import AegisCore
import SwiftUI

/// Advisory strength indicator. It never blocks submission on its own; callers keep their own policy.
struct PasswordStrengthMeter: View {
    let password: String
    var showsSuggestions = true

    private var evaluation: PasswordStrength.Evaluation {
        PasswordStrength.evaluate(password)
    }

    static func tint(for level: PasswordStrength.Level) -> Color {
        switch level {
        case .weak: AegisTheme.danger
        case .fair: Color.orange
        case .good: AegisTheme.gold
        case .strong: AegisTheme.teal
        }
    }

    var body: some View {
        let evaluation = evaluation
        let tint = Self.tint(for: evaluation.level)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(PasswordStrength.Level.allCases, id: \.rawValue) { level in
                        Capsule().fill(level <= evaluation.level ? tint : AegisTheme.border)
                            .frame(height: 4)
                    }
                }
                Text(L10n.format("strength.label", evaluation.level.title))
                    .aegisFont(size: 11, weight: .medium).foregroundStyle(tint).fixedSize()
            }
            if showsSuggestions, let suggestion = evaluation.suggestions.first {
                Label(suggestion.message, systemImage: "lightbulb")
                    .aegisFont(size: 11).foregroundStyle(AegisTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(password.isEmpty ? 0 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("passwordStrength")
    }
}

/// Master passwords are the only barrier against offline guessing of a copied vault header, so a
/// password rated below `.good` needs an explicit acknowledgement before it can be used.
struct WeakPasswordAcknowledgement: View {
    let password: String
    @Binding var acknowledged: Bool

    static func required(for password: String) -> Bool {
        !password.isEmpty && PasswordStrength.evaluate(password).level < .good
    }

    var body: some View {
        if Self.required(for: password) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.text("strength.weakMasterWarning"), systemImage: "exclamationmark.triangle")
                    .aegisFont(size: 12).lineSpacing(4).foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L10n.text("strength.weakMasterAcknowledge"), isOn: $acknowledged)
                    .aegisFont(size: 12).accessibilityIdentifier("weakPasswordAcknowledge")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
