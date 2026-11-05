import AegisCore
import SwiftUI

struct UnlockView: View {
    @Environment(VaultSession.self) private var session
    @State private var password = ""
    @State private var confirmation = ""
    @State private var useRecovery = false
    @State private var showImport = false
    private var creating: Bool { session.phase == .setup }
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
                Text("Aegis").font(.system(size: 28, weight: .medium, design: .serif)).foregroundStyle(.white)
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
                Text(L10n.text("ui.unlockHero")).font(.system(size: 35, weight: .medium, design: .serif)).foregroundStyle(.white).lineSpacing(8)
                Text(L10n.text("ui.unlockHeroDetail")).font(.system(size: 14)).lineSpacing(7).foregroundStyle(.white.opacity(0.6))
            }
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield")
                Text(L10n.text("app.securityCaption"))
            }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).padding(.top, 44)
        }.padding(44).background(LinearGradient(colors: [Color(red: 0.13, green: 0.25, blue: 0.22), AegisTheme.navy], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var unlockForm: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                AegisPill(title: L10n.text("ui.personalVault"), symbol: "lock.shield")
                Text(L10n.text(creating ? "ui.createTitle" : "unlock.title"))
                    .font(.system(size: 32, weight: .semibold)).tracking(-0.8).foregroundStyle(AegisTheme.text)
                Text(L10n.text(creating ? "welcome.description" : "unlock.description"))
                    .font(.system(size: 14)).lineSpacing(5).foregroundStyle(AegisTheme.secondary)
            }
            VStack(spacing: 18) {
                AegisInput(title: L10n.text(useRecovery ? "unlock.recoveryPlaceholder" : "welcome.master"), icon: "lock") {
                    SecureField(L10n.text(useRecovery ? "unlock.recoveryPlaceholder" : "welcome.master"), text: $password)
                        .textContentType(creating ? .newPassword : .password).accessibilityIdentifier("masterPassword").onSubmit(submit)
                }
                if creating {
                    AegisInput(title: L10n.text("welcome.confirm"), icon: "checkmark.shield") {
                        SecureField(L10n.text("welcome.confirm"), text: $confirmation).textContentType(.newPassword).accessibilityIdentifier("confirmPassword").onSubmit(submit)
                    }
                    Text(L10n.text("welcome.passwordHint")).font(.system(size: 11)).foregroundStyle(AegisTheme.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(action: submit) {
                    HStack(spacing: 10) {
                        if session.isBusy { ProgressView().controlSize(.small).tint(.white) }
                        Text(L10n.text(creating ? "action.create" : "action.unlock"))
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                    }
                }.buttonStyle(PrimaryButtonStyle()).disabled(session.isBusy || password.isEmpty || !session.storageAvailable).accessibilityIdentifier("unlockButton")
                if !creating {
                    if session.biometricEnabled {
                        Button { Task { await session.unlockWithBiometrics() } } label: { Label(L10n.text("unlock.biometric"), systemImage: "touchid") }
                            .buttonStyle(AegisButtonStyle(fullWidth: true)).disabled(session.isBusy)
                    }
                    Button(L10n.text(useRecovery ? "unlock.usePassword" : "unlock.useRecovery")) { useRecovery.toggle(); password = "" }
                        .font(.system(size: 12)).foregroundStyle(AegisTheme.teal).buttonStyle(.plain).frame(maxWidth: .infinity).padding(.top, 4)
                }
            }
            if creating {
                VStack(spacing: 16) {
                    Rectangle().fill(AegisTheme.border).frame(height: 1)
                    Button { Task { await session.connectCloud() } } label: { Label(L10n.text("welcome.cloud"), systemImage: "icloud") }
                        .buttonStyle(AegisButtonStyle(fullWidth: true)).disabled(session.isBusy)
                    Text(L10n.text("welcome.cloudHint")).font(.system(size: 11)).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
                    Button(L10n.text("welcome.import")) { showImport = true }.font(.system(size: 12)).foregroundStyle(AegisTheme.teal).buttonStyle(.plain)
                }
            }
            Label(L10n.text("ui.unlockFooter"), systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(AegisTheme.secondary).padding(.top, 10)
        }
    }
    private func submit() {
        guard !session.isBusy else { return }
        if creating, password != confirmation { session.error = L10n.text("error.passwordMismatch"); return }
        let submitted = password; password = ""; confirmation = ""
        Task {
            if creating { await session.create(password: submitted) }
            else { await session.unlock(password: submitted, recovery: useRecovery) }
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
                    Text(L10n.text("recovery.description")).font(.system(size: 14)).lineSpacing(6).foregroundStyle(AegisTheme.secondary)
                    VStack(alignment: .leading, spacing: 20) {
                        Text(session.recoveryKey?.replacingOccurrences(of: "-", with: "  ") ?? "")
                            .font(.system(size: 17, weight: .medium, design: .monospaced)).lineSpacing(12).textSelection(.enabled)
                            .foregroundStyle(AegisTheme.text).frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            if let key = session.recoveryKey { SecureClipboard.copy(key); copied = true }
                        } label: { Label(L10n.text(copied ? "action.copied" : "recovery.copy"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                            .buttonStyle(AegisButtonStyle(fullWidth: true))
                    }.aegisCard().privacySensitive()
                    Label(L10n.text("recovery.warning"), systemImage: "exclamationmark.shield")
                        .font(.system(size: 12)).lineSpacing(5).foregroundStyle(AegisTheme.gold).padding(16)
                        .background(AegisTheme.gold.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    Toggle(L10n.text("recovery.saved"), isOn: Bindable(session).recoveryAcknowledged)
                        .font(.system(size: 13)).toggleStyle(.switch).tint(AegisTheme.teal)
                    Button(L10n.text("recovery.enter")) { session.recoveryKey = nil }
                        .buttonStyle(PrimaryButtonStyle()).disabled(!session.recoveryAcknowledged)
                }.padding(24)
            }
        }.background(AegisTheme.background).aegisSheetSize(width: 540, height: 620).interactiveDismissDisabled()
    }
}
