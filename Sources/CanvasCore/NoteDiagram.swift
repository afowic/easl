import AppKit
import JavaScriptCore

/// Native note diagrams rendered and rasterized on one serial JavaScriptCore worker.
/// The main actor owns only completed bitmap results; it never waits synchronously for the worker.
@MainActor
public enum NoteDiagram {
    /// A worker hands off an immutable bitmap and never touches it again.
    enum Outcome: @unchecked Sendable {
        case image(NSImage)
        /// Why Pele couldn't draw the source, shown under the fence's source rows.
        case failure(String)
    }

    private struct Key: Hashable {
        var source: String
        var width: Int
        var colors: [String]
    }

    private static let engine = PeleEngine()
    private static var cache: [Key: Outcome] = [:]
    private static var order: [Key] = []
    private static var cacheBytes = 0
    static let cacheLimit = 64
    private static let maxCacheBytes = 128 * 1024 * 1024

    nonisolated static let maxFenceBytes = 16 * 1024
    nonisolated static let maxNoteFenceBytes = 128 * 1024
    nonisolated static let maxNoteFences = 32
    nonisolated static let maxNoteRasterBytes = 128 * 1024 * 1024

    struct Budget {
        private var bytes = 0
        private var fences = 0
        private var rasterBytes = 0

        mutating func admit(_ source: String) -> String? {
            guard source.utf8.count <= NoteDiagram.maxFenceBytes else { return "diagram exceeds the native rendering budget" }
            guard fences < NoteDiagram.maxNoteFences,
                  source.utf8.count <= NoteDiagram.maxNoteFenceBytes - bytes else { return "note exceeds the diagram rendering budget" }
            fences += 1
            bytes += source.utf8.count
            return nil
        }

        @MainActor
        mutating func admit(_ outcome: Outcome) -> Outcome {
            let cost = NoteDiagram.cost(outcome)
            guard cost <= NoteDiagram.maxNoteRasterBytes - rasterBytes else {
                return .failure("note exceeds the diagram rendering budget")
            }
            rasterBytes += cost
            return outcome
        }
    }

    /// Builds the JSContext and compiles the common parsers off the main thread, so the first
    /// diagram a launch shows doesn't pay for it. Called at app launch.
    public static func prewarm() {
        engine.prewarm()
    }

    private static func key(source: String, width: CGFloat, colors: [String: String]) -> Key {
        Key(source: source, width: Int(normalizedWidth(width)),
            colors: colors.map { "\($0.key)=\($0.value)" }.sorted())
    }

    nonisolated static func normalizedWidth(_ width: CGFloat) -> CGFloat {
        width.isNaN ? 1 : min(max(1, width.rounded()), 16_384)
    }

    /// A completed result only. A miss must stay source/placeholder until `image` finishes.
    static func completed(source: String, width: CGFloat, appearance: NSAppearance) -> Outcome? {
        cache[key(source: source, width: width, colors: theme(appearance))]
    }

    static func image(source: String, width: CGFloat, appearance: NSAppearance) async -> Outcome? {
        guard !Task.isCancelled else { return nil }
        guard source.utf8.count <= maxFenceBytes else { return .failure("diagram exceeds the native rendering budget") }
        let colors = theme(appearance)
        let key = key(source: source, width: width, colors: colors)
        if let cached = cache[key] { return cached }
        guard let outcome = await engine.render(source: source, width: CGFloat(key.width), theme: colors),
              !Task.isCancelled else { return nil }
        if let cached = cache[key] { return cached }
        cache[key] = outcome
        cacheBytes += cost(outcome)
        order.append(key)
        while order.count > cacheLimit || cacheBytes > maxCacheBytes {
            if let removed = cache.removeValue(forKey: order.removeFirst()) { cacheBytes -= cost(removed) }
        }
        return outcome
    }

    private static func cost(_ outcome: Outcome) -> Int {
        if case .image(let image) = outcome {
            return Int(ceil(image.size.width * 2)) * Int(ceil(image.size.height * 2)) * 4
        }
        return 0
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

/// Context creation, parsing, SVG decoding and first painting are confined to `queue`.
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

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    func render(source: String, width: CGFloat, theme: [String: String]) async -> NoteDiagram.Outcome? {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !cancellation.isCancelled else { continuation.resume(returning: nil); return }
                    let outcome = autoreleasepool { draw(source: source, width: width, theme: theme) }
                    continuation.resume(returning: cancellation.isCancelled ? nil : outcome)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func load() -> JSContext? {
        if !loaded {
            loaded = true
            if let script = Self.script, let context = JSContext() {
                context.evaluateScript(script)
                context.evaluateScript("""
                function easlRenderDiagram(source, options) {
                    const workLimit = 8192;
                    if (pele.detectType(source) === "block") {
                        if (source.includes("%%{"))
                            throw new Error("diagram exceeds the native block parsing budget");
                        let spaces = 0;
                        for (const match of source.replaceAll(";", "").matchAll(/space\\s*:\\s*(\\d+)/g)) {
                            spaces += Number(match[1]);
                            if (spaces > workLimit)
                                throw new Error("diagram exceeds the native block parsing budget");
                        }
                    }
                    const model = pele.parse(source);
                    if (model.type === "gantt" && (model.excludes?.length || model.includes?.length)) {
                        // Calendar exclusions iterate dates; cap the span before Pele schedules them.
                        let days = 0, earliest = Infinity, latest = -Infinity;
                        for (const task of model.tasks || []) {
                            const duration = task.raw?.end || "";
                            const match = String(duration).trim().match(/^(\\d+(?:\\.\\d+)?)(ms|s|m|h|d|w|M|y)$/);
                            if (match) {
                                const units = {ms: 1/86400000, s: 1/86400, m: 1/1440, h: 1/24, d: 1, w: 7, M: 31, y: 366};
                                days += Number(match[1]) * units[match[2]];
                            }
                            for (const raw of [task.raw?.start, task.raw?.end]) {
                                const token = String(raw || "").trim();
                                if (!token || /^(after|until)\\b/.test(token) ||
                                    /^(\\d+(?:\\.\\d+)?)(ms|s|m|h|d|w|M|y)$/.test(token)) continue;
                                try {
                                    const date = +model.getStartDate(token);
                                    if (Number.isFinite(date)) {
                                        earliest = Math.min(earliest, date);
                                        latest = Math.max(latest, date);
                                    }
                                } catch (_) {
                                    // Pele reports invalid dates when rendering the model.
                                }
                            }
                        }
                        const span = Number.isFinite(earliest) ? (latest - earliest) / 86400000 : 0;
                        const calendarWork = (days + span) * Math.max(1, model.dateFormat.length / 10) *
                            Math.max(1, model.excludes.length + model.includes.length);
                        if (calendarWork > workLimit)
                            throw new Error("diagram exceeds the native calendar rendering budget");
                    }
                    const groups = (model.subgraphs?.length || 0) + (model.boundaries?.length || 0);
                    const nodes = model.nodes?.size || model.actors?.size || model.shapes?.length || 0;
                    const edges = model.edges?.length || model.messages?.length || model.rels?.length || 0;
                    const subsets = model.subsets || [];
                    const sets = new Set(subsets.flatMap(subset => subset.sets));
                    const slices = model.sections instanceof Map ? model.sections.size : 0;
                    const work = Math.max((groups + 1) * (nodes + edges), groups * groups,
                                          2 * (model.shapes?.length || 0) * (model.rels?.length || 0),
                                          subsets.length * sets.size * sets.size, slices * slices);
                    if (work > workLimit)
                        throw new Error("diagram exceeds the native structural rendering budget");
                    const pending = [model], seen = new Set();
                    let entries = 0, text = 0;
                    while (pending.length) {
                        const item = pending.pop();
                        if (typeof item === "string") {
                            text += item.length;
                        } else if (item && typeof item === "object" && !seen.has(item)) {
                            seen.add(item);
                            const map = item instanceof Map;
                            const values = map ? item.values() : Object.values(item);
                            entries += map ? item.size : values.length;
                            if (entries > 16384)
                                throw new Error("diagram exceeds the native rendering budget");
                            if (map)
                                for (const key of item.keys()) pending.push(key);
                            for (const value of values) pending.push(value);
                        }
                        if (entries > 16384 || text > 65536)
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
            "outputLimit": 1_000_000,
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
              let drawnWidth = value.objectForKeyedSubscript("width")?.toDouble(), drawnWidth.isFinite, drawnWidth > 0,
              let drawnHeight = value.objectForKeyedSubscript("height")?.toDouble(), drawnHeight.isFinite, drawnHeight > 0 else {
            return .failure("Pele couldn't draw this diagram")
        }
        let themed = NoteDiagram.themed(svg, colors: theme)
        guard let data = themed.data(using: .utf8), let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return .failure("Pele couldn't draw this diagram")
        }
        let scale = min(1, width / CGFloat(drawnWidth))
        let size = CGSize(width: max(1, (CGFloat(drawnWidth) * scale).rounded()),
                          height: max(1, (CGFloat(drawnHeight) * scale).rounded()))
        let pixelsWide = ceil(size.width * 2), pixelsHigh = ceil(size.height * 2)
        guard pixelsWide <= 32_768, pixelsHigh <= 32_768, pixelsWide * pixelsHigh <= 16_777_216,
              let bitmap = CGContext(data: nil, width: Int(pixelsWide), height: Int(pixelsHigh),
                                     bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return .failure("diagram exceeds the native bitmap rendering budget")
        }
        bitmap.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let raster = bitmap.makeImage() else { return .failure("Pele couldn't draw this diagram") }
        return .image(NSImage(cgImage: raster, size: size))
    }
}
