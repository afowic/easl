import AppKit
import JavaScriptCore

/// A note's ```mermaid fence drawn as a diagram by the vendored Pele build
/// (`resources/kit/vendor/pele.global.js`, MIT) running in JavaScriptCore: no web view, no
/// network, synchronous. Colors come from the note's appearance and are resolved into the SVG
/// before `NSImage` decodes it (CoreSVG doesn't resolve CSS variables). Decoded images are cached
/// by source, width, and appearance; the engine's one JSContext lives on its own queue, warmed at
/// launch, so the main thread only waits for a render.
@MainActor
public enum NoteDiagram {
    enum Outcome {
        case image(NSImage)
        /// Why Pele couldn't draw the source, shown under the fence's source rows.
        case failure(String)
    }

    private struct Key: Hashable {
        var source: String
        var width: Int
        var dark: Bool
    }

    private static let engine = PeleEngine()
    private static var cache: [Key: Outcome] = [:]
    private static var order: [Key] = []
    /// Enough for a board's visible diagrams at their note widths; a note's own renders repeat far
    /// more often than sources change.
    static let cacheLimit = 64

    /// Builds the JSContext and compiles the common parsers off the main thread, so the first
    /// diagram a launch shows doesn't pay for it. Called at app launch.
    public static func prewarm() {
        engine.prewarm()
    }

    /// `source` drawn at most `width` points wide for `appearance`.
    static func image(source: String, width: CGFloat, appearance: NSAppearance) -> Outcome {
        let width = max(1, width.rounded())
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = Key(source: source, width: Int(width), dark: dark)
        if let cached = cache[key] { return cached }
        let outcome = engine.render(source: source, width: width, theme: theme(appearance))
        cache[key] = outcome
        order.append(key)
        while order.count > cacheLimit {
            cache[order.removeFirst()] = nil
        }
        return outcome
    }

    /// The appearance diagrams are drawn for: the app's, which follows the system and the
    /// window's override. Tests and offscreen renders without an app take the default appearance.
    static func appearance() -> NSAppearance {
        if let app = NSApp { return app.effectiveAppearance }
        return NSAppearance.currentDrawing()
    }

    // MARK: Theme

    /// Pele's CSS variables as concrete colors: CoreSVG ignores `var()`, so they are resolved into
    /// the SVG before `NSImage` sees it. The light/dark choice is the note's appearance.
    static func theme(_ appearance: NSAppearance) -> [String: String] {
        var theme: [String: String] = [:]
        appearance.performAsCurrentDrawingAppearance {
            let base = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .white
            let colors: [String: NSColor] = [
                "bg": .textBackgroundColor,
                "fg": .labelColor,
                "muted": .secondaryLabelColor,
                "line": .labelColor,
                "surface": .windowBackgroundColor,
                "surface-alt": .underPageBackgroundColor,
                "border": .separatorColor,
                "accent": .controlAccentColor,
                "critical": .systemRed,
                "error": .systemRed,
            ]
            theme = colors.mapValues { hex($0, over: base) }
            for series in 1...8 { theme["series-\(series)"] = seriesColor(series, over: base) }
        }
        theme["font"] = PeleEngine.fontFamily
        theme["font-mono"] = PeleEngine.monoFontFamily
        theme["radius"] = "4px"
        return theme
    }

    /// A palette color of a chart drawn over `background`: translucent colors (a separator, a
    /// selection tint) flatten to an opaque one.
    private static func hex(_ color: NSColor, over background: NSColor) -> String {
        guard let color = color.usingColorSpace(.sRGB) else { return "#000000" }
        let alpha = color.alphaComponent
        let blend = { (value: CGFloat, base: CGFloat) in value * alpha + base * (1 - alpha) }
        return String(format: "#%02x%02x%02x",
                      Int((blend(color.redComponent, background.redComponent) * 255).rounded()),
                      Int((blend(color.greenComponent, background.greenComponent) * 255).rounded()),
                      Int((blend(color.blueComponent, background.blueComponent) * 255).rounded()))
    }

    /// Pele's default series colors for charts; they read on both appearances.
    private static func seriesColor(_ index: Int, over background: NSColor) -> String {
        let palette: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemRed, .systemTeal, .systemYellow, .systemPurple, .systemBrown]
        return hex(palette[index - 1], over: background)
    }

    /// `svg` with every Pele variable replaced by its value (and CoreSVG's unparseable
    /// `height:auto` dropped; the root's width and height attributes carry the size).
    nonisolated static func themed(_ svg: String, colors theme: [String: String]) -> String {
        var out = svg
        for (name, value) in theme {
            out = replacing(#"var\(--pele-\#(name),[^()]*\)"#, with: value, in: out)
            out = replacing(#"var\(--pele-\#(name)\)"#, with: value, in: out)
        }
        let aliases: [String: String] = [
            "bg": theme["bg"] ?? "#ffffff", "fg": theme["fg"] ?? "#1f1f1f",
            "m": theme["muted"] ?? "#6e6e6e", "l": theme["line"] ?? "#1f1f1f",
            "s": theme["surface"] ?? "#f3f3f3", "a": theme["surface-alt"] ?? "#e6e6e6",
            "b": theme["border"] ?? "#8a8a8a", "c": theme["accent"] ?? "#5b7bd5",
            "r": theme["radius"] ?? "4px", "fm": theme["font-mono"] ?? "monospace",
        ]
        for (alias, value) in aliases {
            out = replacing(#"var\(--_\#(alias)\)"#, with: value, in: out)
        }
        // Anything Pele left to a fallback (a chart's own palette, say) takes it; a variable with
        // no fallback has no meaning outside CSS.
        out = replacing(#"var\(--[^(),]+,\s*([^()]*)\)"#, with: "$1", in: out)
        out = replacing(#"var\(--[^(),]+\)"#, with: theme["fg"] ?? "#1f1f1f", in: out)
        return out.replacingOccurrences(of: "height:auto;", with: "")
    }

    private nonisolated static func replacing(_ pattern: String, with template: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }
}

/// Pele in JavaScriptCore. Its context is created and used only on `queue`; callers wait for a
/// render, which is a few milliseconds once the build's script and parsers are warm.
private final class PeleEngine: @unchecked Sendable {
    static let fontFamily = "Helvetica"
    static let monoFontFamily = "Menlo"
    static let fontSize: CGFloat = 13

    private let queue = DispatchQueue(label: "easl.note.diagram", qos: .userInitiated)
    private var context: JSContext?
    private var loaded = false

    /// The vendored script: the app bundle's Resources, `EASL_RESOURCES`, or the checkout the
    /// test runner runs from (`AppPaths.resources` resolves the same roots for the app).
    private static let script: String? = {
        var roots: [URL] = []
        if let override = ProcessInfo.processInfo.environment["EASL_RESOURCES"], !override.isEmpty {
            roots.append(URL(fileURLWithPath: override))
        }
        if let bundled = Bundle.main.resourceURL { roots.append(bundled) }
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("schema/easl-api.json").path) {
                roots.append(directory)
                break
            }
            directory = directory.deletingLastPathComponent()
        }
        for root in roots {
            for path in ["resources/kit/vendor/pele.global.js", "kit/vendor/pele.global.js"] {
                if let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) { return text }
            }
        }
        return nil
    }()

    func prewarm() {
        queue.async { [self] in
            guard load() != nil else { return }
            // The common diagram types compile their parsers on first use.
            for source in ["graph TD\n  A[Start] --> B[Ready]", "sequenceDiagram\n  A->>B: hello"] {
                _ = draw(source: source, width: 320, theme: [:])
            }
        }
    }

    func render(source: String, width: CGFloat, theme: [String: String]) -> NoteDiagram.Outcome {
        queue.sync { draw(source: source, width: width, theme: theme) }
    }

    private func load() -> JSContext? {
        if !loaded {
            loaded = true
            if let script = Self.script, let context = JSContext() {
                context.evaluateScript(script)
                if context.exception == nil { self.context = context }
            }
        }
        return context
    }

    /// On `queue`: Pele draws the source, its variables become `theme`'s colors, and the SVG is
    /// decoded at the size the note lays out.
    private func draw(source: String, width: CGFloat, theme: [String: String]) -> NoteDiagram.Outcome {
        guard let context = load(), let pele = context.objectForKeyedSubscript("pele"), !pele.isUndefined,
              let render = pele.objectForKeyedSubscript("render"), !render.isUndefined else {
            return .failure("Pele isn't available")
        }
        let options: [String: Any] = [
            "maxWidth": Double(width),
            "fontFamily": Self.fontFamily,
            "fontFamilyMono": Self.monoFontFamily,
            "fontSize": Double(Self.fontSize),
            "responsive": true,
            // Notes are untrusted markdown too: no navigation or network from a diagram.
            "links": false,
            "images": false,
        ]
        context.exception = nil
        let value = render.call(withArguments: [source, options])
        if let exception = context.exception {
            context.exception = nil
            let message = exception.objectForKeyedSubscript("message")?.toString() ?? ""
            return .failure(message.isEmpty ? "Pele couldn't draw this diagram" : message)
        }
        guard let value, value.isObject,
              let svg = value.objectForKeyedSubscript("svg")?.toString(), !svg.isEmpty,
              let drawnWidth = value.objectForKeyedSubscript("width")?.toDouble(), drawnWidth > 0,
              let drawnHeight = value.objectForKeyedSubscript("height")?.toDouble(), drawnHeight > 0 else {
            return .failure("Pele couldn't draw this diagram")
        }
        let themed = NoteDiagram.themed(svg, colors: theme)
        guard let data = themed.data(using: .utf8), let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return .failure("Pele couldn't draw this diagram")
        }
        // The attachment fits the image to the line; keeping its size at or under the note's width
        // makes the measured height match what the note draws.
        let scale = min(1, width / CGFloat(drawnWidth))
        image.size = CGSize(width: (CGFloat(drawnWidth) * scale).rounded(), height: (CGFloat(drawnHeight) * scale).rounded())
        return .image(image)
    }
}
