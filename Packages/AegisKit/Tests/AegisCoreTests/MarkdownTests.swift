import AegisMarkdown
import Foundation
import Testing

struct MarkdownTests {
    @Test func parsesCommonMarkBlocksAndTasks() throws {
        let blocks = MarkdownParser.parse("# Heading\n\nA **strong** paragraph.\n\n- [x] Done\n- [ ] Todo\n\n> Quote\n\n```swift\nlet value = 1\n```\n\n---")
        #expect(blocks.count == 6)
        guard case .heading(1, let title) = blocks[0], case .list(let entries) = blocks[2],
              case .quote = blocks[3], case .code(let code, let language) = blocks[4] else {
            Issue.record("Markdown block types were not preserved"); return
        }
        #expect(String(title.characters) == "Heading")
        #expect(entries.map(\.marker) == ["☑", "☐"])
        #expect(language == "swift")
        #expect(code.contains("let value = 1"))
    }

    @Test func parsesTableAndOrderedList() {
        let blocks = MarkdownParser.parse("| Name | Value |\n| --- | --- |\n| A | B |\n\n3. Three\n4. Four")
        guard case .table(let header, let rows) = blocks.first, case .list(let entries) = blocks.last else {
            Issue.record("Table or ordered list missing"); return
        }
        #expect(header.count == 2)
        #expect(rows.count == 1)
        #expect(entries.map(\.marker) == ["3.", "4."])
    }

    @Test func blocksExecutableAndLocalFileLinks() {
        #expect(MarkdownParser.safeLink("javascript:alert(1)") == nil)
        #expect(MarkdownParser.safeLink("file:///etc/passwd") == nil)
        #expect(MarkdownParser.safeLink("data:text/html,hello") == nil)
        #expect(MarkdownParser.safeLink("https://example.com") != nil)
        #expect(MarkdownParser.safeLink("mailto:hello@example.com") != nil)
    }

    @Test func imagesRemainTextAndHTMLIsLiteral() {
        let blocks = MarkdownParser.parse("![private image](https://example.com/tracker.png)\n\n<script>alert(1)</script>")
        guard case .paragraph(let image) = blocks.first, case .code(let html, _) = blocks.last else {
            Issue.record("Image and HTML handling changed"); return
        }
        #expect(String(image.characters).contains("private image"))
        #expect(!String(image.characters).contains("https://"))
        #expect(html.contains("<script>"))
    }
}
