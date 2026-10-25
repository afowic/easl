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

    nonisolated static let maxFenceBytes = 1024
    nonisolated static let maxNoteFenceBytes = 1536
    nonisolated static let maxNoteFences = 2

    struct Budget {
        private var bytes = 0
        private var fences = 0

        mutating func admit(_ source: String) -> String? {
            guard source.utf8.count <= NoteDiagram.maxFenceBytes else { return "diagram exceeds the native rendering budget" }
            guard fences < NoteDiagram.maxNoteFences,
                  source.utf8.count <= NoteDiagram.maxNoteFenceBytes - bytes else { return "note exceeds the diagram rendering budget" }
            fences += 1
            bytes += source.utf8.count
            return nil
        }
    }

    /// Builds the JSContext and compiles the common parsers off the main thread, so the first
    /// diagram a launch shows doesn't pay for it. Called at app launch.
    public static func prewarm() {
        engine.prewarm()
    }

    /// `source` drawn at most `width` points wide for `appearance`.
    static func image(source: String, width: CGFloat, appearance: NSAppearance) -> Outcome {
        guard source.utf8.count <= maxFenceBytes else { return .failure("diagram exceeds the native rendering budget") }
        let width = width.isNaN ? 1 : min(max(1, width.rounded()), 16_384)
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

    nonisolated static func themed(_ svg: String, colors theme: [String: String]) -> String {
        var variables = theme.reduce(into: [String: String]()) { $0["--pele-" + $1.key] = $1.value }
        for (alias, name, fallback) in [
            ("bg", "bg", "#ffffff"), ("fg", "fg", "#1f1f1f"), ("m", "muted", "#6e6e6e"),
            ("l", "line", "#1f1f1f"), ("s", "surface", "#f3f3f3"), ("a", "surface-alt", "#e6e6e6"),
            ("b", "border", "#8a8a8a"), ("c", "accent", "#5b7bd5"), ("r", "radius", "4px"),
            ("fm", "font-mono", "monospace"),
        ] {
            variables["--_" + alias] = theme[name] ?? fallback
        }
        var output = ""
        output.reserveCapacity(svg.utf8.count)
        let scalars = svg.unicodeScalars
        var index = svg.startIndex
        var inStyle = false
        while index < svg.endIndex {
            let textEnd = svg[index...].firstIndex(of: "<") ?? svg.endIndex
            let text = svg[index..<textEnd]
            if inStyle {
                output.append(contentsOf: css(text, variables: variables))
            } else {
                output.append(contentsOf: text)
            }
            guard textEnd < svg.endIndex else { break }
            var tagEnd = scalars.index(after: textEnd)
            var quote: Unicode.Scalar?
            while tagEnd < svg.endIndex {
                let character = scalars[tagEnd]
                if let active = quote {
                    if character == active { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    tagEnd = scalars.index(after: tagEnd)
                    break
                }
                tagEnd = scalars.index(after: tagEnd)
            }
            let tag = svg[textEnd..<tagEnd]
            output.append(contentsOf: themedTag(tag, variables: variables))
            if tag.hasPrefix("<style>") || tag.hasPrefix("<style ") { inStyle = true }
            if tag.hasPrefix("</style") { inStyle = false }
            index = tagEnd
        }
        return output
    }

    private nonisolated static let styledAttributes: Set<Substring> = [
        "style", "fill", "stroke", "color", "stop-color", "flood-color", "lighting-color", "font-family",
    ]

    private nonisolated static func themedTag(_ tag: Substring, variables: [String: String]) -> String {
        var output = ""
        var copied = tag.startIndex
        var index = tag.startIndex
        while index < tag.endIndex {
            guard tag[index] == "=" else { index = tag.index(after: index); continue }
            var nameEnd = index
            while nameEnd > tag.startIndex, tag[tag.index(before: nameEnd)].isWhitespace { nameEnd = tag.index(before: nameEnd) }
            var nameStart = nameEnd
            while nameStart > tag.startIndex {
                let previous = tag.index(before: nameStart)
                guard tag[previous].isLetter || tag[previous] == "-" else { break }
                nameStart = previous
            }
            index = tag.index(after: index)
            while index < tag.endIndex, tag[index].isWhitespace { index = tag.index(after: index) }
            guard index < tag.endIndex, tag[index] == "\"" || tag[index] == "'" else { continue }
            let quote = tag[index]
            let start = tag.index(after: index)
            index = start
            while index < tag.endIndex, tag[index] != quote { index = tag.index(after: index) }
            guard index < tag.endIndex else { break }
            if styledAttributes.contains(tag[nameStart..<nameEnd]) {
                output.append(contentsOf: tag[copied..<start])
                output.append(contentsOf: css(tag[start..<index], variables: variables))
                copied = index
            }
            index = tag.index(after: index)
        }
        output.append(contentsOf: tag[copied...])
        return output
    }

    private struct CSSVariable {
        var start: Substring.Index
        var name = ""
        var fallback = ""
        var hasFallback = false
        var parentheses = 0
    }

    private nonisolated static func css(_ source: Substring, variables: [String: String]) -> String {
        var output = ""
        output.reserveCapacity(source.utf8.count)
        var frames: [CSSVariable] = []
        var index = source.startIndex
        func append<Characters: Sequence>(_ text: Characters) where Characters.Element == Character {
            if frames.isEmpty {
                output.append(contentsOf: text)
            } else if frames[frames.count - 1].hasFallback {
                frames[frames.count - 1].fallback.append(contentsOf: text)
            } else {
                frames[frames.count - 1].name.append(contentsOf: text)
            }
        }
        while index < source.endIndex {
            if source[index...].hasPrefix("var(") {
                guard frames.count < 32 else { return String(source) }
                frames.append(CSSVariable(start: index))
                index = source.index(index, offsetBy: 4)
                continue
            }
            let character = source[index]
            if character == "(", !frames.isEmpty {
                frames[frames.count - 1].parentheses += 1
                append(CollectionOfOne(character))
            } else if character == ")", !frames.isEmpty, frames[frames.count - 1].parentheses > 0 {
                frames[frames.count - 1].parentheses -= 1
                append(CollectionOfOne(character))
            } else if character == ")", let variable = frames.popLast() {
                let name = variable.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = variables[name] ?? (variable.hasFallback
                    ? variable.fallback.trimmingCharacters(in: .whitespacesAndNewlines)
                    : variables["--pele-fg"] ?? "#1f1f1f")
                append(value)
            } else if character == ",", !frames.isEmpty, !frames[frames.count - 1].hasFallback {
                frames[frames.count - 1].hasFallback = true
            } else {
                append(CollectionOfOne(character))
            }
            index = source.index(after: index)
        }
        if let incomplete = frames.first { output.append(contentsOf: source[incomplete.start...]) }
        return output.replacingOccurrences(of: "height:auto;", with: "")
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
                context.evaluateScript("""
                function easlRenderDiagram(source, options) {
                    if (pele.detectType(source) === "block") {
                        let spaces = 0;
                        for (const match of source.matchAll(/\\bspace\\s*:\\s*(\\d+)/g)) {
                            spaces += Number(match[1]);
                            if (spaces > 64)
                                throw new Error("diagram exceeds the native block parsing budget");
                        }
                    }
                    const model = pele.parse(source, {limit: 1024, maxEdges: 8});
                    if (model.type === "gantt" && (model.excludes?.length || model.includes?.length))
                        throw new Error("diagram exceeds the native calendar rendering budget");
                    if (model.type === "venn") {
                        if (model.subsets.length > 12)
                            throw new Error("diagram exceeds the native Venn rendering budget");
                        const sets = new Set();
                        for (const subset of model.subsets)
                            for (const name of subset.sets) {
                                sets.add(name);
                                if (sets.size > 5)
                                    throw new Error("diagram exceeds the native Venn rendering budget");
                            }
                    }
                    const groups = model.subgraphs?.length || 0;
                    const nodes = model.nodes?.size || model.actors?.size || 0;
                    const edges = model.edges?.length || model.messages?.length || 0;
                    if (groups > 2 || nodes > 12 || (groups + 1) * (nodes + edges) > 24)
                        throw new Error("diagram exceeds the native structural rendering budget");
                    const pending = [model], seen = new Set();
                    let entries = 0, text = 0;
                    while (pending.length) {
                        const item = pending.pop();
                        if (typeof item === "string") {
                            text += item.length;
                        } else if (item && typeof item === "object" && !seen.has(item)) {
                            seen.add(item);
                            const values = item instanceof Map ? [...item.values()] : Object.values(item);
                            entries += values.length;
                            if (entries > 256)
                                throw new Error("diagram exceeds the native rendering budget");
                            pending.push(...values);
                        }
                        if (entries > 256 || text > 4096)
                            throw new Error("diagram exceeds the native rendering budget");
                    }
                    return pele.render(model, options);
                }
                """)
                if context.exception == nil { self.context = context }
            }
        }
        return context
    }

    /// On `queue`: Pele draws the source, its variables become `theme`'s colors, and the SVG is
    /// decoded at the size the note lays out.
    private func draw(source: String, width: CGFloat, theme: [String: String]) -> NoteDiagram.Outcome {
        guard let context = load(),
              let render = context.objectForKeyedSubscript("easlRenderDiagram"), !render.isUndefined else {
            return .failure("Pele isn't available")
        }
        let options: [String: Any] = [
            "maxWidth": Double(width),
            "fontFamily": Self.fontFamily,
            "fontFamilyMono": Self.monoFontFamily,
            "fontSize": Double(Self.fontSize),
            "responsive": true,
            "autoDirection": false,
            "outputLimit": 100_000,
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
