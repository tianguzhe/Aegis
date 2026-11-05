import AegisCore
import Foundation

public enum MarkdownFormatAction: String, CaseIterable, Sendable {
    case heading, bold, italic, bullet, task, quote, code, link
}

public struct MarkdownTextEdit: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
    public let selection: NSRange

    public func applying(to source: String) -> String {
        (source as NSString).replacingCharacters(in: range, with: replacement)
    }
}

public enum MarkdownFormatting {
    public static func edit(_ action: MarkdownFormatAction, source: String, selection: NSRange) -> MarkdownTextEdit {
        let string = source as NSString
        let location = min(selection.location == NSNotFound ? string.length : selection.location, string.length)
        let length = min(selection.length, string.length - location)
        let range: NSRange
        if length == 0 {
            let boundary = location < string.length ? string.rangeOfComposedCharacterSequence(at: location).location : location
            range = NSRange(location: boundary, length: 0)
        } else {
            range = string.rangeOfComposedCharacterSequences(for: NSRange(location: location, length: length))
        }
        let selected = string.substring(with: range)
        switch action {
        case .heading: return prefixLines("## ", source: string, selection: range)
        case .bullet: return prefixLines("- ", source: string, selection: range)
        case .task: return prefixLines("- [ ] ", source: string, selection: range)
        case .quote: return prefixLines("> ", source: string, selection: range)
        case .bold: return wrap("**", "**", selected: selected, range: range)
        case .italic: return wrap("_", "_", selected: selected, range: range)
        case .code: return wrap("```\n", "\n```", selected: selected, range: range)
        case .link:
            let label = selected.isEmpty ? L10n.text("composer.linkText") : selected
            let prefix = "[\(label)]("
            return MarkdownTextEdit(range: range, replacement: prefix + "https://)",
                                    selection: NSRange(location: range.location + prefix.utf16.count, length: 8))
        }
    }

    private static func wrap(_ prefix: String, _ suffix: String, selected: String, range: NSRange) -> MarkdownTextEdit {
        let content = selected.isEmpty ? L10n.text("composer.placeholderText") : selected
        return MarkdownTextEdit(range: range, replacement: prefix + content + suffix,
                                selection: NSRange(location: range.location + prefix.utf16.count, length: content.utf16.count))
    }

    private static func prefixLines(_ prefix: String, source: NSString, selection: NSRange) -> MarkdownTextEdit {
        let lines = source.lineRange(for: selection)
        let content = source.substring(with: lines)
        var components = content.components(separatedBy: "\n")
        for index in components.indices where index < components.count - 1 || !components[index].isEmpty || components.count == 1 {
            components[index] = prefix + components[index]
        }
        let replacement = components.joined(separator: "\n")
        let caret = selection.length == 0
            ? NSRange(location: selection.location + prefix.utf16.count, length: 0)
            : NSRange(location: lines.location, length: replacement.utf16.count)
        return MarkdownTextEdit(range: lines, replacement: replacement, selection: caret)
    }
}
