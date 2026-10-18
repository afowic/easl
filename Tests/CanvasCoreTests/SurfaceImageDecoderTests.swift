import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import CanvasCore

@Suite(.serialized)
struct SurfaceImageDecoderTests {
    private func image(redLeftHalf: Bool = false) throws -> CGImage {
        let width = 65, height = 67
        let colors: [[UInt8]] = [[255, 0, 0], [0, 0, 255], [0, 255, 0], [255, 0, 255], [0, 255, 255], [255, 255, 255]]
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = redLeftHalf && x < width / 2 ? colors[0] : colors[(x + y * 3) % colors.count]
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = color[channel] }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
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

    private func decode(_ frame: SurfaceVideoFrame, video: SurfaceVideoDecoder,
                        refreshVideo: SurfaceVideoDecoder, refinement: Bool) throws -> CGImage {
        try SurfaceImageDecoder.decode(frame.data, format: .h264, width: frame.width, height: frame.height,
            canvas: CGSize(width: 65, height: 67), video: video, refreshVideo: refreshVideo, refinement: refinement)
    }

    @Test func sharpCropPreservesTheFullCanvasAndMotionReferencesRemainIndependent() throws {
        let motion = SurfaceVideoEncoder()
        let refresh = SurfaceVideoEncoder(mode: .refresh)
        let video = SurfaceVideoDecoder(), refreshVideo = SurfaceVideoDecoder()
        let source = try image()
        let first = try #require(try motion.encode(source, width: 65, height: 67))
        let original = try decode(first, video: video, refreshVideo: refreshVideo, refinement: false)
        let originalPixels = try pixels(original)
        let sharp = try #require(try refresh.encode(source, width: 65, height: 67))
        let settled = try decode(sharp, video: video, refreshVideo: refreshVideo, refinement: true)
        #expect(settled.width == 65 && settled.height == 67)
        let actual = try pixels(settled)
        let expected = try pixels(source)
        #expect(actual.count == 65 * 67 * 4)
        let maximumError = zip(expected, actual).map { abs(Int($0) - Int($1)) }.max()
        #expect(try #require(maximumError) <= 4)
        let changed = try image(redLeftHalf: true)
        let predicted = try #require(try motion.encode(changed, width: 65, height: 67))
        #expect(predicted.data[4] == 0)
        let moved = try decode(predicted, video: video, refreshVideo: refreshVideo, refinement: false)
        #expect(moved.width == 64 && moved.height == 66)
        let visible = try pixels(moved)
        #expect(visible[0] >= 220 && visible[1] <= 30 && visible[2] <= 30)
        #expect(try pixels(original) == originalPixels)
        #expect(try pixels(settled) == actual)
    }

    @Test func malformedRefreshDoesNotPoisonTheMotionDecoder() throws {
        let motion = SurfaceVideoEncoder()
        let video = SurfaceVideoDecoder(), refreshVideo = SurfaceVideoDecoder()
        let source = try image()
        let first = try #require(try motion.encode(source, width: 65, height: 67))
        _ = try decode(first, video: video, refreshVideo: refreshVideo, refinement: false)
        let sharp = try #require(try SurfaceVideoEncoder(mode: .refresh).encode(source, width: 65, height: 67))
        for data in [Data(), Data(sharp.data.dropLast()), Data(repeating: 0, count: 576 * 1024 + 1)] {
            #expect(throws: (any Error).self) {
                try SurfaceImageDecoder.decode(data, format: .h264, width: sharp.width, height: sharp.height,
                    canvas: CGSize(width: 65, height: 67), video: video, refreshVideo: refreshVideo, refinement: true)
            }
        }
        let predicted = try #require(try motion.encode(image(redLeftHalf: true), width: 65, height: 67))
        let moved = try decode(predicted, video: video, refreshVideo: refreshVideo, refinement: false)
        let visible = try pixels(moved)
        #expect(visible[0] >= 220 && visible[1] <= 30 && visible[2] <= 30)
        let recovered = try decode(sharp, video: video, refreshVideo: refreshVideo, refinement: true)
        #expect(recovered.width == 65 && recovered.height == 67)
        let maximumError = zip(try pixels(recovered), try pixels(source)).map { abs(Int($0) - Int($1)) }.max()
        #expect(try #require(maximumError) <= 4)
    }

    @Test func malformedCanvasAndNonPaddingRefreshDimensionsAreRejectedWithoutResampling() throws {
        let source = try image()
        let sharp = try #require(try SurfaceVideoEncoder(mode: .refresh).encode(source, width: 65, height: 67))
        let video = SurfaceVideoDecoder(), refreshVideo = SurfaceVideoDecoder()
        for canvas in [CGSize.zero, CGSize(width: -1, height: 67), CGSize(width: .infinity, height: 67),
                       CGSize(width: 65.5, height: 67), CGSize(width: 63, height: 67),
                       CGSize(width: 65, height: 65), CGSize(width: 67, height: 67),
                       CGSize(width: 4_000_001, height: 1)] {
            #expect(throws: (any Error).self) {
                try SurfaceImageDecoder.decode(sharp.data, format: .h264, width: sharp.width, height: sharp.height,
                    canvas: canvas, video: video, refreshVideo: refreshVideo, refinement: true)
            }
        }
        for (width, height) in [(0, 68), (Int.max, Int.max), (68, 68), (66, 70)] {
            #expect(throws: (any Error).self) {
                try SurfaceImageDecoder.decode(sharp.data, format: .h264, width: width, height: height,
                    canvas: CGSize(width: 65, height: 67), video: video, refreshVideo: refreshVideo, refinement: true)
            }
        }
        #expect(throws: (any Error).self) {
            try SurfaceImageDecoder.decode(Data(repeating: 0, count: 48 * 1024 + 1), format: .h264, width: 64, height: 66,
                canvas: CGSize(width: 65, height: 67), video: video, refreshVideo: refreshVideo, refinement: false)
        }
        let valid = try decode(sharp, video: video, refreshVideo: refreshVideo, refinement: true)
        #expect(valid.width == 65 && valid.height == 67)
        let maximumError = zip(try pixels(valid), try pixels(source)).map { abs(Int($0) - Int($1)) }.max()
        #expect(try #require(maximumError) <= 4)
    }

    @Test func stillImagesValidateDeclaredDimensionsAndCannotBeUsedAsRefreshes() throws {
        let source = try image()
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        #expect(CGImageDestinationFinalize(destination))
        let video = SurfaceVideoDecoder(), refreshVideo = SurfaceVideoDecoder()
        let decoded = try SurfaceImageDecoder.decode(data as Data, format: .png, width: 65, height: 67,
            canvas: CGSize(width: 65, height: 67), video: video, refreshVideo: refreshVideo, refinement: false)
        #expect(try pixels(decoded) == pixels(source))
        for (width, height, refinement) in [(64, 67, false), (65, 66, false), (65, 67, true)] {
            #expect(throws: (any Error).self) {
                try SurfaceImageDecoder.decode(data as Data, format: .png, width: width, height: height,
                    canvas: CGSize(width: 65, height: 67), video: video, refreshVideo: refreshVideo, refinement: refinement)
            }
        }
        #expect(throws: (any Error).self) {
            try SurfaceImageDecoder.decode(Data([1, 2, 3]), format: .jpeg, width: 65, height: 67,
                canvas: CGSize(width: 65, height: 67), video: video, refreshVideo: refreshVideo, refinement: false)
        }
        #expect(try pixels(decoded) == pixels(source))
    }
}
