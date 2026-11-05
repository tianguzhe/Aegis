import AegisMarkdown
import Foundation
import Testing

struct MarkdownFormattingTests {
    @Test func preservesUnicodeSelectionAndSurroundingText() {
        let source = "Before 👩🏽‍💻安全 After"
        let range = (source as NSString).range(of: "👩🏽‍💻安全")
        let edit = MarkdownFormatting.edit(.bold, source: source, selection: range)
        let result = edit.applying(to: source)
        #expect(result == "Before **👩🏽‍💻安全** After")
        #expect((result as NSString).substring(with: edit.selection) == "👩🏽‍💻安全")
    }

    @Test func formatsMultipleTaskLinesWithoutChangingFollowingParagraph() {
        let source = "one\ntwo\n\nkeep"
        let edit = MarkdownFormatting.edit(.task, source: source, selection: NSRange(location: 0, length: 7))
        #expect(edit.applying(to: source) == "- [ ] one\n- [ ] two\n\nkeep")
    }

    @Test func headingAppliesAtLineStartAndKeepsInsertionPoint() {
        let source = "First\nsecond"
        let edit = MarkdownFormatting.edit(.heading, source: source, selection: NSRange(location: 9, length: 0))
        #expect(edit.applying(to: source) == "First\n## second")
        #expect(edit.selection == NSRange(location: 12, length: 0))
    }

    @Test func linkSelectsDestinationForReplacement() {
        let source = "Visit Aegis"
        let edit = MarkdownFormatting.edit(.link, source: source, selection: NSRange(location: 6, length: 5))
        let result = edit.applying(to: source)
        #expect(result == "Visit [Aegis](https://)")
        #expect((result as NSString).substring(with: edit.selection) == "https://")
    }

    @Test func staleSelectionIsSafelyClamped() {
        let edit = MarkdownFormatting.edit(.bullet, source: "", selection: NSRange(location: NSNotFound, length: 8))
        #expect(edit.applying(to: "") == "- ")
        #expect(edit.selection == NSRange(location: 2, length: 0))
    }
}
