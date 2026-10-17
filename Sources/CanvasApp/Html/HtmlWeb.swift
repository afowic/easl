import AppKit
import CanvasCore
import CryptoKit
import WebKit

/// Compiled local allowlists and the fixed remote connection-hint guard, shared by HTML tiles.
@MainActor
enum HtmlRuleLists {
    private static var compiled: [String: WKContentRuleList] = [:]

    static func list(allowing hosts: [String]) async throws -> WKContentRuleList {
        try await compile(HtmlKit.networkRules(allow: hosts))
    }

    /// CSP does not constrain DNS prefetch or preconnect. Never compile host data for a remote page.
    /// WebKit classifies these hints as pings, so this also refuses anchor link pings.
    static func remote() async throws -> WKContentRuleList {
        try await compile(#"[{"trigger":{"url-filter":"^https?:","resource-type":["ping"]},"action":{"type":"block"}}]"#)
    }

    private static func compile(_ json: String) async throws -> WKContentRuleList {
        let identifier = "canvas-html-" + SHA256.hash(data: Data(json.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        if let list = compiled[identifier] { return list }
        guard let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else {
            throw HtmlError.malformed("content rule list \(identifier) did not compile")
        }
        compiled[identifier] = list
        return list
    }
}

@MainActor
final class HtmlSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var tile: HtmlTile? {
        didSet {
            if oldValue !== tile {
                for read in reads.values { read.cancel() }
                reads.removeAll()
            }
        }
    }
    private static let kitRoot = AppPaths.asset("kit")
    private static var kitCache: [String: Data] = [:]
    private var reads: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(tile: HtmlTile?) {
        self.tile = tile
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == HtmlKit.host, let tile else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        guard !tile.isRemote || tile.files != nil else {
            return task.didFailWithError(URLError(.cannotConnectToHost))
        }
        if url.path == HtmlKit.pageURL(tile: tile.objectID).path {
            if webView === tile.webView { tile.resetAssetWatches() }
            respond(task, url: url, data: Data(tile.document.utf8), type: "text/html", cache: "no-store")
            return
        }
        if let kitRoot = Self.kitRoot, let file = HtmlKit.kitFile(requestPath: url.path, kitRoot: kitRoot),
           let data = Self.kitCache[file.path] ?? (try? Data(contentsOf: file, options: .alwaysMapped)) {
            Self.kitCache[file.path] = data
            respond(task, url: url, data: data, type: HtmlKit.mimeType(file), cache: "max-age=31536000, immutable")
            return
        }
        let method = task.request.httpMethod ?? "GET"
        guard method == "GET" || method == "HEAD" else {
            return respond(task, url: url, data: Data(), type: "text/plain", cache: "no-store", status: 405)
        }
        let key = ObjectIdentifier(task)
        let files = tile.files
        let source = tile.isRemote ? tile.hostImageSource : .directory(tile.boardRoot.path)
        let assetPath = url.path.hasPrefix(tile.boardRoot.path + "/") ? url.path : String(url.path.drop(while: { $0 == "/" }))
        var request = HostFileRequest(source: source, policy: .boardAsset(assetPath), bytes: false)
        let live = webView === tile.webView
        reads[key] = Task { @MainActor [weak self, weak tile] in
            guard let self, let tile else { return }
            var began = false
            do {
                let metadata: HostFile
                do {
                    metadata = try await Self.read(request, files: files)
                } catch {
                    guard let fallback = LocalImage.hostPageFile(requestPath: url.path, source: source,
                                                                 temps: files?.temps ?? FollowFilter.tempDirectories) else { throw error }
                    var imageRequest = fallback
                    imageRequest.bytes = false
                    metadata = try await Self.read(imageRequest, files: files)
                    request = imageRequest
                }
                guard self.reads[key] != nil, !Task.isCancelled else { return }
                if live { tile.observeAsset(url.path, request: request, baseline: .version(metadata.version)) }
                let selection: MediaByteRange
                do {
                    selection = try MediaByteRange(header: task.request.value(forHTTPHeaderField: "Range"), size: metadata.size)
                } catch {
                    self.head(task, url: url, type: metadata.mimeType, status: 416,
                              headers: ["Content-Range": "bytes */\(metadata.size)", "Content-Length": "0", "Accept-Ranges": "bytes"])
                    task.didFinish()
                    self.reads.removeValue(forKey: key)
                    return
                }
                self.head(task, url: url, type: metadata.mimeType, status: selection.partial ? 206 : 200,
                          headers: selection.headers(size: metadata.size))
                began = true
                if method != "HEAD" {
                    var offset = selection.bytes.lowerBound
                    request.bytes = true
                    while offset < selection.bytes.upperBound {
                        try Task.checkCancellation()
                        request.range = HostFileRange(offset: offset, length: Int(min(1_048_576, selection.bytes.upperBound - offset)))
                        let chunk = try await Self.read(request, files: files)
                        guard self.reads[key] != nil, !Task.isCancelled else { return }
                        guard chunk.version == metadata.version, chunk.size == metadata.size,
                              chunk.offset == offset, !chunk.data.isEmpty else { throw URLError(.resourceUnavailable) }
                        task.didReceive(chunk.data)
                        offset += Int64(chunk.data.count)
                    }
                }
                guard self.reads.removeValue(forKey: key) != nil, !Task.isCancelled else { return }
                task.didFinish()
            } catch {
                guard self.reads.removeValue(forKey: key) != nil, !Task.isCancelled else { return }
                if live {
                    tile.observeAsset(url.path, request: request,
                                      baseline: .failure(error as? HostFileError ?? .unavailable(String(describing: error))))
                }
                if began {
                    task.didFailWithError(error)
                } else {
                    self.respond(task, url: url, data: Data("not found".utf8), type: "text/plain", cache: "no-store", status: 404)
                }
            }
        }
    }

    private static func read(_ request: HostFileRequest, files: HostFiles?) async throws -> HostFile {
        if let files { return try await files.read(request) }
        return try await HostFiles.readLocal(request)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        reads.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    private func head(_ task: any WKURLSchemeTask, url: URL, type: String, status: Int, headers: [String: String]) {
        var headers = headers
        headers["Content-Type"] = type
        headers["Cache-Control"] = "no-store"
        if let policy = tile?.contentSecurityPolicy { headers["Content-Security-Policy"] = policy }
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, type: String, cache: String, status: Int = 200) {
        var headers = ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": cache]
        if let policy = tile?.contentSecurityPolicy { headers["Content-Security-Policy"] = policy }
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        if !data.isEmpty { task.didReceive(data) }
        task.didFinish()
    }
}

/// The page's one native channel (`window.webkit.messageHandlers.canvas`). Only the tile's own
/// top-level canvas-kit document may post; bodies are validated by `HtmlMessage` before use.
@MainActor
final class HtmlChannelHandler: NSObject, WKScriptMessageHandlerWithReply {
    /// As `HtmlSchemeHandler.tile`.
    weak var tile: HtmlTile?

    init(tile: HtmlTile?) {
        self.tile = tile
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let tile, message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == HtmlKit.scheme,
              let source = message.webView, source === tile.webView || source === tile.renderWebView else { return (nil, "not allowed") }
        guard let body = message.body as? [String: Any], JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return (nil, HtmlError.malformed("message must be an object").description) }
        do {
            let parsed = try HtmlMessage.parse(data)
            let reply = try await tile.handle(parsed, rendering: source === tile.renderWebView)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply), options: .fragmentsAllowed)
            return (object, nil)
        } catch let error as HtmlError {
            return (nil, error.description)
        } catch let error as BoardError {
            return (nil, "\(error)")
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}

/// HTML tiles never take keyboard focus: the prompt target terminal keeps it while the user
/// clicks through explainers. Clicks still work, including on the (never key) dev window.
final class HtmlWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var lastClick: (time: TimeInterval, flags: NSEvent.ModifierFlags)?

    /// The modifiers of the last click on the page when it was within `seconds` (a link the page
    /// follows just after one is the user's: the web view tells a script's navigation from a click
    /// only by its type, and `a.click()` looks like one).
    func recentClick(within seconds: TimeInterval = 2) -> NSEvent.ModifierFlags? {
        guard let lastClick, ProcessInfo.processInfo.systemUptime - lastClick.time <= seconds else { return nil }
        return lastClick.flags
    }

    override func mouseDown(with event: NSEvent) {
        lastClick = (ProcessInfo.processInfo.systemUptime, event.modifierFlags)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        lastClick = (ProcessInfo.processInfo.systemUptime, event.modifierFlags)
        super.mouseUp(with: event)
    }

    /// WebKit's context menu leads with Mention: the element under the right-click.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        CanvasView.insertMention(into: menu, in: self, for: event)
    }
}
