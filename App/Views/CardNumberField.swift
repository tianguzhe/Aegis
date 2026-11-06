import AegisCore
import SwiftUI

#if os(iOS)
import UIKit

/// Filter at the native edit boundary rather than asynchronously overwriting SwiftUI text.
struct CardNumberField: UIViewRepresentable {
    @Binding var text: String
    @ScaledMetric(relativeTo: .body) private var fontSize = 15

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.keyboardType = .numberPad
        field.textContentType = .creditCardNumber
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.placeholder = L10n.text("field.cardNumber")
        field.accessibilityLabel = L10n.text("field.cardNumber")
        field.accessibilityIdentifier = "cardNumber"
        field.text = CardNumberRules.digits(from: text)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = UIColor(AegisTheme.text)
        if !field.isFirstResponder { field.text = CardNumberRules.digits(from: text) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: max(22, fontSize * 1.3))
    }

    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        @objc func changed(_ field: UITextField) { text.wrappedValue = field.text ?? "" }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString value: String) -> Bool {
            let current = field.text ?? ""
            let ns = current as NSString
            guard range.location <= ns.length, range.length <= ns.length - range.location else { return false }
            let replacement = CardNumberRules.digits(from: value)
            guard replacement != value else { return true }
            let updated = ns.replacingCharacters(in: range, with: replacement)
            field.text = updated
            if let position = field.position(from: field.beginningOfDocument, offset: range.location + replacement.utf16.count) {
                field.selectedTextRange = field.textRange(from: position, to: position)
            }
            text.wrappedValue = updated
            return false
        }

        func textFieldDidEndEditing(_ textField: UITextField) { changed(textField) }
    }
}
#else
import AppKit

struct CardNumberField: NSViewRepresentable {
    @Binding var text: String
    @ScaledMetric(relativeTo: .body) private var fontSize = 15

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = L10n.text("field.cardNumber")
        field.setAccessibilityLabel(L10n.text("field.cardNumber"))
        field.setAccessibilityIdentifier("cardNumber")
        field.stringValue = CardNumberRules.digits(from: text)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = NSColor(AegisTheme.text)
        if field.currentEditor() == nil { field.stringValue = CardNumberRules.digits(from: text) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: max(22, fontSize * 1.3))
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let original = field.stringValue
            let digits = CardNumberRules.digits(from: original)
            if digits != original {
                if let editor = field.currentEditor() as? NSTextView {
                    let location = min(editor.selectedRange().location, (original as NSString).length)
                    let prefix = (original as NSString).substring(to: location)
                    field.stringValue = digits
                    editor.string = digits
                    editor.setSelectedRange(NSRange(location: CardNumberRules.digits(from: prefix).utf16.count, length: 0))
                } else {
                    field.stringValue = digits
                }
            }
            text.wrappedValue = digits
        }

        func controlTextDidEndEditing(_ notification: Notification) { controlTextDidChange(notification) }
    }
}
#endif
