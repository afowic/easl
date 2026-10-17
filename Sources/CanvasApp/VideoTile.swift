import AppKit
import CanvasCore

@MainActor
final class VideoTile: NSView, TileContent {
    private let page: HtmlTile
    private var object: CanvasObject

    init(object: CanvasObject, board: Board, files: HostFiles? = nil) {
        self.object = object
        page = HtmlTile(object: Self.pageObject(object), board: board, files: files)
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        page.frame = bounds
        page.autoresizingMask = [.width, .height]
        addSubview(page)
    }

    required init?(coder: NSCoder) { fatalError("unused") }
    nonisolated override var isFlipped: Bool { true }

    private static func pageObject(_ object: CanvasObject) -> CanvasObject {
        func attribute(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func asset(_ path: String) -> String {
            let path = URL(string: path).flatMap { $0.isFileURL ? $0.path : nil } ?? path
            var url = URLComponents()
            url.scheme = HtmlKit.scheme
            url.host = HtmlKit.host
            url.path = path.hasPrefix("/") ? path : "/" + path
            return attribute(url.string ?? "")
        }
        let props = object.props
        let flags = ["loop", "muted", "autoplay"].filter { props[$0] == .bool(true) }.joined(separator: " ")
        let poster = props["poster"]?.string.map { "poster=\"\(asset($0))\"" } ?? ""
        let start = max(0, props["startTime"]?.number ?? 0)
        let html = """
        <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#111}video{width:100%;height:100%;object-fit:contain}</style>
        <video controls playsinline preload="metadata" src="\(asset(props["path"]?.string ?? ""))" \(poster) \(flags)></video>
        <script>const video=document.querySelector('video');video.addEventListener('loadedmetadata',()=>{video.currentTime=\(start)},{once:true});</script>
        """
        var page = object
        page.type = .html
        page.props = .object(["html": .string(html)])
        return page
    }

    func setLive(_ live: Bool) { page.setLive(live) }
    func render(_ request: TileRenderRequest) async -> TileRender { await page.render(request) }
    func cardSnapshot(_ deliver: @escaping @MainActor (NSImage?) -> Void) { page.cardSnapshot(deliver) }
    func whenLiveReady(_ ready: @escaping @MainActor () -> Void) { page.whenLiveReady(ready) }
    func showSnapshot(_ show: Bool) { page.showSnapshot(show) }
    func prepareSnapshot() async { await page.prepareSnapshot() }
    func mentionTarget(at point: NSPoint) -> MentionTarget? { .object(object.id) }
    func outline(for target: MentionTarget) -> NSRect? { bounds }
    var takesKeyboardFocus: Bool { false }
    var surfaceLuminance: Double? { 0 }

    func update(_ object: CanvasObject) {
        self.object = object
        page.update(Self.pageObject(object))
    }
}
