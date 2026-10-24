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
