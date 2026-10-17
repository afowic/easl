import AVFoundation
import Foundation

public enum LocalVideo {
    public static func problem(_ props: JSONValue) -> String? {
        guard let path = props["path"]?.string, !path.isEmpty else { return "a video needs props.path" }
        for key in ["poster", "title"] where props[key] != nil {
            if props[key]?.string == nil { return "video props.\(key) must be a string" }
        }
        for key in ["loop", "muted", "autoplay"] where props[key] != nil {
            if case .bool = props[key]! {} else { return "video props.\(key) must be a boolean" }
        }
        if let value = props["startTime"], value.number == nil || !value.number!.isFinite || value.number! < 0 {
            return "video props.startTime must be a nonnegative number"
        }
        return nil
    }

    public static func authorizedURL(path: String, root: URL) -> URL? {
        guard let candidate = LocalImage.candidate(path, root: root.path) else { return nil }
        let requested = URL(fileURLWithPath: candidate).standardizedFileURL
        let root = root.standardizedFileURL
        func inside(_ file: URL, _ directory: URL) -> Bool {
            directory.path == "/" || file.path == directory.path || file.path.hasPrefix(directory.path + "/")
        }
        guard inside(requested, root) else { return nil }
        let resolved = requested.resolvingSymlinksInPath()
        guard inside(resolved, root.resolvingSymlinksInPath()) else { return nil }
        return resolved
    }

    public static func naturalSize(of url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ObjectMeasure.Failure.unavailable("no readable video track")
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let display = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
        guard display.width.isFinite, display.height.isFinite, display.width > 0, display.height > 0 else {
            throw ObjectMeasure.Failure.unavailable("video dimensions are unavailable")
        }
        return display
    }
}
