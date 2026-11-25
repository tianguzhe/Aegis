import AegisCore
import SwiftUI

/// Master password change with key rotation (Docs/KEY_ROTATION_DESIGN.md §4). After success the
/// sheet shows the new recovery key itself and closes once it is confirmed.
struct ChangeMasterPasswordView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var finished = false
    @State private var compactHistory = false

    private var validPassword: Bool {
        password.count >= 12 && password.utf8.count <= 4096
    }

    private var canSubmit: Bool {
        !session.isBusy && !current.isEmpty && validPassword && password == confirmation
    }

    var body: some View {
        Group {
            if finished, session.recoveryKey != nil {
                RecoveryView()
            } else {
                form
            }
        }
        .onAppear { session.recoveryPresentedInline = true }
        .onDisappear { session.recoveryPresentedInline = false }
        .onChange(of: session.recoveryKey) {
            _, key in if finished, key == nil {
                dismiss()
            }
        }
    }

    private var form: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text("rotation.title"), symbol: "key", close: { dismiss() }, closeDisabled: session.isBusy)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.text("rotation.description")).aegisFont(size: 13).lineSpacing(5).foregroundStyle(AegisTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(L10n.text("rotation.warning"), systemImage: "exclamationmark.triangle")
                        .aegisFont(size: 12).lineSpacing(4).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
                    AegisInput(title: L10n.text("rotation.current"), icon: "lock") {
                        SecureField(L10n.text("rotation.current"), text: $current).textContentType(.password)
                            .accessibilityIdentifier("currentMasterPassword")
                    }
                    AegisInput(title: L10n.text("rotation.new"), icon: "key") {
                        SecureField(L10n.text("rotation.new"), text: $password).textContentType(.newPassword)
                            .accessibilityIdentifier("newMasterPassword")
                    }
                    if !password.isEmpty {
                        PasswordStrengthMeter(password: password)
                    }
                    AegisInput(title: L10n.text("rotation.confirm"), icon: "checkmark.shield") {
                        SecureField(L10n.text("rotation.confirm"), text: $confirmation).textContentType(.newPassword)
                            .accessibilityIdentifier("confirmNewMasterPassword")
                    }
                    let mismatch = !confirmation.isEmpty && password != confirmation
                    Label(L10n.text(mismatch ? "error.passwordMismatch" : "rotation.requirement"),
                          systemImage: validPassword && !mismatch ? "checkmark.circle.fill" : "info.circle")
                        .aegisFont(size: 11).foregroundStyle(mismatch ? Color.orange : AegisTheme.secondary)
                    Toggle(L10n.text("rotation.compactHistory"), isOn: $compactHistory)
                    if compactHistory {
                        Text(L10n.text("rotation.compactHistoryDetail"))
                            .aegisFont(size: 12).foregroundStyle(AegisTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Button(action: submit) {
                        HStack {
                            if session.isBusy {
                                ProgressView().controlSize(.small).tint(AegisTheme.disabledText)
                            }
                            Text(L10n.text(session.isBusy ? "rotation.working" : "rotation.action"))
                        }
                    }.buttonStyle(PrimaryButtonStyle()).disabled(!canSubmit).accessibilityIdentifier("changeMasterPasswordSubmit")
                }.padding(24).disabled(session.isBusy)
            }
        }.background(AegisTheme.background).aegisSheetSize(width: 540, height: 620).vaultErrorPresenter()
            .interactiveDismissDisabled(session.isBusy).privacySensitive().autocorrectionDisabled()
    }

    private func submit() {
        guard canSubmit else { return }
        let submittedCurrent = current, submittedNew = password, shouldCompact = compactHistory
        current = ""
        Task {
            if await session.changeMasterPassword(current: submittedCurrent, new: submittedNew, compactHistory: shouldCompact) {
                password = ""; confirmation = ""
                // Locked during the commit: the recovery key appears after the next unlock instead.
                if session.recoveryKey == nil {
                    dismiss()
                } else {
                    finished = true
                }
            }
        }
    }
}
