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
