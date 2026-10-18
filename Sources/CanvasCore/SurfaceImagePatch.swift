import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private let patchTileEdge = 32
private let patchColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
private let patchBitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

private func patchDimensions(_ width: Int, _ height: Int) -> Bool {
    width > 0 && height > 0 && width <= 4_000_000 / height
}

private enum SurfacePatchError: Error {
    case invalidPacket, invalidImage, missingBase
}

public struct SurfaceRaster: @unchecked Sendable {
    public let width: Int
    public let height: Int
    private let pixels: CFData
    private let bytesPerRow: Int
    public let image: CGImage

    public init?(_ image: CGImage) {
        guard patchDimensions(image.width, image.height) else { return nil }
        width = image.width
        height = image.height
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32,
           image.bitmapInfo.rawValue == patchBitmapInfo,
           image.colorSpace == patchColorSpace, image.decode == nil,
           image.bytesPerRow >= width * 4,
           image.bytesPerRow <= Int.max / height,
           let data = image.dataProvider?.data,
           CFDataGetLength(data) >= image.bytesPerRow * height {
            pixels = data
            bytesPerRow = image.bytesPerRow
            self.image = image
        } else {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: patchColorSpace, bitmapInfo: patchBitmapInfo) else { return nil }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let normalized = context.makeImage(), let data = normalized.dataProvider?.data else { return nil }
            pixels = data
            bytesPerRow = normalized.bytesPerRow
            self.image = normalized
        }
    }

    public var tileCount: Int { columns * ((height + patchTileEdge - 1) / patchTileEdge) }
    private var columns: Int { (width + patchTileEdge - 1) / patchTileEdge }

    fileprivate func rect(_ tile: Int) -> CGRect {
        let x = tile % columns * patchTileEdge
        let y = tile / columns * patchTileEdge
        return CGRect(x: x, y: y, width: min(patchTileEdge, width - x), height: min(patchTileEdge, height - y))
    }

    public func changedTiles(comparedTo previous: SurfaceRaster?) -> [Int] {
        guard let previous, previous.width == width, previous.height == height else { return Array(0..<tileCount) }
        let currentBytes = CFDataGetBytePtr(pixels)!
        let previousBytes = CFDataGetBytePtr(previous.pixels)!
        return (0..<tileCount).filter { tile in
            let area = rect(tile)
            let x = Int(area.minX), y = Int(area.minY)
            for row in y..<(y + Int(area.height)) {
                if memcmp(currentBytes + row * bytesPerRow + x * 4,
                          previousBytes + row * previous.bytesPerRow + x * 4, Int(area.width) * 4) != 0 { return true }
            }
            return false
        }
    }

    public func damageBounds(comparedTo previous: SurfaceRaster?, changedTiles: [Int]? = nil) -> CGRect? {
        guard let previous, previous.width == width, previous.height == height else {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }
        let changed = changedTiles ?? self.changedTiles(comparedTo: previous)
        guard !changed.isEmpty else { return nil }
        if changed.count > 16 {
            return changed.reduce(CGRect.null) { $0.union(rect($1)) }
        }
        let currentBytes = CFDataGetBytePtr(pixels)!
        let previousBytes = CFDataGetBytePtr(previous.pixels)!
        var minX = width, minY = height, maxX = 0, maxY = 0
        for tile in changed {
            let area = rect(tile)
            for y in Int(area.minY)..<Int(area.maxY) {
                for x in Int(area.minX)..<Int(area.maxX) {
                    if memcmp(currentBytes + y * bytesPerRow + x * 4,
                              previousBytes + y * previous.bytesPerRow + x * 4, 4) != 0 {
                        minX = min(minX, x); minY = min(minY, y)
                        maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                }
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    fileprivate func copyPixels(to destination: UnsafeMutableRawPointer, stride: Int, x: Int = 0, y: Int = 0) {
        let source = CFDataGetBytePtr(pixels)!
        for row in 0..<height {
            memcpy(destination + (y + row) * stride + x * 4, source + row * bytesPerRow, width * 4)
        }
    }
}

public struct SurfacePatchPacket: Sendable {
    public static let maximumBytes = 48 * 1024
    public let data: Data
    public let tiles: [Int]
    public let width: Int
    public let height: Int

    private struct Tile: Sendable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let png: Data
        let decoded: SurfaceRaster?
    }
    private let entries: [Tile]

    public init?(raster: SurfaceRaster, tiles: [Int], maximumBytes: Int = Self.maximumBytes,
                 isCancelled: @Sendable () -> Bool = { false }) {
        guard !tiles.isEmpty, maximumBytes > 16, maximumBytes <= Self.maximumBytes,
              !isCancelled() else { return nil }
        var encoded = Data([69, 83, 80, 49])
        Self.append(raster.width, to: &encoded)
        Self.append(raster.height, to: &encoded)
        Self.append(0, to: &encoded)
        var included: [Int] = []
        var entries: [Tile] = []
        var seen = Set<Int>()
        for tile in tiles {
            guard !isCancelled() else { return nil }
            guard tile >= 0, tile < raster.tileCount, seen.insert(tile).inserted else { return nil }
            let area = raster.rect(tile)
            guard let image = raster.image.cropping(to: area) else { return nil }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            guard !isCancelled() else { return nil }
            guard encoded.count + 20 + png.length <= maximumBytes else { break }
            for value in [Int(area.minX), Int(area.minY), Int(area.width), Int(area.height), png.length] {
                Self.append(value, to: &encoded)
            }
            let bytes = png as Data
            encoded.append(bytes)
            included.append(tile)
            entries.append(Tile(x: Int(area.minX), y: Int(area.minY), width: Int(area.width), height: Int(area.height), png: bytes, decoded: nil))
        }
        guard !included.isEmpty else { return nil }
        var count = UInt32(included.count).bigEndian
        withUnsafeBytes(of: &count) { encoded.replaceSubrange(12..<16, with: $0) }
        data = encoded
        self.tiles = included
        width = raster.width
        height = raster.height
        self.entries = entries
    }

    public init(_ data: Data) throws {
        guard data.count >= 16, data.count <= Self.maximumBytes else { throw SurfacePatchError.invalidPacket }
        var offset = 0
        func read() throws -> Int {
            guard offset <= data.count - 4 else { throw SurfacePatchError.invalidPacket }
            defer { offset += 4 }
            return data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            }
        }
        guard try read() == 0x45535031 else { throw SurfacePatchError.invalidPacket }
        let width = try read(), height = try read(), count = try read()
        guard patchDimensions(width, height), count > 0, count <= (data.count - 16) / 21 else { throw SurfacePatchError.invalidPacket }
        let columns = (width + patchTileEdge - 1) / patchTileEdge
        var tiles: [Int] = []
        var entries: [Tile] = []
        var seen = Set<Int>()
        for _ in 0..<count {
            let x = try read(), y = try read(), w = try read(), h = try read(), length = try read()
            guard x < width, y < height, x % patchTileEdge == 0, y % patchTileEdge == 0,
                  w == min(patchTileEdge, width - x), h == min(patchTileEdge, height - y),
                  length > 0, length <= data.count - offset else { throw SurfacePatchError.invalidPacket }
            let tile = y / patchTileEdge * columns + x / patchTileEdge
            guard seen.insert(tile).inserted else { throw SurfacePatchError.invalidPacket }
            let png = data.subdata(in: offset..<(offset + length))
            offset += length
            guard let decoded = SurfaceRaster(try Self.decode(png, width: w, height: h)) else { throw SurfacePatchError.invalidImage }
            tiles.append(tile)
            entries.append(Tile(x: x, y: y, width: w, height: h, png: png, decoded: decoded))
        }
        guard offset == data.count else { throw SurfacePatchError.invalidPacket }
        self.data = data
        self.tiles = tiles
        self.width = width
        self.height = height
        self.entries = entries
    }

    public func applying(to image: CGImage?) throws -> CGImage {
        let totalTiles = ((width + patchTileEdge - 1) / patchTileEdge) * ((height + patchTileEdge - 1) / patchTileEdge)
        guard image != nil || entries.count == totalTiles else { throw SurfacePatchError.missingBase }
        var canvas = Data(count: width * height * 4)
        try canvas.withUnsafeMutableBytes { bytes in
            let destination = bytes.baseAddress!
            if let image, entries.count != totalTiles {
                let base: SurfaceRaster?
                if image.width == width, image.height == height {
                    base = SurfaceRaster(image)
                } else {
                    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: patchColorSpace, bitmapInfo: patchBitmapInfo) else { throw SurfacePatchError.invalidImage }
                    context.setBlendMode(.copy)
                    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                    base = context.makeImage().flatMap(SurfaceRaster.init)
                }
                guard let base else { throw SurfacePatchError.invalidImage }
                base.copyPixels(to: destination, stride: width * 4)
            }
            for tile in entries {
                let raster: SurfaceRaster
                if let decoded = tile.decoded { raster = decoded }
                else {
                    let image = try Self.decode(tile.png, width: tile.width, height: tile.height)
                    guard let decoded = SurfaceRaster(image) else { throw SurfacePatchError.invalidImage }
                    raster = decoded
                }
                raster.copyPixels(to: destination, stride: width * 4, x: tile.x, y: tile.y)
            }
        }
        guard let provider = CGDataProvider(data: canvas as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: patchColorSpace, bitmapInfo: CGBitmapInfo(rawValue: patchBitmapInfo),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw SurfacePatchError.invalidImage }
        return result
    }

    private static func decode(_ png: Data, width: Int, height: Int) throws -> CGImage {
        try png.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            func word(_ offset: Int) -> Int {
                return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                    | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            }
            guard png.count >= 45, png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
                  word(8) == 13, word(12) == 0x49484452,
                  word(16) == width, word(20) == height else { throw SurfacePatchError.invalidImage }
            var offset = 8
            var ended = false
            while offset <= bytes.count - 12 {
                let length = word(offset)
                guard length <= bytes.count - offset - 12 else { throw SurfacePatchError.invalidImage }
                let kind = word(offset + 4)
                offset += length + 12
                if kind == 0x49454e44 {
                    guard length == 0, offset == bytes.count else { throw SurfacePatchError.invalidImage }
                    ended = true
                    break
                }
            }
            guard ended else { throw SurfacePatchError.invalidImage }
        }
        guard png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height else { throw SurfacePatchError.invalidImage }
        return image
    }

    private static func append(_ value: Int, to data: inout Data) {
        var value = UInt32(value).bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
