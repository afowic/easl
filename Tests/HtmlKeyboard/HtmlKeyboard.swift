import AppKit
import WebKit

@testable import CanvasApp
@testable import CanvasCore

/// An HTML tile's page takes the keyboard for its text fields: Return on the selected tile or a
/// click in a field, and the canvas takes it back on Esc or a click on the board. A page that
/// focuses a field on its own never captures keys. Runs local and remote boards.
@main
@MainActor
private enum HtmlKeyboard {
    private struct Failure: Error { let message: String }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
            throw Failure(message: message)
        }
    }

    private static func check(_ message: String) {
        FileHandle.standardOutput.write(Data("CHECK \(message)\n".utf8))
    }

    private static func key(_ code: UInt16, _ characters: String, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    /// Straight to the window's responder chain: the runner never activates a window on the
    /// machine it runs on, so an application-level key event would look for a key window tests
    /// don't have.
    private static func post(_ event: NSEvent, in window: NSWindow) {
        window.sendEvent(event)
    }

    private static func js(_ web: WKWebView, _ expression: String) async -> Any? {
        (try? await web.evaluateJavaScript(expression)) as Any?
    }

    private static func wait(until condition: @MainActor () -> Bool, _ message: String,
                             limit: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw Failure(message: message)
    }

    /// The quiz page: two fields that persist what is typed in them, the first focused as the
    /// page loads (DOM focus only: the page never takes the keyboard itself).
    private static func pageHTML() -> String {
        """
        <!doctype html><html><body style="margin:0;padding:8px;font-family:sans-serif">
        <p id="plain" style="height:40px">Plain page text.</p>
        <textarea id="thinking" style="display:block;width:320px;height:60px"></textarea>
        <textarea id="next" style="display:block;width:320px;height:60px"></textarea>
        <script>
        const kit = window.canvasKit;
        const wire = (field, key) => {
          if (!kit) return;
          field.addEventListener('input', () => kit.setState(key, field.value));
          kit.getState(key).then((value) => { if (typeof value === 'string' && !field.value) field.value = value; });
        };
        const thinking = document.getElementById('thinking');
        const next = document.getElementById('next');
        wire(thinking, 'thinking');
        wire(next, 'next');
        const focus = () => thinking.focus();
        focus();
        setTimeout(focus, 400);
        // The page's own Esc wins once (a dialog closes); the next one is the canvas's.
        document.addEventListener('keydown', (event) => {
          if (event.key !== 'Escape' || window.escaped) return;
          event.preventDefault();
          window.escaped = true;
        });
        </script></body></html>
        """
    }

    private static func htmlTile(_ canvas: CanvasView, _ object: CanvasObject) throws -> HtmlTile {
        guard let tile = canvas.tiles[object.id], let html = tile.content as? HtmlTile else {
            throw Failure(message: "\(object.id) is not an HTML tile")
        }
        return html
    }

    private static func page(in html: HtmlTile) async throws -> WKWebView {
        for _ in 0..<400 {
            if let web = html.webView { return web }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure(message: "HTML tile built no web view")
    }

    private static func loaded(_ web: WKWebView) async throws {
        for _ in 0..<240 {
            if let state = await js(web, "document.readyState") as? String, state == "complete" { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure(message: "the HTML page did not load")
    }

    /// A click straight to the page's view, as AppKit's hit-tested dispatch delivers it. Posted
    /// mouse events would wait for a key window that an unactivated test window never has.
    private static func click(_ selector: String, in web: WKWebView, window: NSWindow) async throws {
        guard let rect = await js(web, "document.querySelector('\(selector)').getBoundingClientRect().toJSON()") as? [String: Any],
              let x = rect["x"] as? Double, let y = rect["y"] as? Double else {
            throw Failure(message: "the page has no \(selector) to click")
        }
        let point = web.convert(NSPoint(x: x + 4, y: y + 4), to: nil)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            throw Failure(message: "could not build the click")
        }
        web.mouseDown(with: down)
        web.mouseUp(with: up)
    }

    private static func typed(_ text: String, in window: NSWindow) {
        for character in text { post(key(0, String(character), in: window), in: window) }
    }

    private static func state(_ board: Board, _ id: ObjectID, _ key: String) -> String? {
        board.objects[id]?.props["state"]?[key]?.string
    }

    static func main() async throws {
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"] else {
            fatalError("run.py must provide a disposable EASL_HOME")
        }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let root = URL(fileURLWithPath: home).appendingPathComponent("board", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await exercise(root: root, remote: nil, kind: "local")
        let host = RemoteHost(name: "html-keyboard-regression", sshTarget: "html-keyboard-regression.invalid",
                              socketPath: root.appendingPathComponent("absent.sock").path,
                              tmpdir: root.path, easlBin: "easl")
        let absent = EaslConnection(.unixSocket(host.socketPath))
        let mirror = BoardMirror(hostName: host.name, board: "html-keyboard-remote",
                                 connection: absent, diagrams: EaslConnection(.unixSocket(host.socketPath)))
        try await exercise(root: root, remote: RemoteSource(host: host, mirror: mirror), kind: "remote")
        print("PASS HTML tile keyboard: Return, click into a field, Tab, Esc, board click, and no focus from a page on load (local and remote)")
    }

    private static func exercise(root: URL, remote: RemoteSource?, kind: String) async throws {
        let board = remote.map { Board(remote: "html-keyboard-\(kind)", root: root, host: $0.mirror) }
            ?? Board(id: "html-keyboard-\(kind)", root: root)
        let canvas = CanvasView(board: board, viewport: nil, remote: remote)
        canvas.hasHorizontalScroller = false
        canvas.hasVerticalScroller = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        board.onEvent = { canvas.apply($0) }
        defer {
            board.onEvent = nil
            canvas.discard()
            window.close()
        }
        window.orderFrontRegardless()
        let frame = Frame(x: -350, y: -250, w: 700, h: 500)
        let shown = CanvasView.docRect(frame)
        canvas.show(Viewport(rect: Frame(x: frame.x - 60, y: frame.y - 60, w: frame.w + 120, h: frame.h + 120), zoom: 1))
        try await Task.sleep(for: .milliseconds(250))
        window.makeFirstResponder(canvas.document)

        // Return on the selected tile gives the page the keyboard. The page's own field has DOM
        // focus but not the keyboard until then; typed text reaches the page's state, and Tab
        // moves to the next field. Esc hands the keyboard back with the tile selected.
        let returned = board.create(type: .html, props: .object(["title": .string("Quiz \(kind)"),
                                                                 "html": .string(pageHTML())]), frame: frame)
        let typing = try htmlTile(canvas, returned)
        let typingPage = try await page(in: typing)
        try await loaded(typingPage)
        try await Task.sleep(for: .milliseconds(500))
        canvas.setSelection([returned.id])
        try require(window.makeFirstResponder(canvas.document), "the canvas document must take the keyboard")
        try require(typingPage.acceptsFirstResponder == false, "the page must not accept the keyboard before the user asks")
        post(key(36, "\r", in: window), in: window)
        try await wait(until: { window.firstResponder === typingPage }, "Return must give the page the keyboard")
        typed("hello", in: window)
        try await wait(until: { state(board, returned.id, "thinking") == "hello" }, "typed text must reach props.state")
        // Delete in a field is the page's: it must not delete the tile or clear the selection.
        post(key(51, "\u{7f}", in: window), in: window)
        try await Task.sleep(for: .milliseconds(250))
        try require(board.objects[returned.id] != nil && canvas.selection == [returned.id],
                    "a key in the page must not act on the canvas")
        post(key(48, "\t", in: window), in: window)
        typed("!", in: window)
        try await wait(until: { state(board, returned.id, "next") == "!" }, "Tab must move to the next field in the page")
        check("Return and Tab type into \(kind) props.state; page keys never act on the canvas")
        // Delete with no field focused must stay in the page: it would otherwise delete the
        // tile and clear the selection.
        _ = await js(typingPage, "document.activeElement.blur()")
        try await Task.sleep(for: .milliseconds(150))
        let bodyFocused = await js(typingPage, "document.activeElement === document.body") as? Bool
        try require(bodyFocused == true, "the fixture must blur out of its fields")
        post(key(51, "\u{7f}", in: window), in: window)
        try await Task.sleep(for: .milliseconds(250))
        try require(board.objects[returned.id] != nil && canvas.selection == [returned.id],
                    "Delete in the page must not act on the canvas")
        post(key(53, "\u{1b}", in: window), in: window)
        try await Task.sleep(for: .milliseconds(300))
        let escaped = await js(typingPage, "window.escaped") as? Bool
        try require(escaped == true, "the page must see its own Esc")
        try require(window.firstResponder === typingPage, "an Esc the page handles must stay in the page")
        post(key(53, "\u{1b}", in: window), in: window)
        try await wait(until: { window.firstResponder === canvas.document }, "Esc must give the keyboard back to the canvas")
        try require(canvas.selection == [returned.id], "Esc must leave the tile selected")
        post(key(51, "\u{7f}", in: window), in: window)
        try await wait(until: { board.objects[returned.id] == nil }, "a canvas key must act after Esc")
        check("Esc returns \(kind) keyboard to the canvas and canvas keys act again")

        // A click in a text field takes the keyboard; a click on plain page text and a click on
        // the board leave it with the canvas.
        let clicked = board.create(type: .html, props: .object(["title": .string("Quiz click \(kind)"),
                                                                "html": .string(pageHTML())]), frame: frame)
        let clickTile = try htmlTile(canvas, clicked)
        let clickPage = try await page(in: clickTile)
        try await loaded(clickPage)
        try await Task.sleep(for: .milliseconds(500))
        canvas.setSelection([clicked.id])
        try require(window.makeFirstResponder(canvas.document), "the canvas must hold the keyboard before the click")
        try await click("#next", in: clickPage, window: window)
        try await wait(until: { window.firstResponder === clickPage }, "a click in a text field must give the page the keyboard")
        typed("clicked", in: window)
        try await wait(until: { state(board, clicked.id, "next") == "clicked" }, "clicked text must reach props.state")
        check("clicking a text field gives \(kind) the page the keyboard: clicked")
        // The page takes its own first Esc; the next one is the canvas's.
        post(key(53, "\u{1b}", in: window), in: window)
        try await Task.sleep(for: .milliseconds(250))
        post(key(53, "\u{1b}", in: window), in: window)
        try await wait(until: { window.firstResponder === canvas.document }, "Esc must leave the clicked page")
        try await click("#plain", in: clickPage, window: window)
        try await Task.sleep(for: .milliseconds(250))
        try require(window.firstResponder === canvas.document, "a click on plain page text must leave the keyboard with the canvas")
        guard let boardClick = NSEvent.mouseEvent(with: .leftMouseDown, location: shown.origin, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            throw Failure(message: "could not build the board click")
        }
        canvas.emptyMouseDown(boardClick)
        try require(window.firstResponder === canvas.document, "a board click must leave the keyboard with the canvas")
        check("plain page text and the board never take \(kind) keyboard")

        // A page that focuses a field by itself keeps DOM focus but not the keyboard; typing stays
        // with the canvas and Delete still acts on the board.
        canvas.setSelection([])
        try require(window.makeFirstResponder(canvas.document), "the canvas must hold the keyboard before the page loads")
        let autofocus = board.create(type: .html, props: .object(["title": .string("Autofocus \(kind)"),
                                                                  "html": .string(pageHTML())]), frame: frame)
        let autoTile = try htmlTile(canvas, autofocus)
        let autoPage = try await page(in: autoTile)
        try await loaded(autoPage)
        try await Task.sleep(for: .milliseconds(900))
        let active = await js(autoPage, "document.activeElement.id") as? String
        try require(active == "thinking", "the fixture must focus its own field")
        try require(window.firstResponder === canvas.document, "a page focusing a field on load must not capture keys")
        typed("x", in: window)
        try await Task.sleep(for: .milliseconds(300))
        let typedIntoPage = await js(autoPage, "document.getElementById('thinking').value") as? String
        try require(typedIntoPage == "", "keys must not reach a page that focused its own field")
        try require(state(board, autofocus.id, "thinking") == nil, "a page focusing its own field must not receive typed text")
        check("a \(kind) page focusing a field on load does not capture keys")
        canvas.setSelection([autofocus.id])
        post(key(51, "\u{7f}", in: window), in: window)
        try await wait(until: { board.objects[autofocus.id] == nil }, "Delete with the canvas keyboard must delete the selected tile")
        check("canvas keys act after a \(kind) page focused its own field")
    }
}
