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
    public let damage: CGRect?
    public let refinement: Int?
}

public final class SurfaceImageEncoder: @unchecked Sendable {
    public static let motionBytes = 256 * 1024
    public static let refinementBytes = 8 * 1024
    public static let settle: TimeInterval = 0.8
    public private(set) var captureDelay: TimeInterval = 1

    private let video = SurfaceVideoEncoder()
    private var observed: SurfaceRaster?
    private var presented: SurfaceRaster?
    private var changedAt: [TimeInterval] = []
    private var dirty: [Bool] = []
    private var pendingRefinement: (id: Int, tiles: [Int], at: TimeInterval)?
    private var refinementID = 0
    private var lastJPEG: Data?
    private var jpegSource: CGImage?
    private var jpegSourceAt: TimeInterval = 0

    public init() {}

    public func capture(_ image: CGImage, width: Int, height: Int, mode: SurfaceLinkMode,
                        inputActive: Bool, lastInput: TimeInterval, forceState: Bool,
                        acknowledgedRefinement: Int?, revision: SurfaceInputRevision,
                        at now: TimeInterval) throws -> SurfaceImageEncoding? {
        captureDelay = 1
        guard let sized = Self.sized(image, width: width, height: height) else { return nil }
        let canvas = CGSize(width: width, height: height)
        if let pending = pendingRefinement {
            if acknowledgedRefinement == pending.id {
                for tile in pending.tiles where tile < dirty.count && changedAt[tile] <= pending.at {
                    dirty[tile] = false
                }
            }
            pendingRefinement = nil
        }
        if mode == .jpeg, inputActive {
            guard let jpeg = Self.jpeg(sized) else { return nil }
            if jpeg.data == lastJPEG, !forceState { return nil }
            lastJPEG = jpeg.data
            jpegSource = sized
            jpegSourceAt = now
            captureDelay = 1.0 / 30
            observed = nil
            presented = nil
            changedAt.removeAll(keepingCapacity: true)
            dirty.removeAll(keepingCapacity: true)
            return SurfaceImageEncoding(format: .jpeg, data: jpeg.data, width: jpeg.width, height: jpeg.height,
                                        canvas: canvas, damage: nil, refinement: nil)
        }
        guard let raster = SurfaceRaster(sized) else { return nil }
        if presented == nil, let jpegSource, jpegSource.width == width, jpegSource.height == height {
            presented = SurfaceRaster(jpegSource)
            observed = presented
            changedAt = Array(repeating: jpegSourceAt, count: raster.tileCount)
            dirty = Array(repeating: true, count: raster.tileCount)
        }
        if observed?.width != width || observed?.height != height {
            changedAt = Array(repeating: now, count: raster.tileCount)
            dirty = Array(repeating: true, count: raster.tileCount)
        } else {
            for tile in raster.changedTiles(comparedTo: observed) { changedAt[tile] = now }
        }
        observed = raster
        captureDelay = 1.0 / 30
        let changes = raster.changedTiles(comparedTo: presented)
        let damage = raster.damageBounds(comparedTo: presented, changedTiles: changes)
        if damage != nil || forceState {
            let area = damage.map { $0.width * $0.height } ?? 0
            let small = presented != nil && area <= canvas.width * canvas.height * 0.12
            let tiles = changes.isEmpty ? [0] : changes
            if small, let patch = SurfacePatchPacket(raster: raster, tiles: tiles), patch.tiles.count == tiles.count {
                for tile in patch.tiles { dirty[tile] = false }
                presented = raster
                lastJPEG = nil
                return SurfaceImageEncoding(format: .patch, data: patch.data, width: width, height: height,
                                            canvas: canvas, damage: nil, refinement: nil)
            }
            if mode == .jpeg {
                guard let jpeg = Self.jpeg(sized) else { return nil }
                dirty = Array(repeating: true, count: raster.tileCount)
                presented = raster
                lastJPEG = jpeg.data
                return SurfaceImageEncoding(format: .jpeg, data: jpeg.data, width: jpeg.width, height: jpeg.height,
                                            canvas: canvas, damage: nil, refinement: nil)
            }
            let fitted = SurfaceVideoEncoder.fittedVideoPixels(width: width, height: height)
            guard let encoded = try video.encode(sized, width: fitted.width, height: fitted.height) else { return nil }
            if small {
                for tile in changes { dirty[tile] = true }
            } else {
                dirty = Array(repeating: true, count: raster.tileCount)
            }
            presented = raster
            lastJPEG = nil
            return SurfaceImageEncoding(format: .h264, data: encoded.data, width: encoded.width, height: encoded.height,
                                        canvas: canvas, damage: small ? damage : nil, refinement: nil)
        }
        let pending = dirty.indices.filter { dirty[$0] }
        guard !pending.isEmpty else {
            captureDelay = 1
            return nil
        }
        let due = pending.map { max(lastInput, changedAt[$0]) + Self.settle }.min()!
        captureDelay = max(1.0 / 30, due - now)
        let eligible = pending.filter { now >= max(lastInput, changedAt[$0]) + Self.settle }
        guard !eligible.isEmpty else { return nil }
        let ticket = revision.value
        guard let patch = SurfacePatchPacket(raster: raster, tiles: eligible, maximumBytes: Self.refinementBytes,
                                             isCancelled: { revision.value != ticket }), revision.value == ticket else { return nil }
        refinementID += 1
        pendingRefinement = (refinementID, patch.tiles, now)
        return SurfaceImageEncoding(format: .patch, data: patch.data, width: width, height: height,
                                    canvas: canvas, damage: nil, refinement: refinementID)
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

public enum SurfaceImagePresentation {
    public static func composite(_ image: CGImage, onto previous: CGImage?, canvas: CGSize, damage: CGRect?) -> CGImage? {
        guard let damage, let previous else { return image }
        let width = Int(canvas.width), height = Int(canvas.height)
        guard width > 0, height > 0, width <= SurfaceEvent.Frame.maxPixels / height,
              damage.minX >= 0, damage.minY >= 0, damage.maxX <= canvas.width, damage.maxY <= canvas.height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.setBlendMode(.copy)
        context.draw(previous, in: CGRect(origin: .zero, size: canvas))
        context.clip(to: CGRect(x: damage.minX, y: canvas.height - damage.maxY, width: damage.width, height: damage.height))
        context.draw(image, in: CGRect(origin: .zero, size: canvas))
        return context.makeImage()
    }
}
