import AppKit
import Foundation
import Testing
@testable import CanvasCore

@MainActor
struct NoteMathBoundsTests {
    private func hostileFormulas() -> [String] {
        let depth = 1000
        return [
            String(repeating: #"\frac{1}{"#, count: depth) + "1" + String(repeating: "}", count: depth),
            String(repeating: "{", count: depth) + "x" + String(repeating: "}", count: depth),
            String(repeating: #"\sqrt{"#, count: depth) + "x" + String(repeating: "}", count: depth),
            String(repeating: #"\sqrt "#, count: depth) + "x",
            String(repeating: #"\sqrt["#, count: depth) + "2" + String(repeating: "]{x}", count: depth),
            String(repeating: #"\left("#, count: depth) + "x" + String(repeating: #"\right)"#, count: depth),
            String(repeating: #"\begin{matrix}"#, count: depth) + "x" + String(repeating: #"\end{matrix}"#, count: depth),
            String(repeating: "x_{", count: depth) + "x" + String(repeating: "}", count: depth),
            String(repeating: "x^{", count: depth) + "x" + String(repeating: "}", count: depth),
            String(repeating: #"x\over "#, count: depth) + "x",
            String(repeating: #"\hat "#, count: depth) + "x",
            String(repeating: #"\mathbf "#, count: depth) + "x",
            String(repeating: "x", count: 1_000_000),
        ]
    }

    @Test func hostileFormulasNeverEnterNativeTypesetting() {
        for latex in hostileFormulas() {
            #expect(NoteMath.attachment(latex: latex, fontSize: 13, display: true) == nil)
            #expect(NoteMath.attachment(latex: latex, fontSize: 13, display: false) == nil)
        }
    }

    @Test func rejectedFormulasKeepTheirLiteralSourceInMonospace() throws {
        for latex in hostileFormulas() {
            let markdown = "$$\n" + latex + "\n$$"
            let text = NoteRenderer(excerpts: [:], source: markdown, width: 400).render(NoteMarkdown.parse(markdown), placeholder: "")
            #expect(text.string.trimmingCharacters(in: .whitespacesAndNewlines) == markdown)
            var attachmentCount = 0
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if value != nil { attachmentCount += 1 }
            }
            #expect(attachmentCount == 0)
            let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
        }
    }

    @Test func sizeFitMeasuresTheRejectedFormulaAsSource() async throws {
        let latex = String(repeating: #"\frac{1}{"#, count: 1000) + "1" + String(repeating: "}", count: 1000)
        let markdown = "$$\n" + latex + "\n$$"
        let text = NoteRenderer(excerpts: [:], source: markdown, width: 384).render(NoteMarkdown.parse(markdown), placeholder: "")
        let measured = try await ObjectMeasure.size(type: .note, props: .object(["markdown": .string(markdown)]), width: 400, root: URL(fileURLWithPath: "/tmp"))
        let expectedHeight = (CodeMetrics.titleHeight + 2 * ObjectMeasure.noteInset.height + ObjectMeasure.noteTextHeight(text, width: 384)).rounded(.up)
        #expect(measured == CGSize(width: 400, height: expectedHeight))
    }

    @Test func smallFormulasAndEscapedSymbolsStillTypeset() {
        for latex in [#"\frac{a}{b}"#, #"\sqrt[3]{x^2}"#, #"\left(\frac{a}{b}\right)"#, #"\begin{matrix}a&b\\c&d\end{matrix}"#, #"\{x\}"#] {
            #expect(NoteMath.attachment(latex: latex, fontSize: 13, display: true) != nil)
        }
    }
    @Test func byteAndRecursionBoundariesPreserveAcceptedMath() {
        #expect(NoteMath.attachment(latex: String(repeating: "x", count: 2048), fontSize: 13, display: true) != nil)
        #expect(NoteMath.attachment(latex: String(repeating: "x", count: 2049), fontSize: 13, display: true) == nil)
        let accepted = String(repeating: "{", count: 16) + "x" + String(repeating: "}", count: 16)
        let rejected = String(repeating: "{", count: 17) + "x" + String(repeating: "}", count: 17)
        #expect(NoteMath.attachment(latex: accepted, fontSize: 13, display: true) != nil)
        #expect(NoteMath.attachment(latex: rejected, fontSize: 13, display: true) == nil)
        #expect(NoteMath.attachment(latex: String(repeating: #"\sqrt "#, count: 16) + "x", fontSize: 13, display: true) != nil)
        #expect(NoteMath.attachment(latex: String(repeating: #"\sqrt "#, count: 17) + "x", fontSize: 13, display: true) == nil)
    }
}
