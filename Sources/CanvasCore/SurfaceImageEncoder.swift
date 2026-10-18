import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct SurfaceImageEncoding: @unchecked Sendable {
    public let format: SurfaceFormat
    public let data: Data
    public let width: Int
    public let height: Int
    public let canvas: CGSize
    public let refresh: Bool
}

private enum SurfaceImageEncodingError: Error {
    case invalidImage, missingOutput, invalidRefresh
}

private struct SurfaceImageIdentity: Equatable {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private let bitmap: UInt32
    private let space: CGColorSpace?
    private let pixels: CFData

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32,
           image.decode == nil, image.bytesPerRow >= width * 4,
           image.bytesPerRow <= Int.max / height, let data = image.dataProvider?.data,
           CFDataGetLength(data) >= image.bytesPerRow * height {
            pixels = data
            bytesPerRow = image.bytesPerRow
            bitmap = image.bitmapInfo.rawValue
            space = image.colorSpace
        } else {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: Self.colorSpace, bitmapInfo: Self.bitmapInfo) else { return nil }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let normalized = context.makeImage(), let data = normalized.dataProvider?.data else { return nil }
            pixels = data
            bytesPerRow = normalized.bytesPerRow
            bitmap = Self.bitmapInfo
            space = Self.colorSpace
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              lhs.bitmap == rhs.bitmap, lhs.space == rhs.space else { return false }
        let left = CFDataGetBytePtr(lhs.pixels)!
        let right = CFDataGetBytePtr(rhs.pixels)!
        if lhs.bytesPerRow == lhs.width * 4, rhs.bytesPerRow == lhs.bytesPerRow {
            return memcmp(left, right, lhs.bytesPerRow * lhs.height) == 0
        }
        for row in 0..<lhs.height {
            if memcmp(left + row * lhs.bytesPerRow, right + row * rhs.bytesPerRow, lhs.width * 4) != 0 { return false }
        }
        return true
    }
}

private final class SurfaceImageRefresh: @unchecked Sendable {
    struct Key: Equatable, Sendable {
        let imageVersion: UInt64
        let inputRevision: UInt64
    }

    private final class Job: @unchecked Sendable {
        let key: Key
        let image: CGImage
        let revision: SurfaceInputRevision

        init(key: Key, image: CGImage, revision: SurfaceInputRevision) {
            self.key = key
            self.image = image
            self.revision = revision
        }
    }

    private enum State {
        case idle
        case pending(Job)
        case ready(Job, Result<SurfaceVideoFrame, Error>)
        case delivered
        case refused(imageVersion: UInt64)
    }

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let encoder = SurfaceVideoEncoder(mode: .refresh)
    private var key: Key?
    private var state: State = .idle
    private var workerRunning = false

    init(queue: DispatchQueue) { self.queue = queue }

    func synchronize(_ key: Key?) {
        lock.lock()
        defer { lock.unlock() }
        if self.key != key {
            self.key = key
            if case .refused(let version) = state, key == nil || key?.imageVersion == version { return }
            state = .idle
        }
    }

    private func isCurrent(_ job: Job) -> Bool {
        guard job.revision.value == job.key.inputRevision else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard key == job.key, case .pending(let pending) = state else { return false }
        return pending === job
    }

    func start(image: CGImage, key: Key, revision: SurfaceInputRevision) -> Bool {
        lock.lock()
        guard self.key == key else { lock.unlock(); return false }
        guard case .idle = state else {
            let pending: Bool
            switch state {
            case .pending, .ready: pending = true
            case .idle, .delivered, .refused: pending = false
            }
            lock.unlock()
            return pending
        }
        let job = Job(key: key, image: image, revision: revision)
        state = .pending(job)
        guard !workerRunning else { lock.unlock(); return true }
        workerRunning = true
        lock.unlock()
        queue.async { [self] in run() }
        return true
    }

    private func run() {
        while true {
            lock.lock()
            guard case .pending(let job) = state else {
                workerRunning = false
                lock.unlock()
                return
            }
            lock.unlock()
            guard isCurrent(job) else {
                lock.lock()
                if case .pending(let pending) = state, pending === job { state = .idle }
                lock.unlock()
                continue
            }
            let result: Result<SurfaceVideoFrame?, Error> = Result {
                guard let frame = try encoder.encode(job.image, width: job.image.width, height: job.image.height,
                    isCancelled: { !self.isCurrent(job) }) else { return nil }
                guard frame.data.count <= SurfaceImageEncoder.refinementBytes,
                      frame.width == max(16, (job.image.width + 1) / 2 * 2),
                      frame.height == max(16, (job.image.height + 1) / 2 * 2) else {
                    throw SurfaceImageEncodingError.invalidRefresh
                }
                return frame
            }
            lock.lock()
            if self.key == job.key, job.revision.value == job.key.inputRevision,
               case .pending(let pending) = state, pending === job {
                switch result {
                case .success(let frame?): state = .ready(job, .success(frame))
                case .success(nil): state = .refused(imageVersion: job.key.imageVersion)
                case .failure(let error): state = .ready(job, .failure(error))
                }
            }
            lock.unlock()
        }
    }

    func take(key: Key, revision: SurfaceInputRevision) throws -> SurfaceVideoFrame? {
        guard revision.value == key.inputRevision else { return nil }
        lock.lock()
        guard self.key == key, case .ready(let job, let result) = state,
              job.key == key else { lock.unlock(); return nil }
        switch result {
        case .success: state = .delivered
        case .failure: state = .idle
        }
        lock.unlock()
        guard revision.value == key.inputRevision else { return nil }
        return try result.get()
    }
}

/// Callers serialize captures. The independent idle encoder never holds up motion encoding.
public final class SurfaceImageEncoder: @unchecked Sendable {
    public static let motionBytes = 256 * 1024
    public static let refinementBytes = 576 * 1024
    public static let settle: TimeInterval = 0.6
    public private(set) var captureDelay: TimeInterval = 0.1

    private let video = SurfaceVideoEncoder()
    private let refresh: SurfaceImageRefresh
    private var observed: SurfaceImageIdentity?
    private var imageVersion: UInt64 = 0
    private var motionVersion: UInt64?
    private var changedAt: TimeInterval = 0
    private var lastJPEG: Data?
    private var lastJPEGCanvas: CGSize?

    public convenience init() {
        self.init(refreshQueue: DispatchQueue(label: "easl.surface.refresh", qos: .utility))
    }

    init(refreshQueue: DispatchQueue) { refresh = SurfaceImageRefresh(queue: refreshQueue) }

    public func capture(_ image: CGImage, width: Int, height: Int, mode: SurfaceLinkMode,
                        inputActive: Bool, lastInput: TimeInterval, forceState: Bool,
                        revision: SurfaceInputRevision,
                        at now: TimeInterval) throws -> SurfaceImageEncoding? {
        captureDelay = inputActive ? 1.0 / 30 : 0.1
        guard let source = Self.sized(image, width: width, height: height) else { throw SurfaceImageEncodingError.invalidImage }
        let canvas = CGSize(width: width, height: height)
        if mode == .jpeg {
            refresh.synchronize(nil)
            observed = nil
            motionVersion = nil
            guard let jpeg = Self.jpeg(source) else { throw SurfaceImageEncodingError.missingOutput }
            guard jpeg.data != lastJPEG || canvas != lastJPEGCanvas || forceState else {
                if !inputActive { captureDelay = 1 }
                return nil
            }
            lastJPEG = jpeg.data
            lastJPEGCanvas = canvas
            captureDelay = 1.0 / 30
            return SurfaceImageEncoding(format: .jpeg, data: jpeg.data, width: jpeg.width, height: jpeg.height,
                                        canvas: canvas, refresh: false)
        }
        guard let identity = SurfaceImageIdentity(source) else { throw SurfaceImageEncodingError.invalidImage }
        if identity != observed {
            imageVersion &+= 1
            changedAt = now
            observed = identity
        } else if forceState {
            imageVersion &+= 1
        }
        let key = SurfaceImageRefresh.Key(imageVersion: imageVersion, inputRevision: revision.value)
        refresh.synchronize(inputActive ? nil : key)
        if motionVersion != imageVersion || forceState {
            guard let encoded = try video.encode(source, width: width, height: height) else { return nil }
            motionVersion = imageVersion
            lastJPEG = nil
            lastJPEGCanvas = nil
            captureDelay = 1.0 / 30
            return SurfaceImageEncoding(format: .h264, data: encoded.data, width: encoded.width, height: encoded.height,
                                        canvas: canvas, refresh: false)
        }
        let due = max(changedAt, lastInput) + Self.settle
        guard !inputActive, now >= due else {
            captureDelay = min(captureDelay, max(1.0 / 30, due - now))
            return nil
        }
        if let encoded = try refresh.take(key: key, revision: revision) {
            guard revision.value == key.inputRevision else { return nil }
            return SurfaceImageEncoding(format: .h264, data: encoded.data, width: encoded.width, height: encoded.height,
                                        canvas: canvas, refresh: true)
        }
        captureDelay = refresh.start(image: source, key: key, revision: revision) ? 1.0 / 30 : 1
        return nil
    }

    public static func sized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, width <= SurfaceEvent.Frame.maxPixels / height else { return nil }
        if image.width == width && image.height == height { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.setBlendMode(.copy)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    public static func jpeg(_ image: CGImage) -> (data: Data, width: Int, height: Int)? {
        var image = image
        for _ in 0..<8 {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if output.length <= motionBytes { return (output as Data, image.width, image.height) }
            let ratio = min(0.75, sqrt(Double(motionBytes) / Double(output.length)) * 0.9)
            guard let reduced = sized(image, width: max(1, Int(Double(image.width) * ratio)),
                                      height: max(1, Int(Double(image.height) * ratio))) else { return nil }
            image = reduced
        }
        return nil
    }
}
