import AppKit
import Foundation
import Markdown
import Testing
@testable import CanvasCore

/// A note's ```mermaid fence rendered natively by the vendored Pele build: the diagram itself in
/// the note's text, at the note's width, and the source with Pele's explanation when it can't be
/// drawn.
@MainActor
struct NoteDiagramTests {
    /// The note's rendered text and the first attachment in it, if any.
    func render(_ markdown: String, noteWidth: CGFloat = 400) async -> (text: NSAttributedString, attachment: NSTextAttachment?) {
        let renderer = NoteRenderer(excerpts: [:], width: noteWidth - 2 * ObjectMeasure.noteInset.width)
        let text = await renderer.renderPrepared(NoteMarkdown.parse(markdown), placeholder: "")
        var attachment: NSTextAttachment?
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let value = value as? NSTextAttachment { attachment = value }
        }
        return (text, attachment)
    }

    @Test func pendingDiagramsAreWidthDependentAndBecomePreparedBitmaps() async throws {
        let source = "graph TD\nA[Pending \(UUID().uuidString)]-->B[Ready]"
        let document = NoteMarkdown.parse("```mermaid\n" + source + "\n```")
        let renderer = NoteRenderer(excerpts: [:], width: 384)
        let pending = renderer.render(document, placeholder: "")
        #expect(renderer.hasPendingDiagrams)
        #expect(renderer.fitsWidth)
        #expect(pending.string.contains("Pending"))
        #expect(!pending.string.contains("Pele:"))
        let ready = await renderer.renderPrepared(document, placeholder: "")
        #expect(!renderer.hasPendingDiagrams)
        #expect(!ready.string.contains("Pending"))
        let attachment = try #require(ready.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let image = try #require(attachment.image)
        #expect(image.representations.allSatisfy { $0.pixelsWide == Int(ceil(image.size.width * 2)) })
        let measured = await ObjectMeasure.note(document, markdown: "", width: 400, excerpts: [:], images: [:])
        let expected = CodeMetrics.titleHeight + 2 * ObjectMeasure.noteInset.height
            + ObjectMeasure.noteTextHeight(ready, width: 384)
        #expect(measured.size.height == expected.rounded(.up))
    }

    @Test func cancelledRequestsDoNotPublishCompletedResults() async {
        let source = "graph LR\nA[Cancelled \(UUID().uuidString)]-->B"
        let appearance = NSAppearance(named: .aqua)!
        let task = Task { await NoteDiagram.image(source: source, width: 371, appearance: appearance) }
        task.cancel()
        let outcome = await task.value
        #expect(outcome == nil)
        #expect(NoteDiagram.completed(source: source, width: 371, appearance: appearance) == nil)
    }

    @Test func teachingSizedDiagramsRenderNatively() async {
        for (nodes, groups) in [(30, 3), (120, 6)] {
            var lines = ["graph TD"]
            for group in 0..<groups {
                lines.append("subgraph s\(group)")
                for node in (group * nodes / groups)..<((group + 1) * nodes / groups) {
                    lines.append("x\(node)[Node \(node)]")
                }
                lines.append("end")
            }
            for node in 1..<nodes { lines.append("x\(node - 1)-->x\(node)") }
            #expect(await render("```mermaid\n" + lines.joined(separator: "\n") + "\n```").attachment?.image != nil)
        }
        let gantt = "gantt\ndateFormat YYYY-MM-DD\nsection Study\nT0 :t0, 2024-01-01, 1d\n"
            + (1..<40).map { "T\($0) :t\($0), after t\($0 - 1), 1d" }.joined(separator: "\n")
        let concept = "graph LR\nRoot[Concept]\n"
            + (1..<50).map { "Root-->x\($0)[Idea \($0)]" }.joined(separator: "\n")
        let sequence = "sequenceDiagram\n"
            + (0..<20).map { "A->>B: Message \($0)" }.joined(separator: "\n")
        for source in [gantt, concept, sequence] {
            #expect(await render("```mermaid\n" + source + "\n```").attachment?.image != nil)
        }
        let fences = (0..<10).map { "```mermaid\ngraph LR\nA[Start \($0)]-->B[Done]\n```" }
        let (text, _) = await render(fences.joined(separator: "\n\n"))
        var attachments = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        #expect(attachments == 10)
    }

    @Test func aMermaidFenceRendersADiagramAtTheNoteWidth() async throws {
        let markdown = "Before\n\n```mermaid\ngraph TD\n  A[Start] --> B[Done]\n```\n\nAfter"
        let (text, attachment) = await render(markdown)
        let diagram = try #require(attachment?.image)
        // The fence's source is the diagram, not rows of text.
        #expect(!text.string.contains("A[Start]"))
        #expect(text.string.contains("Before") && text.string.contains("After"))
        #expect(diagram.size.width > 0 && diagram.size.height > 0)
        #expect(diagram.size.width <= 400 - 2 * ObjectMeasure.noteInset.width)
        // The diagram ends its paragraph, so the prose after the fence starts below it, not beside it.
        let attachmentRange = (text.string as NSString).range(of: "\u{FFFC}")
        #expect((text.string as NSString).substring(with: NSRange(location: NSMaxRange(attachmentRange), length: 1)) == "\n")
    }

    @Test func theDiagramHeightCountsTowardsTheNotesMeasuredHeight() async {
        let diagram = "```mermaid\ngraph TD\n  A[Start] --> B[Done]\n```"
        let invalidSource = "```mermaid\nA[Start] --> B[Done]\n```"
        let prose = "A line"
        let withDiagram = await ObjectMeasure.note(NoteMarkdown.parse(diagram), markdown: diagram, width: 400, excerpts: [:], images: [:])
        let sourceOnly = await ObjectMeasure.note(NoteMarkdown.parse(invalidSource), markdown: invalidSource, width: 400, excerpts: [:], images: [:])
        let plain = await ObjectMeasure.note(NoteMarkdown.parse(prose), markdown: prose, width: 400, excerpts: [:], images: [:])
        #expect(withDiagram.size.height > plain.size.height + 40)
        // An invalid diagram keeps its source rows and Pele's message, so it is still taller than prose.
        #expect(sourceOnly.size.height > plain.size.height)
    }

    @Test func invalidMermaidShowsTheSourceAndPelesExplanation() async {
        let markdown = "```mermaid\nflowchart LR\n  A[\n```"
        let (text, attachment) = await render(markdown)
        #expect(attachment == nil)
        #expect(text.string.contains("flowchart LR"))
        #expect(text.string.contains("A["))
        #expect(text.string.contains("Pele"))
        #expect(text.string.contains("Parse error"))
    }

    @Test func rejectedDiagramSourceHasABoundedPreviewAndItsExplanation() async {
        let source = "graph TD\nA[\"HEAD " + String(repeating: "x", count: 20_000) + " TAIL\"]-->B"
        let (text, attachment) = await render("```mermaid\n" + source + "\n```")
        #expect(attachment == nil)
        #expect(text.string.contains("HEAD"))
        #expect(!text.string.contains("TAIL"))
        #expect(text.string.contains("…"))
        #expect(text.string.contains("Pele:"))
        #expect(text.string.contains("budget"))
        #expect(text.length < 2200)
    }

    @Test func svgThemingPreservesLiteralLabelsAndMetadata() {
        let label = "var(--untrusted, " + String(repeating: "\u{00a0}", count: 40_000) + ")"
        let svg = "<svg aria-label=\"var(--pele-fg,keep)\"><style>.node{fill:var(--pele-fg,#123456)}</style><text>" + label + "</text><path fill=\"var(--_fg)\" style=\"height:auto;stroke:var(--unknown, #654321)\"/></svg>"
        let result = NoteDiagram.themed(svg, colors: ["fg": "#abcdef"])
        #expect(result.contains("<text>" + label + "</text>"))
        #expect(result.contains("aria-label=\"var(--pele-fg,keep)\""))
        #expect(result.contains(".node{fill:#abcdef}"))
        #expect(result.contains("fill=\"#abcdef\""))
        #expect(result.contains("style=\"stroke:#654321\""))
    }

    @Test func svgThemingResolvesNestedFallbacksAndPreservesMalformedCSS() {
        let svg = "<svg><path fill=\"var(--missing,var(--pele-fg,#123456))\" stroke=\"var(--unfinished\"/></svg>"
        let result = NoteDiagram.themed(svg, colors: ["fg": "#abcdef"])
        #expect(result.contains("fill=\"#abcdef\""))
        #expect(result.contains("stroke=\"var(--unfinished\""))
    }

    @Test func svgThemingPreservesCombiningLabelsAndResolvesFontFamilies() {
        for scalar in ["\u{301}", "\u{200d}", "\u{fe0f}"] {
            let label = scalar + "fill='var(--pele-fg)'"
            let svg = "<svg><text>" + label + "</text><path fill='var(--pele-fg)'/><text font-family='var(--_fm)'>Rail</text></svg>"
            let result = NoteDiagram.themed(svg, colors: ["fg": "#123456", "font-mono": "Menlo"])
            #expect(result.contains("<text>" + label + "</text>"))
            #expect(result.contains("<path fill='#123456'/>"))
            #expect(result.contains("font-family='Menlo'"))
        }
    }

    @Test func extremeDiagramWidthsNeverTrapInMeasurement() async throws {
        if try runIsolatedTestIfParallelNow("NoteDiagramTests/extremeDiagramWidthsNeverTrapInMeasurement") { return }
        let markdown = "```mermaid\ngraph LR\nA-->B\n```"
        for width in [CGFloat(1e300), .infinity, -.infinity, .nan] {
            let (_, attachment) = await render(markdown, noteWidth: width)
            let image = try #require(attachment?.image)
            #expect(image.size.width.isFinite && image.size.width > 0)
            #expect(image.size.height.isFinite && image.size.height > 0)
        }
        let measured = try await ObjectMeasure.size(type: .note, props: .object(["markdown": .string(markdown)]),
                                                   width: 1e300, root: URL(fileURLWithPath: "/tmp"))
        #expect(measured.height.isFinite && measured.height > 0)
    }

    @Test func nestedCrossEdgeFencesFallBackBeforeExpensiveLayout() async {
        var source = "graph TD\n"
        for i in 0..<50 { source += "subgraph s\(i)\nx\(i)-->x\(i + 1)\n" }
        source += String(repeating: "end\n", count: 50)
        for i in 0..<250 { source += "x\((i * 13) % 50)-->x\((i * 29) % 50)\n" }
        #expect(source.utf8.count < NoteDiagram.maxFenceBytes)
        let (text, attachment) = await render("```mermaid\n" + source + "```")
        #expect(attachment == nil)
        #expect(text.string.contains("subgraph s0"))
        #expect(text.string.contains("structural rendering budget"))
    }

    @Test func expensiveCalendarAndBlockFencesKeepTheirSource() async {
        var gantt = "gantt\ndateFormat DD.MM.YYYY HH:mm:ss.SSS\nexcludes weekends, 02.01.2024 00:00:00.000\nsection S\nT0 :t0, 01.01.2024 00:00:00.000, 20000d\n"
        for i in 1...7 { gantt += "T\(i) :t\(i), after t\(i - 1), 20000d\n" }
        for (source, marker) in [
            (gantt, "T7 :t7, after t6, 20000d"),
            ("gantt\ndateFormat YYYY-MM-DD\nincludes 2024-01-01\nsection S\nTask :a, 2024-01-01, 20000d", "includes 2024-01-01"),
            ("gantt\ndateFormat YYYY-MM-DD\nexcludes weekends\nsection S\nFar :far, 2099-01-01, 1d\nSpan :span, 2024-01-01, until far", "until far"),
            ("block-beta\nspace:99999", "space:99999"),
        ] {
            let (text, attachment) = await render("```mermaid\n" + source + "\n```")
            #expect(attachment == nil)
            #expect(text.string.contains(marker))
            #expect(text.string.contains("budget"))
        }
    }

    @Test func rejectedBlockSourcesCannotAmplifyParsingWork() async {
        let sources = [
            "block-beta\nspace:1space:99999",
            "block-beta\ncolumns 1space:99999",
            "block-beta\nA:1space:99999",
            "block-beta\nspace%%{wrap}%%:99999",
            "block-beta\nspace:%%{wrap}%%99999",
            "block-beta\nspace:9%%{wrap}%%9999",
            "block-beta\nX[\"style:#\"]space;:99999",
            "block-beta\nX[\"style:#\"]space:9;9999",
            "---\ntitle: Blocks\n---\nblock-beta\ncolumns 1space:99999",
        ]
        for source in sources {
            #expect(source.utf8.count < NoteDiagram.maxFenceBytes)
            let (text, attachment) = await render("```mermaid\n" + source + "\n```")
            #expect(attachment == nil)
            #expect(text.string.contains("block parsing budget"))
        }
    }

    @Test func boundedCalendarAndBlockDiagramsStillRender() async {
        for source in [
            "gantt\ndateFormat YYYY-MM-DD\nsection S\nTask :a, 2024-01-01, 2d",
            "gantt\ndateFormat YYYY-MM-DD\nexcludes weekends\nsection S\nTask :a, 2024-01-01, 2d",
            "gantt\ndateFormat YYYY-MM-DD\nincludes 2024-01-01\nsection S\nTask :a, 2024-01-01, 2d",
            "block-beta\ncolumns 3\nA space:1 B",
            "block-beta\ncolumns 10\nA space:80 B",
            "gantt\ndateFormat YYYY-MM-DD\nexcludes weekends\nsection S\nTask :a, 2024-01-01, 4000d",
            "graph LR\nA[\"space:99999\"]-->B",
        ] {
            let (_, attachment) = await render("```mermaid\n" + source + "\n```")
            #expect(attachment?.image != nil)
        }
    }

    @Test func ordinaryPieAndVennChartsDoNotHavePerTypeMicroBudgets() async {
        let pie = "pie showData\n" + (0..<32).map { "\"label\($0)\":\($0 == 31 ? 69 : 1)" }.joined(separator: "\n")
        let venn = "venn-beta\n" + (0..<6).map { "set S\($0): \(10 + $0 * 13)" }.joined(separator: "\n")
        for source in [pie, venn] {
            #expect(await render("```mermaid\n" + source + "\n```").attachment?.image != nil)
        }
    }

    @Test func noteDiagramBudgetAppliesEvenWhenImagesAreCached() async {
        let fence = "```mermaid\ngraph LR\nA-->B\n```"
        _ = await render(fence)
        let (text, _) = await render(Array(repeating: fence, count: NoteDiagram.maxNoteFences + 1).joined(separator: "\n\n"))
        var attachments = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        #expect(attachments == NoteDiagram.maxNoteFences)
        #expect(text.string.contains("note exceeds the diagram rendering budget"))
        #expect(text.string.contains("A-->B"))
    }

    @Test func noteDiagramBytesAreBoundedAcrossOtherwiseValidFences() async {
        let source = "graph LR\nA-->B\n%%" + String(repeating: "p", count: NoteDiagram.maxFenceBytes - 100)
        let fence = "```mermaid\n" + source + "\n```"
        let (text, _) = await render(Array(repeating: fence, count: 10).joined(separator: "\n\n"))
        var attachments = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        #expect(attachments == NoteDiagram.maxNoteFenceBytes / source.utf8.count)
        #expect(text.string.contains("note exceeds the diagram rendering budget"))
    }

    @Test func nativeFlowchartKeepsDeclaredHorizontalDirection() async throws {
        let (_, attachment) = await render("```mermaid\ngraph LR\nA[Start]-->B[Middle]-->C[Finish]\n```", noteWidth: 100)
        let image = try #require(attachment?.image)
        #expect(image.size.width > image.size.height)
        #expect(image.size.width <= 100)
    }

    @Test func otherFencesStayCodeRows() async {
        let (text, attachment) = await render("```swift\nlet x = 1\n```")
        #expect(attachment == nil)
        #expect(text.string.contains("let x = 1"))
    }

    @Test func anAnchoredMermaidFenceIsAnExcerptNotADiagram() async {
        let (text, attachment) = await render("```mermaid file=flow.mmd\nnot diagram source\n```")
        #expect(attachment == nil)
        #expect(text.string.contains("flow.mmd"))
    }
}
