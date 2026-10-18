import Foundation
import CoreGraphics
import Testing
import CanvasCore

struct SurfaceImageEncoderTests {
    private struct Fixture {
        let image: CGImage
        let pixels: [UInt8]
    }

    private func fixture(width: Int = 128, height: Int = 96, noise: Bool = false,
                         blackAt: (Int, Int)? = nil, redLeftHalf: Bool = false) throws -> Fixture {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var random: UInt32 = 0x12345678
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                for channel in 0..<3 {
                    random = random &* 1664525 &+ 1013904223
                    if noise { pixels[offset + channel] = UInt8(truncatingIfNeeded: random >> 24) }
                }
                if redLeftHalf && x < width / 2 {
                    pixels[offset] = 255
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 0
                }
                if let (blackX, blackY) = blackAt, x == blackX, y == blackY {
                    pixels[offset] = 0
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
                         revision: SurfaceInputRevision, ack: Int? = nil, input: Bool = false,
                         lastInput: TimeInterval = 0) throws -> SurfaceImageEncoding? {
        try encoder.capture(source.image, width: source.image.width, height: source.image.height, mode: .jpeg,
            inputActive: input, lastInput: lastInput, forceState: false,
            acknowledgedRefinement: ack, revision: revision, at: time)
    }

    private func decode(_ frame: SurfaceImageEncoding, previous: CGImage?) throws -> CGImage {
        try SurfaceImageDecoder.decode(frame.data, format: frame.format, width: frame.width, height: frame.height,
            canvas: frame.canvas, damage: frame.damage, previous: previous, video: SurfaceVideoDecoder())
    }

    private func finishRefinements(_ encoder: SurfaceImageEncoder, source: Fixture, previous: CGImage,
                                   revision: SurfaceInputRevision, at time: TimeInterval,
                                   ack: Int? = nil) throws -> CGImage {
        var image = previous
        var acknowledged = ack
        for _ in 0..<100 {
            guard let frame = try capture(encoder, source, at: time, revision: revision, ack: acknowledged) else {
                #expect(try pixels(image) == source.pixels)
                return image
            }
            #expect(frame.format == .patch)
            #expect(frame.data.count <= 8 * 1024)
            acknowledged = try #require(frame.refinement)
            image = try decode(frame, previous: image)
        }
        Issue.record("Acknowledged refinements did not converge within 100 deliveries")
        return image
    }

    @Test func repeatedCaretChangesAreBoundedExactPatchesWithoutIdleRefreshes() throws {
        let encoder = SurfaceImageEncoder()
        let revision = SurfaceInputRevision()
        let blank = try fixture()
        let first = try #require(try capture(encoder, blank, at: 0, revision: revision))
        var image = try finishRefinements(encoder, source: blank, previous: decode(first, previous: nil),
            revision: revision, at: 1)
        for index in 0..<12 {
            let source = try fixture(blackAt: (31 + index, 7))
            let time = 2 + Double(index) * 2
            let frame = try #require(try capture(encoder, source, at: time, revision: revision))
            #expect(frame.format == .patch)
            #expect(frame.refinement == nil)
            #expect(frame.data.count <= 48 * 1024)
            image = try decode(frame, previous: image)
            #expect(try pixels(image) == source.pixels)
            #expect(try capture(encoder, source, at: time + 1, revision: revision) == nil)
        }
    }

    @Test func refinementChangesOnlyStableDirtyPixelsThenAcknowledgementsStopRefreshes() throws {
        let encoder = SurfaceImageEncoder()
        let revision = SurfaceInputRevision()
        let original = try fixture(noise: true)
        _ = try #require(try capture(encoder, original, at: 0, revision: revision))
        let source = try fixture(noise: true, redLeftHalf: true)
        let motion = try #require(try capture(encoder, source, at: 0.6, revision: revision))
        let before = try decode(motion, previous: nil)
        let beforePixels = try pixels(before)
        let refinement = try #require(try capture(encoder, source, at: 0.9, revision: revision))
        #expect(refinement.format == .patch)
        #expect(refinement.data.count <= 8 * 1024)
        let ticket = try #require(refinement.refinement)
        let after = try decode(refinement, previous: before)
        let afterPixels = try pixels(after)
        var restored = 0
        var unstablePixelsPreserved = true
        var restoredPixelsExact = true
        for y in 0..<96 {
            for x in 0..<128 {
                let offset = (y * 128 + x) * 4
                let beforePixel = Array(beforePixels[offset..<(offset + 4)])
                let afterPixel = Array(afterPixels[offset..<(offset + 4)])
                if x < 64 {
                    unstablePixelsPreserved = unstablePixelsPreserved && afterPixel == beforePixel
                } else if afterPixel != beforePixel {
                    restoredPixelsExact = restoredPixelsExact && afterPixel == Array(source.pixels[offset..<(offset + 4)])
                    restored += 1
                }
            }
        }
        #expect(unstablePixelsPreserved)
        #expect(restoredPixelsExact)
        #expect(restored > 0)
        _ = try finishRefinements(encoder, source: source, previous: after, revision: revision, at: 1.5, ack: ticket)
        for time in [2.0, 10.0, 100.0] {
            #expect(try capture(encoder, source, at: time, revision: revision) == nil)
        }
    }

    @Test func unacknowledgedRefinementIsRedeliveredUntilExactPixelsAreAccepted() throws {
        let encoder = SurfaceImageEncoder()
        let revision = SurfaceInputRevision()
        let source = try fixture(noise: true)
        let motion = try #require(try capture(encoder, source, at: 0, revision: revision))
        let base = try decode(motion, previous: nil)
        #expect(try pixels(base) != source.pixels)
        let lost = try #require(try capture(encoder, source, at: 1, revision: revision))
        let lostTicket = try #require(lost.refinement)
        let unacknowledged = try #require(try capture(encoder, source, at: 1.1, revision: revision))
        _ = try #require(unacknowledged.refinement)
        #expect(unacknowledged.data.count <= 8 * 1024)
        #expect(try pixels(decode(unacknowledged, previous: base)) == pixels(decode(lost, previous: base)))
        let retry = try #require(try capture(encoder, source, at: 1.2, revision: revision, ack: lostTicket))
        let retryTicket = try #require(retry.refinement)
        #expect(retryTicket != lostTicket)
        #expect(retry.data.count <= 8 * 1024)
        let delivered = try decode(retry, previous: base)
        #expect(try pixels(delivered) == pixels(decode(lost, previous: base)))
        #expect(try pixels(delivered) != pixels(base))
        _ = try finishRefinements(encoder, source: source, previous: delivered, revision: revision, at: 2, ack: retryTicket)
    }

    @Test func inputRevisionSupersedesPendingRefinementWithoutBlockingMotionOrLosingQuality() throws {
        let encoder = SurfaceImageEncoder()
        let revision = SurfaceInputRevision()
        var flow = SurfaceFrameFlow(adaptive: true)
        #expect(flow.acknowledge(0, at: 0) == .granted)
        let source = try fixture(noise: true)
        let first = try #require(try capture(encoder, source, at: 0, revision: revision))
        let base = try decode(first, previous: nil)
        #expect(flow.publish(1, refinement: false, at: 0) == nil)
        #expect(flow.acknowledge(1, at: 0.01) == .granted)
        let abandoned = try #require(try capture(encoder, source, at: 1, revision: revision))
        let abandonedTicket = try #require(abandoned.refinement)
        #expect(flow.publish(2, refinement: true, at: 1) == nil)
        let ticket = revision.value
        revision.advance()
        #expect(revision.value != ticket)
        #expect(flow.supersedeRefinement())
        let updated = try fixture(noise: true, redLeftHalf: true)
        let motion = try #require(try capture(encoder, updated, at: 1.1, revision: revision, input: true, lastInput: 1.1))
        #expect(motion.refinement == nil)
        #expect(flow.publish(3, refinement: false, at: 1.1) == 2)
        #expect(!flow.supersedeRefinement())
        #expect(flow.acknowledge(2, at: 1.11) == .stale)
        let moved = try decode(motion, previous: base)
        let movedPixels = try pixels(moved)
        let red = Array(movedPixels[(40 * 128 + 20) * 4..<(40 * 128 + 20) * 4 + 3])
        #expect(red[0] > 240 && red[1] < 15 && red[2] < 15)
        #expect(flow.acknowledge(3, at: 1.12) == .granted)
        #expect(try capture(encoder, updated, at: 1.2, revision: revision, ack: abandonedTicket, lastInput: 1.1) == nil)
        _ = try finishRefinements(encoder, source: updated, previous: moved, revision: revision, at: 2)
    }

    @Test func regionCompositionPreservesSharpPixelsOutsideTopLeftDamage() throws {
        let base = try fixture(blackAt: (20, 80))
        let changed = try fixture(blackAt: (20, 10))
        let result = try #require(SurfaceImagePresentation.composite(changed.image, onto: base.image,
            canvas: CGSize(width: 128, height: 96), damage: CGRect(x: 0, y: 0, width: 64, height: 48)))
        var expected = base.pixels
        let offset = (10 * 128 + 20) * 4
        expected[offset] = 0
        expected[offset + 1] = 0
        expected[offset + 2] = 0
        #expect(try pixels(result) == expected)
    }
}
