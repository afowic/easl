import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import CanvasCore

@Suite(.serialized)
struct SurfaceImageEncoderTests {
    private final class RefreshQueue {
        let queue = DispatchQueue(label: "easl.tests.surface.refresh")
        private var suspended = false

        func pause() {
            queue.suspend()
            suspended = true
        }

        func finish() {
            if suspended {
                queue.resume()
                suspended = false
            }
            queue.sync {}
        }

        deinit { if suspended { queue.resume() } }
    }

    private struct Fixture {
        let image: CGImage
        let pixels: [UInt8]
    }

    private func fixture(width: Int = 129, height: Int = 97, redLeftHalf: Bool = false,
                         shift: Int = 0, noise: Bool = false) throws -> Fixture {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let colors: [[UInt8]] = [[0, 0, 0], [255, 0, 0], [0, 0, 255], [0, 255, 0]]
        var random: UInt32 = 0x12345678
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                for channel in 0..<3 {
                    if noise {
                        random = random &* 1664525 &+ 1013904223
                        pixels[offset + channel] = UInt8(truncatingIfNeeded: random >> 24)
                    } else if (y + shift) % 13 < 8 && (x + shift) % 7 < 3 {
                        pixels[offset + channel] = colors[(x / 7 + y / 13 + shift) % colors.count][channel]
                    }
                }
                if redLeftHalf && x < width / 2 {
                    pixels[offset] = 255
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 0
                }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return Fixture(image: image, pixels: pixels)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try result.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }

    private func capture(_ encoder: SurfaceImageEncoder, _ source: Fixture, at time: TimeInterval,
                         revision: SurfaceInputRevision, mode: SurfaceLinkMode = .video,
                         input: Bool = false, lastInput: TimeInterval = 0,
                         forceState: Bool = false) throws -> SurfaceImageEncoding? {
        try encoder.capture(source.image, width: source.image.width, height: source.image.height, mode: mode,
            inputActive: input, lastInput: lastInput, forceState: forceState,
            revision: revision, at: time)
    }

    private func decode(_ frame: SurfaceImageEncoding, video: SurfaceVideoDecoder = SurfaceVideoDecoder(),
                        refreshVideo: SurfaceVideoDecoder = SurfaceVideoDecoder()) throws -> CGImage {
        try SurfaceImageDecoder.decode(frame.data, format: frame.format, width: frame.width, height: frame.height,
            canvas: frame.canvas, video: video, refreshVideo: refreshVideo, refinement: frame.refresh)
    }

    private func expectSharp(_ frame: SurfaceImageEncoding, source: Fixture) throws {
        #expect(frame.format == .h264)
        #expect(frame.refresh)
        #expect(frame.data.count <= 576 * 1024)
        let image = try decode(frame)
        #expect(image.width == source.image.width && image.height == source.image.height)
        let actual = try pixels(image)
        #expect(actual.count == source.pixels.count)
        let maximumError = zip(actual, source.pixels).map { abs(Int($0) - Int($1)) }.max()
        #expect(try #require(maximumError) <= 4)
    }

    @Test func jpegUsesBaselineBytesDuringIdleAndInputWithoutRefinements() throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let source = try fixture()
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source.image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let first = try #require(try capture(encoder, source, at: 0, revision: revision, mode: .jpeg))
        #expect(first.format == .jpeg && !first.refresh)
        #expect(first.data == output as Data)
        #expect(first.width == 129 && first.height == 97)
        #expect(try capture(encoder, source, at: 1, revision: revision, mode: .jpeg) == nil)
        let state = try #require(try capture(encoder, source, at: 1.1, revision: revision, mode: .jpeg, forceState: true))
        #expect(state.data == first.data && !state.refresh)
        let changed = try fixture(redLeftHalf: true)
        let motion = try #require(try capture(encoder, changed, at: 2, revision: revision, mode: .jpeg, input: true))
        #expect(motion.format == .jpeg && !motion.refresh)
        let visible = try pixels(decode(motion))
        #expect(visible[0] >= 240 && visible[1] <= 15 && visible[2] <= 15)
        work.finish()
        for time in [2.1, 3, 30] {
            #expect(try capture(encoder, changed, at: time, revision: revision, mode: .jpeg) == nil)
        }
    }

    @Test func settledRefreshReplacesTheEntireOddCanvasExactlyOnce() throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let source = try fixture()
        let motion = try #require(try capture(encoder, source, at: 0, revision: revision))
        #expect(motion.format == .h264 && !motion.refresh)
        #expect(try capture(encoder, source, at: 0.59, revision: revision) == nil)
        #expect(try capture(encoder, source, at: 0.6, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, source, at: 0.7, revision: revision))
        #expect(sharp.width == 130 && sharp.height == 98)
        #expect(sharp.canvas == CGSize(width: 129, height: 97))
        try expectSharp(sharp, source: source)
        for time in [0.8, 1.5, 100] {
            #expect(try capture(encoder, source, at: time, revision: revision) == nil)
        }
    }

    @Test func negotiatedPerStreamSizingDefinesTheSharpCanvasBeforeCodecPadding() throws {
        let source = try fixture(width: 258, height: 194, redLeftHalf: true)
        let context = try #require(CGContext(data: nil, width: 129, height: 97, bitsPerComponent: 8,
            bytesPerRow: 129 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy)
        context.interpolationQuality = .high
        context.draw(source.image, in: CGRect(x: 0, y: 0, width: 129, height: 97))
        let normalized = try #require(context.makeImage())
        let expected = Fixture(image: normalized, pixels: try pixels(normalized))
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        func sizedCapture(at time: TimeInterval) throws -> SurfaceImageEncoding? {
            try encoder.capture(source.image, width: 129, height: 97, mode: .video,
                inputActive: false, lastInput: 0, forceState: false,
                revision: revision, at: time)
        }
        let motion = try #require(try sizedCapture(at: 0))
        #expect(motion.canvas == CGSize(width: 129, height: 97) && !motion.refresh)
        #expect(try sizedCapture(at: 0.6) == nil)
        work.finish()
        let sharp = try #require(try sizedCapture(at: 0.7))
        #expect(sharp.width == 130 && sharp.height == 98)
        try expectSharp(sharp, source: expected)
    }

    @Test func pendingRefreshInputCancellationDoesNotBlockMotionOrLoseTheNewSettledVersion() throws {
        let work = RefreshQueue()
        work.pause()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let video = SurfaceVideoDecoder()
        let original = try fixture()
        let first = try #require(try capture(encoder, original, at: 0, revision: revision))
        _ = try decode(first, video: video)
        #expect(try capture(encoder, original, at: 0.6, revision: revision) == nil)
        revision.advance()
        let changed = try fixture(redLeftHalf: true)
        let motion = try #require(try capture(encoder, changed, at: 0.7, revision: revision, input: true, lastInput: 0.7))
        #expect(!motion.refresh && motion.data.count <= 48 * 1024)
        let visible = try pixels(decode(motion, video: video))
        #expect(visible[0] >= 220 && visible[1] <= 30 && visible[2] <= 30)
        #expect(try capture(encoder, changed, at: 1.29, revision: revision, lastInput: 0.7) == nil)
        #expect(try capture(encoder, changed, at: 1.31, revision: revision, lastInput: 0.7) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, changed, at: 1.4, revision: revision, lastInput: 0.7))
        try expectSharp(sharp, source: changed)
        #expect(try capture(encoder, changed, at: 10, revision: revision, lastInput: 0.7) == nil)
    }

    @Test func aReadyRefreshCannotCrossANewerImageVersion() throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let original = try fixture()
        _ = try #require(try capture(encoder, original, at: 0, revision: revision))
        #expect(try capture(encoder, original, at: 0.6, revision: revision) == nil)
        work.finish()
        let changed = try fixture(shift: 1)
        let motion = try #require(try capture(encoder, changed, at: 0.8, revision: revision))
        #expect(!motion.refresh)
        #expect(try capture(encoder, changed, at: 1.41, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, changed, at: 1.5, revision: revision))
        try expectSharp(sharp, source: changed)
    }

    @Test func aReadyRefreshIsCanceledByInputEvenWhenThePixelsDoNotChange() throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let source = try fixture()
        _ = try #require(try capture(encoder, source, at: 0, revision: revision))
        #expect(try capture(encoder, source, at: 0.6, revision: revision) == nil)
        work.finish()
        revision.advance()
        #expect(try capture(encoder, source, at: 0.7, revision: revision, lastInput: 0.7) == nil)
        #expect(try capture(encoder, source, at: 1.31, revision: revision, lastInput: 0.7) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, source, at: 1.4, revision: revision, lastInput: 0.7))
        try expectSharp(sharp, source: source)
    }

    @Test(arguments: [0.45, 0.5])
    func repeatingChangesDoNotProduceRefreshStorms(interval: TimeInterval) throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let sources = try [fixture(), fixture(redLeftHalf: true)]
        var final = sources[0]
        var lastChange: TimeInterval = 0
        for index in 0..<10 {
            final = sources[index % 2]
            lastChange = Double(index) * interval
            let motion = try #require(try capture(encoder, final, at: lastChange, revision: revision))
            #expect(motion.format == .h264 && !motion.refresh)
            #expect(motion.data.count <= 48 * 1024)
            #expect(try capture(encoder, final, at: lastChange + 0.35, revision: revision) == nil)
            work.finish()
        }
        #expect(try capture(encoder, final, at: lastChange + 0.59, revision: revision) == nil)
        #expect(try capture(encoder, final, at: lastChange + 0.61, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, final, at: lastChange + 0.7, revision: revision))
        try expectSharp(sharp, source: final)
        #expect(try capture(encoder, final, at: 100, revision: revision) == nil)
    }

    @Test func switchingToJpegDiscardsQueuedRefreshAndVideoCanSettleAgain() throws {
        let work = RefreshQueue()
        work.pause()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let source = try fixture()
        _ = try #require(try capture(encoder, source, at: 0, revision: revision))
        #expect(try capture(encoder, source, at: 0.6, revision: revision) == nil)
        let jpeg = try #require(try capture(encoder, source, at: 0.7, revision: revision, mode: .jpeg))
        #expect(jpeg.format == .jpeg && !jpeg.refresh)
        work.finish()
        #expect(try capture(encoder, source, at: 10, revision: revision, mode: .jpeg) == nil)
        let motion = try #require(try capture(encoder, source, at: 10.1, revision: revision))
        #expect(motion.format == .h264 && !motion.refresh)
        #expect(try capture(encoder, source, at: 10.71, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, source, at: 10.8, revision: revision))
        try expectSharp(sharp, source: source)
    }

    @Test(arguments: [false, true])
    func anOverBudgetFrozenImageKeepsBoundedMotionAndANewVersionCanRefresh(paddedPixels: Bool) throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let entropy = try fixture(width: paddedPixels ? 2001 : 512, height: paddedPixels ? 1999 : 512,
                                  noise: !paddedPixels)
        let motion = try #require(try capture(encoder, entropy, at: 0, revision: revision))
        #expect(motion.format == .h264 && !motion.refresh && motion.data.count <= 48 * 1024)
        let image = try decode(motion)
        #expect(image.width == motion.width && image.height == motion.height)
        #expect(try capture(encoder, entropy, at: 0.6, revision: revision) == nil)
        work.finish()
        for time in [0.7, 1, 5] {
            #expect(try capture(encoder, entropy, at: time, revision: revision) == nil)
            work.finish()
        }
        revision.advance()
        #expect(try capture(encoder, entropy, at: 5.1, revision: revision, input: true, lastInput: 5.1) == nil)
        #expect(try capture(encoder, entropy, at: 5.8, revision: revision, lastInput: 5.1) == nil)
        work.finish()
        let changed = try fixture()
        let next = try #require(try capture(encoder, changed, at: 6, revision: revision))
        #expect(next.format == .h264 && !next.refresh)
        #expect(try capture(encoder, changed, at: 6.61, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, changed, at: 6.7, revision: revision))
        try expectSharp(sharp, source: changed)
    }

}
