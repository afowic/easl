import AppKit
import Testing
@testable import CanvasCore

/// Math in note tiles: `$…$` and `$$…$$` typeset with SwiftMath, and what stays literal.
@MainActor
struct NoteMathTests {
    func render(_ markdown: String, width: CGFloat = 400) -> NSAttributedString {
        NoteRenderer(excerpts: [:], source: markdown, width: width).render(NoteMarkdown.parse(markdown), placeholder: "")
    }

    /// The rendered math pictures in `text`, in order.
    func math(_ text: NSAttributedString) -> [NSTextAttachment] {
        var found: [NSTextAttachment] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { found.append(attachment) }
        }
        return found
    }

    @Test func inlineMathTypesetsAsMath() {
        let text = render(#"The identity $e^{i\pi} + 1 = 0$ holds."#)
        let pictures = math(text)
        #expect(pictures.count == 1)
        #expect(!text.string.contains("e^{i"))
        #expect(text.string.contains("The identity "))
        #expect(text.string.contains(" holds."))
        #expect((pictures.first?.image?.size.height ?? 0) > 0)
    }

    @Test func currencyAndEscapedDollarsStayProse() {
        let text = render(#"Costs $5 and $10; a literal \$ and $x$ after it."#)
        #expect(math(text).count == 1)
        #expect(text.string.contains("$5 and $10"))
        #expect(text.string.contains(#"a literal $ and "#))
    }

    @Test func displayMathStandsOnItsOwnCenteredLine() {
        let text = render(#"""
        Before.

        $$
        \sum_{i=1}^{n} i = \frac{n(n+1)}{2}
        $$

        After.
        """#)
        let pictures = math(text)
        #expect(pictures.count == 1)
        #expect(!text.string.contains("sum_"))
        let mark = "\u{FFFC}"
        #expect(text.string.split(separator: "\n").contains { String($0) == mark })
        let style = text.attribute(.paragraphStyle, at: (text.string as NSString).range(of: mark).location, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.alignment == .center)
    }

    @Test func codeSpansAndFencesAreNeverMath() {
        let text = render(#"""
        Use `$x^2$` and `$$y$$`.

        ```
        $$z$$
        ```
        """#)
        #expect(math(text).isEmpty)
        #expect(text.string.contains("$x^2$"))
        #expect(text.string.contains("$$y$$"))
        #expect(text.string.contains("$$z$$"))
    }

    @Test func unparsableLatexKeepsItsSourceInMonospace() {
        let markdown = #"Broken $\notarealcommand{x}$ here."#
        let text = render(markdown)
        #expect(math(text).isEmpty)
        let range = (text.string as NSString).range(of: #"$\notarealcommand{x}$"#)
        #expect(range.location != NSNotFound)
        guard range.location != NSNotFound else { return }
        let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    @Test func measuredNoteFitsTheMathItDraws() {
        let markdown = #"""
        $$
        \frac{a}{b}
        $$
        """#
        let plain = ObjectMeasure.note(NoteMarkdown.parse("a"), markdown: "a", width: 400, excerpts: [:], images: [:])
        let measured = ObjectMeasure.note(NoteMarkdown.parse(markdown), markdown: markdown, width: 400, excerpts: [:], images: [:])
        #expect(measured.size.height > plain.size.height)
    }
}
