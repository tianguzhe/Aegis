import AegisCore
import SwiftUI

struct UnlockView: View {
    @Environment(VaultSession.self) private var session
    @State private var password = ""
    @State private var confirmation = ""
    @State private var useRecovery = false
    @State private var showImport = false
    private var creating: Bool { session.phase == .setup }
    private var validCreationPassword: Bool { password.count >= 12 && password.utf8.count <= 4096 }
    private var canSubmit: Bool {
        !session.isBusy && session.storageAvailable && !password.isEmpty &&
        (!creating || (validCreationPassword && password == confirmation))
    }
    private var confirmationHint: String {
        if confirmation.isEmpty { return L10n.text("welcome.confirmHint") }
        return L10n.text(password == confirmation ? "welcome.passwordMatch" : "error.passwordMismatch")
    }
    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 850 {
                HStack(spacing: 0) {
                    brandPanel.frame(width: geometry.size.width * 0.43)
                    ScrollView {
                        unlockForm.padding(48).frame(maxWidth: 520).frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 36) {
                        AegisBrand(compact: true).padding(.top, 20)
                        unlockForm
                    }.padding(28).frame(maxWidth: 480).frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                }
            }
        }.background(AegisTheme.background)
            .sheet(isPresented: $showImport) { ImportBackupView().environment(session) }
            .onDisappear { password = ""; confirmation = "" }
    }

    private var brandPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                AegisMark(size: 38)
                Text("Aegis").aegisFont(size: 28, weight: .medium, design: .serif).foregroundStyle(.white)
            }
            Spacer()
            ZStack {
                ForEach(0..<3) { index in
                    RoundedRectangle(cornerRadius: CGFloat(42 + index * 18)).stroke(.white.opacity(0.06), lineWidth: 1)
                        .frame(width: CGFloat(190 + index * 72), height: CGFloat(190 + index * 72)).rotationEffect(.degrees(-12))
                }
                AegisMark(size: 128).rotationEffect(.degrees(-12)).shadow(color: .black.opacity(0.15), radius: 30, y: 20)
            }.frame(maxWidth: .infinity).frame(height: 310).accessibilityHidden(true)
            Spacer()
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.text("ui.unlockHero")).aegisFont(size: 35, weight: .medium, design: .serif).foregroundStyle(.white).lineSpacing(8)
                Text(L10n.text("ui.unlockHeroDetail")).aegisFont(size: 14).lineSpacing(7).foregroundStyle(.white.opacity(0.6))
            }
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield")
                Text(L10n.text("app.securityCaption"))
            }.aegisFont(size: 11).foregroundStyle(.white.opacity(0.45)).padding(.top, 44)
        }.padding(44).background(LinearGradient(colors: [Color(red: 0.13, green: 0.25, blue: 0.22), AegisTheme.navy], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var unlockForm: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                AegisPill(title: L10n.text("ui.personalVault"), symbol: "lock.shield")
                Text(L10n.text(creating ? "ui.createTitle" : "unlock.title"))
                    .aegisFont(size: 32, weight: .semibold).tracking(-0.8).foregroundStyle(AegisTheme.text)
                Text(L10n.text(creating ? "welcome.description" : "unlock.description"))
                    .aegisFont(size: 14).lineSpacing(5).foregroundStyle(AegisTheme.secondary)
            }
            VStack(spacing: 18) {
                AegisInput(title: L10n.text(useRecovery ? "unlock.recoveryPlaceholder" : "welcome.master"), icon: "lock") {
                    SecureField(L10n.text(useRecovery ? "unlock.recoveryPlaceholder" : "welcome.master"), text: $password)
                        .textContentType(creating ? .newPassword : .password).accessibilityIdentifier("masterPassword").onSubmit(submit)
                }.disabled(session.isBusy)
                if creating {
                    AegisInput(title: L10n.text("welcome.confirm"), icon: "checkmark.shield") {
                        SecureField(L10n.text("welcome.confirm"), text: $confirmation).textContentType(.newPassword).accessibilityIdentifier("confirmPassword").onSubmit(submit)
                    }.disabled(session.isBusy)
                    VStack(alignment: .leading, spacing: 7) {
                        Label(L10n.text(password.utf8.count > 4096 ? "welcome.passwordTooLong" : "welcome.passwordHint"),
                              systemImage: validCreationPassword ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(validCreationPassword ? AegisTheme.teal : AegisTheme.secondary)
                        Label(confirmationHint,
                              systemImage: !confirmation.isEmpty && password == confirmation ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(!confirmation.isEmpty && password == confirmation ? AegisTheme.teal : AegisTheme.secondary)
                    }.aegisFont(size: 11).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("creationRequirements")
                }
                Button(action: submit) {
                    HStack(spacing: 10) {
                        if session.isBusy { ProgressView().controlSize(.small).tint(AegisTheme.disabledText) }
                        Text(L10n.text(session.isBusy ? (creating ? "action.creating" : "action.unlocking") : (creating ? "action.create" : "action.unlock")))
                        if !session.isBusy { Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)) }
                    }
                }.buttonStyle(PrimaryButtonStyle()).disabled(!canSubmit).accessibilityIdentifier("unlockButton")
                if !creating {
                    if session.biometricEnabled {
                        Button { Task { await session.unlockWithBiometrics() } } label: { Label(L10n.text("unlock.biometric"), systemImage: "touchid") }
                            .buttonStyle(AegisButtonStyle(fullWidth: true)).disabled(session.isBusy)
                    }
                    Button(L10n.text(useRecovery ? "unlock.usePassword" : "unlock.useRecovery")) { useRecovery.toggle(); password = "" }
                        .aegisFont(size: 12).foregroundStyle(session.isBusy ? AegisTheme.disabledText : AegisTheme.teal).buttonStyle(.plain).frame(maxWidth: .infinity).padding(.top, 4).disabled(session.isBusy)
                }
            }
            if creating {
                VStack(spacing: 16) {
                    Rectangle().fill(AegisTheme.border).frame(height: 1)
                    Button { Task { await session.connectCloud() } } label: { Label(L10n.text("welcome.cloud"), systemImage: "icloud") }
                        .buttonStyle(AegisButtonStyle(fullWidth: true)).disabled(session.isBusy)
                    Text(L10n.text("welcome.cloudHint")).aegisFont(size: 11).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
                    Button(L10n.text("welcome.import")) { showImport = true }.aegisFont(size: 12).foregroundStyle(session.isBusy ? AegisTheme.disabledText : AegisTheme.teal).buttonStyle(.plain).disabled(session.isBusy)
                }
            }
            Label(L10n.text("ui.unlockFooter"), systemImage: "lock.shield").aegisFont(size: 11).foregroundStyle(AegisTheme.secondary).padding(.top, 10)
        }
    }
    private func submit() {
        guard canSubmit else { return }
        let isCreating = creating, isRecovery = useRecovery
        let submitted = password; password = ""; confirmation = ""
        Task {
            if isCreating { await session.create(password: submitted) }
            else { await session.unlock(password: submitted, recovery: isRecovery) }
        }
    }
}

struct RecoveryView: View {
    @Environment(VaultSession.self) private var session
    @State private var copied = false
    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text("recovery.title"), symbol: "key.horizontal")
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(L10n.text("recovery.description")).aegisFont(size: 14).lineSpacing(6).foregroundStyle(AegisTheme.secondary)
                    VStack(alignment: .leading, spacing: 20) {
                        Text(session.recoveryKey?.replacingOccurrences(of: "-", with: "  ") ?? "")
                            .aegisFont(size: 17, weight: .medium, design: .monospaced).lineSpacing(12).textSelection(.enabled)
                            .foregroundStyle(AegisTheme.text).frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            if let key = session.recoveryKey { SecureClipboard.copy(key); copied = true }
                        } label: { Label(L10n.text(copied ? "action.copied" : "recovery.copy"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                            .buttonStyle(AegisButtonStyle(fullWidth: true))
                    }.aegisCard().privacySensitive()
                    Label(L10n.text("recovery.warning"), systemImage: "exclamationmark.shield")
                        .aegisFont(size: 12).lineSpacing(5).foregroundStyle(AegisTheme.gold).padding(16)
                        .background(AegisTheme.gold.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    Toggle(L10n.text("recovery.saved"), isOn: Bindable(session).recoveryAcknowledged)
                        .aegisFont(size: 13).toggleStyle(.switch).tint(AegisTheme.teal)
                        .accessibilityIdentifier("recoveryAcknowledgement")
                    VStack(spacing: 10) {
                        Button(L10n.text("recovery.enter")) {
                            guard session.recoveryAcknowledged else { return }
                            session.confirmRecovery()
                        }.buttonStyle(PrimaryButtonStyle()).disabled(!session.recoveryAcknowledged)
                            .accessibilityIdentifier("enterVaultButton")
                        Label(L10n.text(session.recoveryAcknowledged ? "recovery.confirmedHint" : "recovery.confirmHint"),
                              systemImage: session.recoveryAcknowledged ? "checkmark.circle" : "info.circle")
                            .aegisFont(size: 11).foregroundStyle(session.recoveryAcknowledged ? AegisTheme.teal : AegisTheme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(24)
            }
        }.background(AegisTheme.background).aegisSheetSize(width: 540, height: 620).interactiveDismissDisabled().vaultErrorPresenter()
            .onChange(of: session.recoveryAcknowledged) { _, _ in session.touch() }
    }
}
