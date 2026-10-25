import AppKit
import Darwin
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
    func render(_ markdown: String, noteWidth: CGFloat = 400) -> (text: NSAttributedString, attachment: NSTextAttachment?) {
        let renderer = NoteRenderer(excerpts: [:], width: noteWidth - 2 * ObjectMeasure.noteInset.width)
        let text = renderer.render(NoteMarkdown.parse(markdown), placeholder: "")
        var attachment: NSTextAttachment?
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let value = value as? NSTextAttachment { attachment = value }
        }
        return (text, attachment)
    }

    @Test func aMermaidFenceRendersADiagramAtTheNoteWidth() throws {
        let markdown = "Before\n\n```mermaid\ngraph TD\n  A[Start] --> B[Done]\n```\n\nAfter"
        let (text, attachment) = render(markdown)
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

    @Test func theDiagramHeightCountsTowardsTheNotesMeasuredHeight() {
        let diagram = "```mermaid\ngraph TD\n  A[Start] --> B[Done]\n```"
        let invalidSource = "```mermaid\nA[Start] --> B[Done]\n```"
        let prose = "A line"
        let withDiagram = ObjectMeasure.note(NoteMarkdown.parse(diagram), markdown: diagram, width: 400, excerpts: [:], images: [:])
        let sourceOnly = ObjectMeasure.note(NoteMarkdown.parse(invalidSource), markdown: invalidSource, width: 400, excerpts: [:], images: [:])
        let plain = ObjectMeasure.note(NoteMarkdown.parse(prose), markdown: prose, width: 400, excerpts: [:], images: [:])
        #expect(withDiagram.size.height > plain.size.height + 40)
        // An invalid diagram keeps its source rows and Pele's message, so it is still taller than prose.
        #expect(sourceOnly.size.height > plain.size.height)
    }

    @Test func invalidMermaidShowsTheSourceAndPelesExplanation() {
        let markdown = "```mermaid\nflowchart LR\n  A[\n```"
        let (text, attachment) = render(markdown)
        #expect(attachment == nil)
        #expect(text.string.contains("flowchart LR"))
        #expect(text.string.contains("A["))
        #expect(text.string.contains("Pele"))
        #expect(text.string.contains("Parse error"))
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
            let (_, attachment) = render(markdown, noteWidth: width)
            let image = try #require(attachment?.image)
            #expect(image.size.width.isFinite && image.size.width > 0)
            #expect(image.size.height.isFinite && image.size.height > 0)
        }
        let measured = try await ObjectMeasure.size(type: .note, props: .object(["markdown": .string(markdown)]),
                                                   width: 1e300, root: URL(fileURLWithPath: "/tmp"))
        #expect(measured.height.isFinite && measured.height > 0)
    }

    @Test func nestedCrossEdgeFencesFallBackBeforeExpensiveLayout() {
        var source = "graph TD\n"
        for i in 0..<50 { source += "subgraph s\(i)\nx\(i)-->x\(i + 1)\n" }
        source += String(repeating: "end\n", count: 50)
        for i in 0..<250 { source += "x\((i * 13) % 50)-->x\((i * 29) % 50)\n" }
        let (text, attachment) = render("```mermaid\n" + source + "```")
        #expect(attachment == nil)
        #expect(text.string.contains("subgraph s0"))
        #expect(text.string.contains("rendering budget"))
        let compact = "graph TD\nsubgraph a\nsubgraph b\nsubgraph c\nA-->B\nend\nend\nend"
        let refused = render("```mermaid\n" + compact + "\n```")
        #expect(refused.attachment == nil)
        #expect(refused.text.string.contains("structural rendering budget"))
    }

    @Test func expensiveCalendarAndBlockFencesKeepTheirSource() {
        var gantt = "gantt\ndateFormat DD.MM.YYYY HH:mm:ss.SSS\nexcludes weekends, 02.01.2024 00:00:00.000\nsection S\nT0 :t0, 01.01.2024 00:00:00.000, 20000d\n"
        for i in 1...7 { gantt += "T\(i) :t\(i), after t\(i - 1), 20000d\n" }
        for (source, marker) in [
            (gantt, "T7 :t7, after t6, 20000d"),
            ("gantt\ndateFormat YYYY-MM-DD\nincludes 2024-01-01\nsection S\nTask :a, 2024-01-01, 20000d", "includes 2024-01-01"),
            ("block-beta\nspace:99999", "space:99999"),
            ("block-beta\nspace:40\nspace:40", "space:40"),
        ] {
            let (text, attachment) = render("```mermaid\n" + source + "\n```")
            #expect(attachment == nil)
            #expect(text.string.contains(marker))
            #expect(text.string.contains("budget"))
        }
    }

    @Test func rejectedBlockSourcesCannotAmplifyParsingWork() throws {
        if try runIsolatedTestIfParallelNow("NoteDiagramTests/rejectedBlockSourcesCannotAmplifyParsingWork") { return }
        let appearance = NSAppearance(named: .aqua)!
        let reference = "block-beta\n" + String(repeating: "space:2\n", count: 33)
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
        func cpu() -> Double {
            var usage = rusage()
            precondition(getrusage(RUSAGE_SELF, &usage) == 0)
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        func work(_ inputs: [String], width: Int) -> (cpu: Double, refusals: Int) {
            var refusals = 0
            let start = cpu()
            for index in 0..<32 {
                if case .failure = NoteDiagram.image(source: inputs[index % inputs.count],
                                                     width: CGFloat(width + index), appearance: appearance) {
                    refusals += 1
                }
            }
            return (cpu() - start, refusals)
        }
        _ = work([reference], width: 800)
        // Distinct widths bypass cached failures; isolated process CPU excludes CI scheduling delays.
        let bounded = work([reference], width: 900)
        let hostile = work(sources, width: 1000)
        #expect(bounded.refusals == 32)
        #expect(hostile.refusals == 32)
        #expect(hostile.cpu <= bounded.cpu * 4)
    }

    @Test func boundedCalendarAndBlockDiagramsStillRender() {
        for source in [
            "gantt\ndateFormat YYYY-MM-DD\nsection S\nTask :a, 2024-01-01, 2d",
            "block-beta\ncolumns 3\nA space:1 B",
            "graph LR\nA[\"space:99999\"]-->B",
        ] {
            let (_, attachment) = render("```mermaid\n" + source + "\n```")
            #expect(attachment?.image != nil)
        }
    }

    @Test func vennDiagramsBoundSetsAndSubsets() {
        let five = "venn-beta\n" + (0..<5).map { "set S\($0): \(10 + $0 * 13)" }.joined(separator: "\n")
        let unions = ["S0,S1", "S0,S2", "S0,S3", "S0,S4", "S1,S2", "S1,S3", "S1,S4", "S2,S3"]
        let bounded = five + "\n" + unions.prefix(7).map { "union \($0): 1" }.joined(separator: "\n")
        #expect(render("```mermaid\n" + bounded + "\n```").attachment?.image != nil)
        for source in [five + "\nset S5", five + "\n" + unions.map { "union \($0): 1" }.joined(separator: "\n")] {
            let (text, attachment) = render("```mermaid\n" + source + "\n```")
            #expect(attachment == nil)
            #expect(text.string.contains("venn-beta"))
            #expect(text.string.contains("budget"))
        }
    }

    @Test func pieDiagramsBoundSlicesBeforeResponsiveLayout() {
        let marker = String(repeating: "X", count: 80)
        func source(_ count: Int, wideLabels: Bool = true) -> String {
            "pie\n" + (0..<count).map { index in
                let label = index == 0 ? marker
                    : wideLabels ? String(format: "label%03d", index) : String(index, radix: 36)
                return "\"\(label)\":1"
            }.joined(separator: "\n")
        }
        #expect(render("```mermaid\n" + source(32) + "\n```").attachment?.image != nil)
        for source in [source(33), source(100, wideLabels: false)] {
            let (text, attachment) = render("```mermaid\n" + source + "\n```")
            #expect(attachment == nil)
            #expect(text.string.contains("pie"))
            #expect(text.string.contains(marker))
        }
    }

    @Test func noteDiagramBudgetAppliesEvenWhenImagesAreCached() {
        let fence = "```mermaid\ngraph LR\nA-->B\n```"
        _ = render(fence)
        let (text, _) = render(Array(repeating: fence, count: NoteDiagram.maxNoteFences + 1).joined(separator: "\n\n"))
        var attachments = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        #expect(attachments == NoteDiagram.maxNoteFences)
        #expect(text.string.contains("note exceeds the diagram rendering budget"))
        #expect(text.string.contains("A-->B"))
    }

    @Test func noteDiagramBytesAreBoundedAcrossOtherwiseValidFences() {
        let source = "graph LR\nA-->B\n%%" + String(repeating: "p", count: 880)
        let fence = "```mermaid\n" + source + "\n```"
        let (text, _) = render(fence + "\n\n" + fence)
        var attachments = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        #expect(attachments == 1)
        #expect(text.string.contains("note exceeds the diagram rendering budget"))
    }

    @Test func nativeFlowchartKeepsDeclaredHorizontalDirection() throws {
        let (_, attachment) = render("```mermaid\ngraph LR\nA[Start]-->B[Middle]-->C[Finish]\n```", noteWidth: 100)
        let image = try #require(attachment?.image)
        #expect(image.size.width > image.size.height)
        #expect(image.size.width <= 100)
    }

    @Test func otherFencesStayCodeRows() {
        let (text, attachment) = render("```swift\nlet x = 1\n```")
        #expect(attachment == nil)
        #expect(text.string.contains("let x = 1"))
    }

    @Test func anAnchoredMermaidFenceIsAnExcerptNotADiagram() {
        let (text, attachment) = render("```mermaid file=flow.mmd\nnot diagram source\n```")
        #expect(attachment == nil)
        #expect(text.string.contains("flow.mmd"))
    }
}
