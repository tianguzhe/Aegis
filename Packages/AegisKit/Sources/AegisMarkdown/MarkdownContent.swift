import AegisCore
import Foundation
import Markdown
import SwiftUI

public struct MarkdownListEntry: Sendable, Equatable {
    public let marker: String
    public let blocks: [MarkdownBlock]
}

public indirect enum MarkdownBlock: Sendable, Equatable {
    case paragraph(AttributedString)
    case heading(Int, AttributedString)
    case code(String, String?)
    case quote([MarkdownBlock])
    case list([MarkdownListEntry])
    case table([AttributedString], [[AttributedString]])
    case rule
}

public enum MarkdownParser {
    public static func parse(_ source: String) -> [MarkdownBlock] {
        let document = Document(parsing: source, options: [.disableSmartOpts])
        return document.children.flatMap { blocks($0, depth: 0) }
    }

    public static func safeLink(_ destination: String?) -> URL? {
        guard let destination, let url = URL(string: destination),
              let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else { return nil }
        return url
    }

    private static func blocks(_ markup: any Markup, depth: Int) -> [MarkdownBlock] {
        guard depth < 32 else { return [.paragraph(AttributedString(markup.format()))] }
        switch markup {
        case let heading as Heading: return [.heading(heading.level, inline(heading))]
        case let paragraph as Paragraph: return [.paragraph(inline(paragraph))]
        case let code as CodeBlock: return [.code(code.code, code.language)]
        case let html as HTMLBlock: return [.code(html.rawHTML, "HTML")]
        case let quote as BlockQuote: return [.quote(quote.children.flatMap { blocks($0, depth: depth + 1) })]
        case let list as OrderedList:
            return [.list(list.listItems.enumerated().map { index, item in
                MarkdownListEntry(marker: "\(list.startIndex + UInt(index)).", blocks: item.children.flatMap { blocks($0, depth: depth + 1) })
            })]
        case let list as UnorderedList:
            return [.list(list.listItems.map { item in
                let marker: String
                switch item.checkbox { case .checked: marker = "☑"; case .unchecked: marker = "☐"; case nil: marker = "•" }
                return MarkdownListEntry(marker: marker, blocks: item.children.flatMap { blocks($0, depth: depth + 1) })
            })]
        case let table as Markdown.Table:
            return [.table(table.head.cells.map { inline($0) }, table.body.rows.map { row in row.cells.map { inline($0) } })]
        case is ThematicBreak: return [.rule]
        default: return markup.children.flatMap { blocks($0, depth: depth + 1) }
        }
    }

    private static func inline(_ markup: any Markup) -> AttributedString {
        switch markup {
        case let text as Markdown.Text: return AttributedString(text.string)
        case let code as InlineCode:
            var result = AttributedString(code.code)
            result.font = .system(.body, design: .monospaced)
            result.backgroundColor = Color.secondary.opacity(0.12)
            return result
        case is SoftBreak: return AttributedString(" ")
        case is LineBreak: return AttributedString("\n")
        case let html as InlineHTML: return AttributedString(html.rawHTML)
        case let image as Markdown.Image:
            return AttributedString(L10n.format("markdown.imagePlaceholder", image.plainText))
        default:
            var result = markup.children.reduce(AttributedString()) { $0 + inline($1) }
            if markup is Strong {
                for run in result.runs { result[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized) }
            }
            if markup is Emphasis {
                for run in result.runs { result[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.emphasized) }
            }
            if markup is Strikethrough { result.strikethroughStyle = .single }
            if let link = markup as? Markdown.Link, let url = safeLink(link.destination) { result.link = url }
            return result
        }
    }
}

public struct MarkdownContent: View {
    private let source: String
    private let accent: Color
    @State private var blocks: [MarkdownBlock] = []
    @ScaledMetric(relativeTo: .body) private var bodySize = 16
    @ScaledMetric(relativeTo: .title) private var headingSize = 28
    @ScaledMetric(relativeTo: .callout) private var codeSize = 14
    @ScaledMetric(relativeTo: .caption) private var captionSize = 12
    @ScaledMetric(relativeTo: .body) private var taskSize = 20
    public init(_ source: String, accent: Color = .accentColor) { self.source = source; self.accent = accent }

    public var body: some View {
        blockStack(blocks)
            .tint(accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                MarkdownParser.safeLink(url.absoluteString) == nil ? .discarded : .systemAction
            })
            .task(id: source) {
                let source = self.source
                let parsed = await Task.detached(priority: .userInitiated) { MarkdownParser.parse(source) }.value
                guard !Task.isCancelled else { return }
                blocks = parsed
            }
    }

    private func blockStack(_ blocks: [MarkdownBlock]) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block).padding(.top, index == 0 ? 0 : spacing(before: block))
            }
        })
    }

    private func spacing(before block: MarkdownBlock) -> CGFloat {
        switch block {
        case .heading: 28
        case .table, .code, .quote, .rule: 22
        case .list: 16
        case .paragraph: 14
        }
    }

    @ViewBuilder
    private func listMarker(_ marker: String) -> some View {
        if marker == "☑" || marker == "☐" {
            Image(systemName: marker == "☑" ? "checkmark.square.fill" : "square")
                .font(.system(size: taskSize, weight: .medium))
                .foregroundStyle(marker == "☑" ? accent : Color.secondary.opacity(0.8))
                .frame(width: taskSize + 4, height: bodySize * 1.5)
                .accessibilityLabel(L10n.text(marker == "☑" ? "markdown.taskDone" : "markdown.taskPending"))
        } else {
            SwiftUI.Text(marker).font(.system(size: bodySize, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary).frame(minWidth: taskSize + 4, alignment: .trailing)
                .padding(.top, 1)
        }
    }

    private func blockView(_ block: MarkdownBlock) -> AnyView {
        switch block {
        case .paragraph(let text):
            return AnyView(SwiftUI.Text(text).font(.system(size: bodySize)).lineSpacing(7).fixedSize(horizontal: false, vertical: true))
        case .heading(let level, let text):
            let size = level == 1 ? headingSize : level == 2 ? headingSize * 0.79 : level == 3 ? headingSize * 0.68 : bodySize
            return AnyView(SwiftUI.Text(text).font(.system(size: size, weight: .semibold))
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader))
        case .code(let code, let language):
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                if let language, !language.isEmpty {
                    SwiftUI.Text(language.uppercased()).font(.system(size: captionSize, weight: .medium, design: .monospaced))
                        .tracking(0.6).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    SwiftUI.Text(verbatim: code.trimmingCharacters(in: .newlines))
                        .font(.system(size: codeSize, design: .monospaced)).lineSpacing(6)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.04))))
        case .quote(let children):
            return AnyView(blockStack(children).foregroundStyle(.secondary).padding(.vertical, 12).padding(.horizontal, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.6)).frame(width: 4) })
        case .list(let entries):
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 12) {
                        listMarker(entry.marker)
                        blockStack(entry.blocks)
                    }.accessibilityElement(children: .combine)
                }
            })
        case .table(let header, let rows):
            return AnyView(ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            SwiftUI.Text(cell).font(.system(size: bodySize - 1, weight: .semibold))
                                .padding(.horizontal, 18).padding(.vertical, 14).frame(minWidth: 140, alignment: .leading)
                                .background(.primary.opacity(0.06))
                        }
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                SwiftUI.Text(cell).font(.system(size: bodySize - 1))
                                    .padding(.horizontal, 18).padding(.vertical, 14).frame(minWidth: 140, alignment: .leading)
                                    .overlay(alignment: .bottom) { Divider() }
                            }
                        }
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 10)))
        case .rule: return AnyView(Divider().padding(.vertical, 6))
        }
    }
}
