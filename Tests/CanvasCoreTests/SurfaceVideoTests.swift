import Foundation
import CoreGraphics
import Testing
import CanvasCore

struct SurfaceVideoTests {
    private func image(width: Int = 64, height: Int = 64, red: Bool = false) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: red ? 1 : 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return try #require(context.makeImage())
    }

    private func center(_ image: CGImage) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Array(pixel.prefix(3))
    }

    @Test func encodedChangesAreVisibleAndImagesRemainImmutable() throws {
        let encoder = SurfaceVideoEncoder()
        let decoder = SurfaceVideoDecoder()
        let first = try #require(try encoder.encode(image(), width: 64, height: 64))
        let black = try decoder.decode(first.data, width: first.width, height: first.height)
        let second = try #require(try encoder.encode(image(red: true), width: 64, height: 64))
        let red = try decoder.decode(second.data, width: second.width, height: second.height)
        #expect(black.width == 64 && black.height == 64)
        let blackPixel = try center(black)
        let redPixel = try center(red)
        #expect(blackPixel.allSatisfy { $0 < 30 })
        #expect(redPixel[0] > 220 && redPixel[1] < 30 && redPixel[2] < 30)
        #expect(try center(black) == blackPixel)
    }

    @Test func resizingAndNewStreamsProduceRecoverableKeyframes() throws {
        let encoder = SurfaceVideoEncoder()
        let decoder = SurfaceVideoDecoder()
        let original = try #require(try encoder.encode(image(), width: 64, height: 64))
        _ = try decoder.decode(original.data, width: original.width, height: original.height)
        let resized = try #require(try encoder.encode(image(width: 96, height: 80, red: true), width: 96, height: 80))
        for consumer in [decoder, SurfaceVideoDecoder()] {
            let decoded = try consumer.decode(resized.data, width: resized.width, height: resized.height)
            #expect(decoded.width == 96 && decoded.height == 80)
            #expect(try center(decoded)[0] > 220)
        }
        let restarted = try #require(try SurfaceVideoEncoder().encode(image(), width: 64, height: 64))
        #expect(try center(SurfaceVideoDecoder().decode(restarted.data, width: restarted.width, height: restarted.height)).allSatisfy { $0 < 30 })
    }

    @Test func predictedFirstFrameAndForgedKeyframeAreRejected() throws {
        let encoder = SurfaceVideoEncoder()
        let first = try #require(try encoder.encode(image(), width: 64, height: 64)).data
        let predicted = try #require(try encoder.encode(image(), width: 64, height: 64)).data
        #expect(predicted[4] == 0)
        let decoder = SurfaceVideoDecoder()
        #expect(throws: (any Error).self) { try decoder.decode(predicted, width: 64, height: 64) }
        var forged = predicted
        forged[4] = 1
        #expect(throws: (any Error).self) { try decoder.decode(forged, width: 64, height: 64) }
        var hiddenIDR = first
        hiddenIDR[4] = 0
        #expect(throws: (any Error).self) { try decoder.decode(hiddenIDR, width: 64, height: 64) }
        #expect(try center(decoder.decode(first, width: 64, height: 64)).allSatisfy { $0 < 30 })
    }

    @Test func malformedPacketsResetTheDecoderAndKeyframesRecover() throws {
        let encoder = SurfaceVideoEncoder()
        let keyframe = try #require(try encoder.encode(image(), width: 64, height: 64)).data
        let predicted = try #require(try encoder.encode(image(), width: 64, height: 64)).data
        var malformed = [Data(), Data(keyframe.prefix(9)), Data(keyframe.dropLast()),
                         Data(repeating: 0, count: 8 * 1024 * 1024 + 1)]
        for (index, value) in [(0, UInt8(0)), (4, 2), (5, 3), (6, 255), (7, 255), (10, 0x68)] {
            var packet = keyframe
            packet[index] = value
            malformed.append(packet)
        }
        let spsSize = Int(keyframe[6]) << 8 | Int(keyframe[7])
        let ppsSize = Int(keyframe[8]) << 8 | Int(keyframe[9])
        var wrongPPS = keyframe
        wrongPPS[10 + spsSize] = 0x67
        malformed.append(wrongPPS)
        var invalidNAL = keyframe
        let sampleStart = 10 + spsSize + ppsSize
        invalidNAL.replaceSubrange(sampleStart..<(sampleStart + 4), with: [255, 255, 255, 255])
        malformed.append(invalidNAL)
        for packet in malformed {
            let decoder = SurfaceVideoDecoder()
            _ = try decoder.decode(keyframe, width: 64, height: 64)
            #expect(throws: (any Error).self) { try decoder.decode(packet, width: 64, height: 64) }
            #expect(throws: (any Error).self) { try decoder.decode(predicted, width: 64, height: 64) }
            #expect(try center(decoder.decode(keyframe, width: 64, height: 64)).allSatisfy { $0 < 30 })
        }
    }

    @Test func invalidAndMismatchedDimensionsAreRejected() throws {
        let encoder = SurfaceVideoEncoder()
        let source = try image()
        let packet = try #require(try encoder.encode(source, width: 64, height: 64)).data
        for (width, height) in [(0, 64), (-1, 64), (Int.max, Int.max), (2001, 2000), (64, 80)] {
            let decoder = SurfaceVideoDecoder()
            #expect(throws: (any Error).self) { try decoder.decode(packet, width: width, height: height) }
            #expect(try center(decoder.decode(packet, width: 64, height: 64)).allSatisfy { $0 < 30 })
        }
        for (width, height) in [(0, 64), (-1, 64), (Int.max, Int.max), (2001, 2000)] {
            #expect(throws: (any Error).self) { try encoder.encode(source, width: width, height: height) }
        }
    }

    @Test func oversizedParameterSetDimensionsAreRejected() throws {
        let encoder = SurfaceVideoEncoder()
        let original = try #require(try encoder.encode(image(), width: 64, height: 64)).data
        func golomb(_ value: Int) -> String {
            let binary = String(value + 1, radix: 2)
            return String(repeating: "0", count: binary.count - 1) + binary
        }
        var bits = golomb(0) + golomb(0) + golomb(0) + golomb(0) + golomb(1) + "0"
        bits += golomb(125) + golomb(124) + "11001"
        while bits.count % 8 != 0 { bits += "0" }
        let digits = Array(bits)
        var sps = Data([0x67, 66, 0, 51])
        for offset in stride(from: 0, to: digits.count, by: 8) {
            sps.append(UInt8(String(digits[offset..<(offset + 8)]), radix: 2)!)
        }
        let oldSPSSize = Int(original[6]) << 8 | Int(original[7])
        var oversized = original
        oversized.replaceSubrange(10..<(10 + oldSPSSize), with: sps)
        oversized[6] = UInt8(sps.count >> 8)
        oversized[7] = UInt8(sps.count & 255)
        let decoder = SurfaceVideoDecoder()
        #expect(throws: (any Error).self) { try decoder.decode(oversized, width: 64, height: 64) }
        #expect(try center(decoder.decode(original, width: 64, height: 64)).allSatisfy { $0 < 30 })
    }

    @Test func fittedOddAndThinCapturesRoundTrip() throws {
        for (width, height, expectedWidth, expectedHeight) in [(1, 1, 16, 16), (65, 67, 64, 66), (1, 64, 16, 64)] {
            let fitted = SurfaceVideoEncoder.fittedVideoPixels(width: width, height: height)
            #expect(fitted.width == expectedWidth && fitted.height == expectedHeight)
            let encoder = SurfaceVideoEncoder()
            let packet = try #require(try encoder.encode(image(width: fitted.width, height: fitted.height),
                width: fitted.width, height: fitted.height))
            let decoded = try SurfaceVideoDecoder().decode(packet.data, width: packet.width, height: packet.height)
            #expect(decoded.width == expectedWidth && decoded.height == expectedHeight)
            #expect(try center(decoded).allSatisfy { $0 < 30 })
        }
        for (width, height) in [(Int.max, 1), (1, Int.max), (Int.max, Int.max), (2001, 2000)] {
            let fitted = SurfaceVideoEncoder.fittedVideoPixels(width: width, height: height)
            #expect(fitted.width >= 16 && fitted.height >= 16)
            #expect(fitted.width <= 4096 && fitted.height <= 4096)
            #expect(fitted.width % 2 == 0 && fitted.height % 2 == 0)
            #expect(fitted.width * fitted.height <= 4_000_000)
        }
    }

    @Test func predictedConfigurationChangesRequireAKeyframe() throws {
        let encoder = SurfaceVideoEncoder()
        let decoder = SurfaceVideoDecoder()
        let original = try #require(try encoder.encode(image(), width: 64, height: 64)).data
        _ = try decoder.decode(original, width: 64, height: 64)
        let resized = try #require(try encoder.encode(image(width: 96, height: 80), width: 96, height: 80)).data
        let predicted = try #require(try encoder.encode(image(width: 96, height: 80), width: 96, height: 80)).data
        #expect(predicted[4] == 0)
        #expect(throws: (any Error).self) { try decoder.decode(predicted, width: 96, height: 80) }
        let recovered = try decoder.decode(resized, width: 96, height: 80)
        #expect(recovered.width == 96 && recovered.height == 80)
        #expect(try center(recovered).allSatisfy { $0 < 30 })
    }

    private func noise(width: Int, height: Int, seed: UInt64) throws -> CGImage {
        var state = seed
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                bytes[offset] = UInt8(truncatingIfNeeded: state)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 8)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 16)
                bytes[offset + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test func entropyChangesAndFrozenNoiseStayBoundedAndDecodable() throws {
        let encoder = SurfaceVideoEncoder()
        let decoder = SurfaceVideoDecoder()
        let width = 1536
        let height = 1024
        let original = try #require(try encoder.encode(image(width: width, height: height),
            width: width, height: height))
        let preserved = try decoder.decode(original.data, width: original.width, height: original.height)
        let black = try center(preserved)
        let frozen = try noise(width: width, height: height, seed: 0x123456789abcdef)
        var previous: SurfaceVideoFrame?
        var frozenPredictedFrames = 0
        for index in 0..<8 {
            let source = index < 3 ? try noise(width: width, height: height, seed: UInt64(index + 1)) : frozen
            guard let frame = try encoder.encode(source, width: width, height: height) else { continue }
            #expect(frame.data.count <= 48 * 1024)
            #expect(frame.width >= 16 && frame.height >= 16)
            #expect(frame.width % 2 == 0 && frame.height % 2 == 0)
            #expect(frame.width <= width && frame.height <= height)
            let decoded = try decoder.decode(frame.data, width: frame.width, height: frame.height)
            #expect(decoded.width == frame.width && decoded.height == frame.height)
            if index == 0 || previous?.width != frame.width || previous?.height != frame.height {
                let fresh = try SurfaceVideoDecoder().decode(frame.data, width: frame.width, height: frame.height)
                #expect(fresh.width == frame.width && fresh.height == frame.height)
            }
            if index >= 3, frame.data[4] == 0 { frozenPredictedFrames += 1 }
            previous = frame
        }
        #expect(frozenPredictedFrames > 0)
        #expect(try center(preserved) == black)
    }

    @Test func oddRequestedDimensionsReportEvenDecodablePixels() throws {
        let frame = try #require(try SurfaceVideoEncoder().encode(image(width: 65, height: 67), width: 65, height: 67))
        #expect(frame.width == 64 && frame.height == 66)
        #expect(frame.data.count <= 48 * 1024)
        let decoded = try SurfaceVideoDecoder().decode(frame.data, width: frame.width, height: frame.height)
        #expect(decoded.width == 64 && decoded.height == 66)
    }

    private func coloredDetail(width: Int, height: Int, shifted: Bool = false) throws -> CGImage {
        let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 0, 255, 255], [0, 255, 0, 255],
                                 [255, 0, 255, 255], [0, 255, 255, 255], [255, 255, 255, 255]]
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let color = colors[(x + y * 3 + (shifted ? 1 : 0)) % colors.count]
                    for channel in 0..<4 { bytes[(y * width + x) * 4 + channel] = color[channel] }
                }
            }
        }
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    }

    private func rgba(_ image: CGImage) throws -> Data {
        var pixels = Data(count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    @Test func refreshPreservesColoredPixelsAndDoesNotChangeMotionReferences() throws {
        let motion = SurfaceVideoEncoder()
        let motionDecoder = SurfaceVideoDecoder()
        let first = try #require(try motion.encode(image(), width: 64, height: 64))
        _ = try motionDecoder.decode(first.data, width: first.width, height: first.height)
        let refresh = SurfaceVideoEncoder(mode: .refresh)
        for shifted in [false, true] {
            let source = try coloredDetail(width: 65, height: 67, shifted: shifted)
            let frame = try #require(try refresh.encode(source, width: 65, height: 67))
            #expect(frame.width == 66 && frame.height == 68)
            #expect(frame.data.count <= 576 * 1024 && frame.data[4] == 1)
            let decoded = try SurfaceVideoDecoder().decode(frame.data, width: frame.width, height: frame.height)
            let cropped = try #require(decoded.cropping(to: CGRect(x: 0, y: 0, width: 65, height: 67)))
            let expected = try rgba(source)
            let actual = try rgba(cropped)
            #expect(actual.count == 65 * 67 * 4)
            let maximumError = zip(expected, actual).map { abs(Int($0) - Int($1)) }.max()
            #expect(try #require(maximumError) <= 4)
        }
        let predicted = try #require(try motion.encode(image(red: true), width: 64, height: 64))
        #expect(predicted.data[4] == 0 && predicted.data.count <= 48 * 1024)
        let red = try motionDecoder.decode(predicted.data, width: predicted.width, height: predicted.height)
        #expect(try center(red)[0] > 220)
    }

    @Test func refreshCancellationAndPacketRejectionAllowIndependentRecovery() throws {
        let refresh = SurfaceVideoEncoder(mode: .refresh)
        let source = try coloredDetail(width: 64, height: 64)
        #expect(try refresh.encode(source, width: 64, height: 64, isCancelled: { true }) == nil)
        let entropy = try noise(width: 512, height: 512, seed: 0x123456789abcdef)
        #expect(try refresh.encode(entropy, width: 512, height: 512) == nil)
        let frame = try #require(try refresh.encode(source, width: 64, height: 64))
        #expect(frame.width == 64 && frame.height == 64)
        #expect(frame.data.count <= 576 * 1024 && frame.data[4] == 1)
        let decoded = try SurfaceVideoDecoder().decode(frame.data, width: frame.width, height: frame.height)
        let maximumError = zip(try rgba(source), try rgba(decoded)).map { abs(Int($0) - Int($1)) }.max()
        #expect(try #require(maximumError) <= 4)
    }

    @Test func refreshRejectsPaddedPixelOverflowAndDimensionMismatch() throws {
        let refresh = SurfaceVideoEncoder(mode: .refresh)
        let source = try image(width: 2001, height: 1999)
        #expect(throws: (any Error).self) { try refresh.encode(source, width: 2001, height: 1999) }
        #expect(throws: (any Error).self) { try refresh.encode(source, width: 2000, height: 1999) }
    }
}
