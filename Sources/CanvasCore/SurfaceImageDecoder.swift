import Foundation
import CoreGraphics
import ImageIO

public enum SurfaceImageDecoder {
    private enum Failure: Error { case invalidImage }

    public static func decode(_ data: Data, format: SurfaceFormat, width: Int, height: Int,
                              canvas: CGSize, damage: CGRect?, previous: CGImage?,
                              video: SurfaceVideoDecoder) throws -> CGImage {
        guard width > 0, height > 0, width <= SurfaceEvent.Frame.maxPixels / height,
              canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0,
              canvas.width * canvas.height <= Double(SurfaceEvent.Frame.maxPixels) else { throw Failure.invalidImage }
        if let damage {
            guard damage.minX.isFinite, damage.minY.isFinite, damage.width.isFinite, damage.height.isFinite,
                  damage.minX >= 0, damage.minY >= 0, damage.width > 0, damage.height > 0,
                  damage.maxX <= canvas.width, damage.maxY <= canvas.height else { throw Failure.invalidImage }
        }
        if format == .patch {
            let patch = try SurfacePatchPacket(data)
            guard patch.width == width, patch.height == height,
                  Double(width) == canvas.width, Double(height) == canvas.height else { throw Failure.invalidImage }
            return try patch.applying(to: previous)
        }
        let image: CGImage
        if format == .h264 {
            guard data.count <= 48 * 1024 else { throw Failure.invalidImage }
            image = try video.decode(data, width: width, height: height)
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
                  (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height,
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw Failure.invalidImage
            }
            image = decoded
        }
        guard let result = SurfaceImagePresentation.composite(image, onto: previous, canvas: canvas, damage: damage) else {
            throw Failure.invalidImage
        }
        return result
    }
}
