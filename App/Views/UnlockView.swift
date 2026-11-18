import AegisCore
import SwiftUI

struct UnlockView: View {
    @Environment(VaultSession.self) private var session
    @State private var password = ""
    @State private var confirmation = ""
    @State private var useRecovery = false
    @State private var showImport = false
    @State private var showLocalImport = false
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
                    brandPanel.frame(width: min(geometry.size.width * 0.38, 420))
                    ScrollView {
                        unlockForm.padding(40).frame(maxWidth: 500).frame(maxWidth: .infinity, minHeight: geometry.size.height)
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
            .sheet(isPresented: $showLocalImport) { LocalVaultTransferView(mode: .receive).environment(session) }
            .onDisappear { password = ""; confirmation = "" }
    }

    private var brandPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AegisMark(size: 32)
                Text("Aegis").aegisFont(size: 22, weight: .semibold).foregroundStyle(.white)
            }
            Spacer(minLength: 40)
            AegisMark(size: 84).padding(.bottom, 30)
            Text(L10n.text("welcome.heroTitle")).aegisFont(size: 30, weight: .semibold)
                .foregroundStyle(.white).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("welcome.heroSubtitle")).aegisFont(size: 13)
                .foregroundStyle(.white.opacity(0.78)).lineSpacing(5).padding(.top, 14)
            VStack(alignment: .leading, spacing: 18) {
                brandFeature("welcome.feature.local", symbol: "externaldrive")
                brandFeature("welcome.feature.encrypted", symbol: "lock.shield")
                brandFeature("welcome.feature.devices", symbol: "macbook.and.iphone")
            }.padding(.top, 34)
            Spacer(minLength: 40)
            Label(L10n.text("ui.personalVault"), systemImage: "checkmark.shield")
                .aegisFont(size: 11).foregroundStyle(.white.opacity(0.72))
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(AegisTheme.navy)
    }
    private func brandFeature(_ key: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 20)
            Text(L10n.text(key)).aegisFont(size: 12)
        }.foregroundStyle(.white.opacity(0.86))
    }

    private var unlockForm: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text(creating ? "welcome.startTitle" : "unlock.title"))
                    .aegisFont(size: 28, weight: .semibold).tracking(-0.8).foregroundStyle(AegisTheme.text)
                Text(L10n.text(creating ? "welcome.description" : "unlock.description"))
                    .aegisFont(size: 14).lineSpacing(5).foregroundStyle(AegisTheme.secondary)
            }
            if creating {
                VStack(alignment: .leading, spacing: 14) {
                    Button { showLocalImport = true } label: {
                        Label(L10n.text("welcome.localImport"), systemImage: "wifi")
                    }.buttonStyle(AegisButtonStyle(fullWidth: true)).accessibilityIdentifier("localImportButton")
                    Text(L10n.text("welcome.localImportHint")).aegisFont(size: 11).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
                    Button { showImport = true } label: {
                        Label(L10n.text("welcome.import"), systemImage: "square.and.arrow.down")
                    }.buttonStyle(AegisButtonStyle(fullWidth: true)).accessibilityIdentifier("onboardingBackupImportButton")
                }.disabled(session.isBusy || !session.storageAvailable)
                Text(L10n.text("welcome.newVault")).aegisFont(size: 14, weight: .semibold).foregroundStyle(AegisTheme.text)
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
                    if session.cloudConfigured {
                        Button { Task { await session.connectCloud() } } label: { Label(L10n.text("welcome.cloud"), systemImage: "icloud") }
                            .buttonStyle(AegisButtonStyle(fullWidth: true)).disabled(session.isBusy || session.isConnectingCloud)
                        Text(L10n.text("welcome.cloudHint")).aegisFont(size: 11).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
                    }
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
