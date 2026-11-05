import AegisMarkdown
import SwiftUI

struct MarkdownEditorCommand: Identifiable {
    enum Action { case format(MarkdownFormatAction), dismissKeyboard }
    let id = UUID()
    let action: Action
}

#if os(iOS)
import UIKit

struct MarkdownSourceEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var isFocused: Bool
    var command: MarkdownEditorCommand?
    var identifier: String
    var fontSize: CGFloat = 16

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.textColor = UIColor(AegisTheme.text)
        view.tintColor = UIColor(AegisTheme.teal)
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: fontSize, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.textContainerInset = UIEdgeInsets(top: 20, left: 14, bottom: 24, right: 14)
        view.textContainer.lineFragmentPadding = 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        view.typingAttributes = [.font: view.font!, .foregroundColor: view.textColor!, .paragraphStyle: paragraph]
        view.text = text
        view.selectedRange = bounded(selection, count: view.text.utf16.count)
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = AegisCoreLabel.editor
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.updating = true
        if view.text != text, view.markedTextRange == nil {
            view.text = text
            view.selectedRange = bounded(selection, count: view.text.utf16.count)
        }
        let textColor = UIColor(AegisTheme.text), tintColor = UIColor(AegisTheme.teal)
        if view.textColor != textColor { view.textColor = textColor }
        if view.tintColor != tintColor { view.tintColor = tintColor }
        coordinator.updating = false
        if let command, coordinator.lastCommand != command.id {
            coordinator.lastCommand = command.id
            // Native editor actions run after SwiftUI finishes updating bindings.
            DispatchQueue.main.async { [weak view, weak coordinator] in
                guard let view, let coordinator else { return }
                coordinator.perform(command.action, in: view)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 220)
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownSourceEditor
        var lastCommand: UUID?
        var updating = false
        init(_ parent: MarkdownSourceEditor) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) {
            guard !updating else { return }
            parent.text = view.text
            parent.selection = view.selectedRange
        }
        func textViewDidChangeSelection(_ view: UITextView) {
            guard !updating, view.isFirstResponder, parent.selection != view.selectedRange else { return }
            parent.selection = view.selectedRange
        }
        func textViewDidBeginEditing(_ view: UITextView) { updateFocus(true) }
        func textViewDidEndEditing(_ view: UITextView) { updateFocus(false) }
        private func updateFocus(_ focused: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.isFocused != focused else { return }
                self.parent.isFocused = focused
            }
        }
        func perform(_ action: MarkdownEditorCommand.Action, in view: UITextView) {
            switch action {
            case .dismissKeyboard: view.resignFirstResponder()
            case .format(let format):
                let edit = MarkdownFormatting.edit(format, source: view.text, selection: parent.selection)
                view.becomeFirstResponder()
                guard let start = view.position(from: view.beginningOfDocument, offset: edit.range.location),
                      let end = view.position(from: start, offset: edit.range.length),
                      let range = view.textRange(from: start, to: end) else { return }
                view.replace(range, withText: edit.replacement)
                view.selectedRange = edit.selection
                view.scrollRangeToVisible(edit.selection)
                textViewDidChange(view)
            }
        }
    }
}
#else
import AppKit

struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var isFocused: Bool
    var command: MarkdownEditorCommand?
    var identifier: String
    var fontSize: CGFloat = 16

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = NSTextView(frame: .zero)
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.drawsBackground = false
        view.textColor = NSColor(AegisTheme.text)
        view.insertionPointColor = NSColor(AegisTheme.teal)
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.textContainerInset = NSSize(width: 20, height: 22)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        view.defaultParagraphStyle = paragraph
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        view.string = text
        view.setSelectedRange(bounded(selection, count: view.string.utf16.count))
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(AegisCoreLabel.editor)
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.updating = true
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            view.setSelectedRange(bounded(selection, count: view.string.utf16.count))
        }
        view.textColor = NSColor(AegisTheme.text)
        view.insertionPointColor = NSColor(AegisTheme.teal)
        coordinator.updating = false
        if let command, coordinator.lastCommand != command.id {
            coordinator.lastCommand = command.id
            DispatchQueue.main.async { [weak view, weak coordinator] in
                guard let view, let coordinator else { return }
                coordinator.perform(command.action, in: view)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownSourceEditor
        var lastCommand: UUID?
        var updating = false
        init(_ parent: MarkdownSourceEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.selection = view.selectedRange()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView,
                  view.window?.firstResponder === view, parent.selection != view.selectedRange() else { return }
            parent.selection = view.selectedRange()
        }
        func textDidBeginEditing(_ notification: Notification) { updateFocus(true) }
        func textDidEndEditing(_ notification: Notification) { updateFocus(false) }
        private func updateFocus(_ focused: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.isFocused != focused else { return }
                self.parent.isFocused = focused
            }
        }
        func perform(_ action: MarkdownEditorCommand.Action, in view: NSTextView) {
            switch action {
            case .dismissKeyboard: view.window?.makeFirstResponder(nil)
            case .format(let format):
                let edit = MarkdownFormatting.edit(format, source: view.string, selection: parent.selection)
                view.window?.makeFirstResponder(view)
                view.insertText(edit.replacement, replacementRange: edit.range)
                view.setSelectedRange(edit.selection)
                view.scrollRangeToVisible(edit.selection)
                parent.text = view.string
                parent.selection = view.selectedRange()
            }
        }
    }
}
#endif

import AegisCore
private enum AegisCoreLabel { static var editor: String { L10n.text("markdown.editor") } }
private func bounded(_ range: NSRange, count: Int) -> NSRange {
    let location = min(range.location == NSNotFound ? count : range.location, count)
    return NSRange(location: location, length: min(range.length, count - location))
}
