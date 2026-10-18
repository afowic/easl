import Foundation
import CoreGraphics
import Testing
import CanvasCore

struct SurfaceImagePatchTests {
    private func image(width: Int, height: Int, noise: Bool = false, changed: [(Int, Int)] = []) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var random: UInt32 = 0x12345678
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                for channel in 0..<3 {
                    random = random &* 1664525 &+ 1013904223
                    bytes[index + channel] = noise ? UInt8(truncatingIfNeeded: random >> 24) : 255
                }
            }
        }
        for (x, y) in changed {
            let index = (y * width + x) * 4
            bytes[index] = 0; bytes[index + 1] = 0; bytes[index + 2] = 0
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func word(_ value: UInt32, at offset: Int, in data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    @Test func preciseCaretAndEdgeDamageHasNoIdleTiles() throws {
        let original = try #require(SurfaceRaster(image(width: 193, height: 100)))
        let updated = try #require(SurfaceRaster(image(width: 193, height: 100, changed: [(95, 2), (96, 4)])))
        #expect(original.tileCount == 28)
        #expect(original.changedTiles(comparedTo: nil) == Array(0..<28))
        #expect(updated.changedTiles(comparedTo: original) == [2, 3])
        #expect(updated.damageBounds(comparedTo: original) == CGRect(x: 95, y: 2, width: 2, height: 3))
        #expect(original.changedTiles(comparedTo: original).isEmpty)
        #expect(original.damageBounds(comparedTo: original) == nil)
        let resized = try #require(SurfaceRaster(image(width: 20, height: 10)))
        #expect(resized.changedTiles(comparedTo: original) == [0])
        #expect(resized.damageBounds(comparedTo: original) == CGRect(x: 0, y: 0, width: 20, height: 10))
        #expect(SurfacePatchPacket(raster: original, tiles: []) == nil)
    }

    @Test func noisyPacketsStayBoundedMakeProgressAndPreservePriorImages() throws {
        let source = try #require(SurfaceRaster(image(width: 289, height: 193, noise: true)))
        let blank = try image(width: 289, height: 193)
        let blankRaster = try #require(SurfaceRaster(blank))
        var canvas = blank
        var remaining = source.changedTiles(comparedTo: nil)
        var packets = 0
        while !remaining.isEmpty {
            let packet = try #require(SurfacePatchPacket(raster: source, tiles: remaining, maximumBytes: 8 * 1024))
            #expect(packet.data.count <= 8 * 1024)
            #expect(!packet.tiles.isEmpty)
            #expect(packet.tiles == Array(remaining.prefix(packet.tiles.count)))
            let previous = canvas
            let previousRaster = try #require(SurfaceRaster(previous))
            let parsed = try SurfacePatchPacket(packet.data)
            #expect(parsed.tiles == packet.tiles)
            #expect(parsed.width == 289 && parsed.height == 193)
            canvas = try parsed.applying(to: previous)
            #expect(try #require(SurfaceRaster(previous)).changedTiles(comparedTo: previousRaster).isEmpty)
            remaining.removeFirst(packet.tiles.count)
            packets += 1
            #expect(packets <= source.tileCount)
        }
        #expect(try #require(SurfaceRaster(canvas)).changedTiles(comparedTo: source).isEmpty)
        #expect(try #require(SurfaceRaster(blank)).changedTiles(comparedTo: blankRaster).isEmpty)
        #expect(try #require(SurfaceRaster(canvas)).changedTiles(comparedTo: blankRaster).count == 70)
    }

    @Test func fullPacketNeedsNoBaseButPartialPacketRequiresOneAndScalesIt() throws {
        let source = try #require(SurfaceRaster(image(width: 97, height: 96, changed: [(96, 0), (1, 95)])))
        let full = try #require(SurfacePatchPacket(raster: source, tiles: Array(0..<12)))
        #expect(try #require(SurfaceRaster(SurfacePatchPacket(full.data).applying(to: nil))).changedTiles(comparedTo: source).isEmpty)
        let partial = try #require(SurfacePatchPacket(raster: source, tiles: [3]))
        #expect(throws: (any Error).self) { try partial.applying(to: nil) }
        let scaled = try partial.applying(to: image(width: 2, height: 2))
        let expected = try #require(SurfaceRaster(image(width: 97, height: 96, changed: [(96, 0)])))
        #expect(try #require(SurfaceRaster(scaled)).changedTiles(comparedTo: expected).isEmpty)
        #expect(SurfacePatchPacket(raster: source, tiles: [-1]) == nil)
        #expect(SurfacePatchPacket(raster: source, tiles: [12]) == nil)
        #expect(SurfacePatchPacket(raster: source, tiles: [0, 0]) == nil)
        #expect(SurfacePatchPacket(raster: source, tiles: [0], maximumBytes: 16) == nil)
        #expect(SurfacePatchPacket(raster: source, tiles: [0], maximumBytes: 48 * 1024 + 1) == nil)
        #expect(SurfacePatchPacket(raster: source, tiles: [0], isCancelled: { true }) == nil)
    }

    @Test func malformedDimensionsLengthsOverlapsAndImageSizesAreRejected() throws {
        let source = try #require(SurfaceRaster(image(width: 192, height: 96)))
        let packet = try #require(SurfacePatchPacket(raster: source, tiles: [0, 1]))
        var variants: [Data] = [Data(), Data(packet.data.dropLast()), packet.data + Data([0]), Data(repeating: 0, count: 48 * 1024 + 1)]
        for (offset, value): (Int, UInt32) in [(4, 0), (4, UInt32.max), (8, UInt32.max), (12, UInt32.max), (16, 1), (24, 95), (32, UInt32.max)] {
            var malformed = packet.data
            word(value, at: offset, in: &malformed)
            variants.append(malformed)
        }
        let firstLength = packet.data[32..<36].reduce(0) { ($0 << 8) | Int($1) }
        var overlap = packet.data
        word(0, at: 36 + firstLength, in: &overlap)
        variants.append(overlap)
        var wrongPNGSize = packet.data
        word(31, at: 4, in: &wrongPNGSize)
        word(1, at: 12, in: &wrongPNGSize)
        word(31, at: 24, in: &wrongPNGSize)
        wrongPNGSize.removeSubrange((36 + firstLength)..<wrongPNGSize.count)
        variants.append(wrongPNGSize)
        var trailingPNG = packet.data
        trailingPNG.removeSubrange((36 + firstLength)..<trailingPNG.count)
        word(1, at: 12, in: &trailingPNG)
        trailingPNG.append(0)
        word(UInt32(firstLength + 1), at: 32, in: &trailingPNG)
        variants.append(trailingPNG)
        for malformed in variants {
            #expect(throws: (any Error).self) { try SurfacePatchPacket(malformed) }
        }
    }
}
