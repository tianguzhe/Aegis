import AegisCore
import SwiftUI
import UniformTypeIdentifiers

/// Export sheet (Docs/BACKUP_FORMAT_DESIGN_V1.md §4.2, §9): mode choice, device-owner check, sealing, save.
struct ExportBackupView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var usesBackupPassword = false
    @State private var working = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var passwordOnly = false
    @State private var needsMasterPassword = false
    @State private var masterPassword = ""
    @State private var document: EncryptedBackupDocument?
    @State private var showExporter = false

    /// Backup passwords are NFC-normalized before sealing, so confirmation compares the same form.
    private var busy: Bool {
        session.isBusy || working
    }

    private var normalizedPassword: String {
        password.precomposedStringWithCanonicalMapping
    }

    private var passwordsMatch: Bool {
        normalizedPassword.utf8.elementsEqual(confirmation.precomposedStringWithCanonicalMapping.utf8)
    }

    private var canExport: Bool {
        guard !busy, !(needsMasterPassword && masterPassword.isEmpty) else { return false }
        return !usesBackupPassword || (normalizedPassword.count >= BackupCryptor.minimumPasswordCharacters && passwordsMatch)
    }

    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text("backup.exportTitle"), symbol: "square.and.arrow.up", close: { dismiss() }, closeDisabled: busy)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modeOption(selected: !usesBackupPassword, title: "backup.mode.vault.title", detail: "backup.mode.vault.detail",
                               symbol: "checkmark.shield", identifier: "exportModeVault") { usesBackupPassword = false }
                    modeOption(selected: usesBackupPassword, title: "backup.mode.password.title", detail: "backup.mode.password.detail",
                               symbol: "key", identifier: "exportModePassword") { usesBackupPassword = true }
                    if usesBackupPassword {
                        AegisInput(title: L10n.text("backup.newPassword"), icon: "lock") {
                            SecureField(L10n.text("backup.newPassword"), text: $password).textContentType(.newPassword)
                                .accessibilityIdentifier("backupPassword")
                        }
                        AegisInput(title: L10n.text("backup.confirmPassword"), icon: "lock") {
                            SecureField(L10n.text("backup.confirmPassword"), text: $confirmation).textContentType(.newPassword)
                                .accessibilityIdentifier("backupPasswordConfirmation")
                        }
                        let mismatch = !confirmation.isEmpty && !passwordsMatch
                        Label(L10n.text(mismatch ? "backup.passwordMismatch" : "backup.passwordRequirement"), systemImage: "info.circle")
                            .aegisFont(size: 11).foregroundStyle(mismatch ? Color.orange : AegisTheme.secondary)
                        // The payload carries the raw vault key (§5), so this password guards the whole vault identity.
                        Label(L10n.text("backup.passwordVaultKeyWarning"), systemImage: "exclamationmark.triangle")
                            .aegisFont(size: 12).lineSpacing(4).foregroundStyle(Color.orange)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("backupPasswordVaultKeyWarning")
                        Toggle(isOn: $passwordOnly) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.text("backup.passwordOnly")).aegisFont(size: 13, weight: .medium).foregroundStyle(AegisTheme.text)
                                Text(L10n.text("backup.passwordOnlyDetail")).aegisFont(size: 11).lineSpacing(3)
                                    .foregroundStyle(AegisTheme.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }.toggleStyle(.switch).tint(AegisTheme.teal).accessibilityIdentifier("backupPasswordOnly")
                    }
                    if needsMasterPassword {
                        Text(L10n.text("backup.masterFallback")).aegisFont(size: 12).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
                        AegisInput(title: L10n.text("welcome.master"), icon: "lock") {
                            SecureField(L10n.text("welcome.master"), text: $masterPassword).textContentType(.password)
                                .accessibilityIdentifier("exportMasterPassword")
                        }
                    }
                    Button(action: export) {
                        HStack {
                            if busy {
                                ProgressView().controlSize(.small).tint(AegisTheme.disabledText)
                            }
                            Text(L10n.text(busy ? "backup.exporting" : "backup.exportAction"))
                        }
                    }.buttonStyle(PrimaryButtonStyle()).disabled(!canExport).accessibilityIdentifier("exportBackupButton")
                }.padding(24).disabled(busy)
            }
        }.background(AegisTheme.background).aegisSheetSize(width: 540, height: 660).vaultErrorPresenter()
            .interactiveDismissDisabled(busy).privacySensitive()
            .fileExporter(isPresented: $showExporter, document: document, contentType: .aegisVaultBackup,
                          defaultFilename: "Aegis-\(Date.now.formatted(.iso8601.year().month().day()))")
            { result in
                document = nil
                switch result {
                case .success: dismiss()
                case let .failure(error as CocoaError) where error.code == .userCancelled: break
                case let .failure(error): session.error = error.localizedDescription
                }
            }
    }

    private func export() {
        guard canExport else { return }
        working = true
        Task {
            defer { working = false }
            if needsMasterPassword {
                let submitted = masterPassword; masterPassword = ""
                guard await session.authorizeExport(masterPassword: submitted) else { return }
            } else {
                switch await session.authorizeExport() {
                case .authorized: break
                case .cancelled: return
                case .needsMasterPassword: needsMasterPassword = true; return
                }
            }
            do {
                let data = try await session.exportBackup(backupPassword: usesBackupPassword ? password : nil,
                                                          includeVaultSlot: !usesBackupPassword || !passwordOnly)
                password = ""; confirmation = ""
                document = EncryptedBackupDocument(data: data)
                showExporter = true
            } catch { session.error = error.localizedDescription }
        }
    }

    private func modeOption(selected: Bool, title: String, detail: String, symbol: String, identifier: String,
                            action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(AegisTheme.teal)
                    .frame(width: 32, height: 32).background(AegisTheme.inset, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text(title)).aegisFont(size: 13, weight: .medium).foregroundStyle(AegisTheme.text)
                    Text(L10n.text(detail)).aegisFont(size: 11).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AegisTheme.teal : AegisTheme.secondary)
            }.padding(18).aegisSurface(radius: 14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? AegisTheme.teal.opacity(0.6) : Color.clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(busy).accessibilityIdentifier(identifier)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
