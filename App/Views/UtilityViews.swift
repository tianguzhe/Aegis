import AegisCore
import AegisSync
import SwiftUI
import UniformTypeIdentifiers

struct GeneratorView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    @State private var password = ""
    @State private var copied = false
    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text("nav.generator"), subtitle: L10n.text("ui.generatorSubtitle"), symbol: "wand.and.stars", close: embedded ? nil : { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            AegisPill(title: L10n.text("ui.randomPassword"), symbol: "sparkles")
                            Spacer()
                            AegisIconButton(symbol: "arrow.clockwise", label: L10n.text("generator.regenerate"), action: regenerate)
                        }
                        Text(styledPassword).aegisFont(size: 27, weight: .medium, design: .monospaced)
                            .tracking(0.6).lineSpacing(8).textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        Button {
                            SecureClipboard.copy(password); copied = true; session.touch()
                        } label: {
                            Label(L10n.text(copied ? "action.copied" : "generator.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        }.buttonStyle(PrimaryButtonStyle()).disabled(password.isEmpty)
                    }.padding(24).aegisSurface(radius: 20)
                    AegisSection(title: L10n.text("ui.generatorRules"), subtitle: L10n.text("ui.generatorShared")) {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(L10n.text("generator.length")).aegisFont(size: 14, weight: .medium).foregroundStyle(AegisTheme.text)
                                    Text(L10n.text("ui.lengthRange")).aegisFont(size: 11).foregroundStyle(AegisTheme.secondary)
                                }
                                Spacer()
                                HStack(spacing: 7) {
                                    AegisIconButton(symbol: "minus", label: L10n.text("ui.lengthDecrease")) { session.passwordOptions.length -= 1 }.disabled(session.passwordOptions.length <= 12).accessibilityIdentifier("decreasePasswordLength")
                                    Text(session.passwordOptions.length, format: .number).aegisFont(size: 28, weight: .medium, design: .rounded).monospacedDigit().foregroundStyle(AegisTheme.teal).frame(minWidth: 40)
                                    AegisIconButton(symbol: "plus", label: L10n.text("ui.lengthIncrease")) { session.passwordOptions.length += 1 }.disabled(session.passwordOptions.length >= 64).accessibilityIdentifier("increasePasswordLength")
                                }
                            }
                            Slider(value: Binding(get: { Double(session.passwordOptions.length) }, set: { session.passwordOptions.length = Int($0) }), in: 12...64, step: 1)
                                .tint(AegisTheme.teal).accessibilityLabel(L10n.text("generator.length"))
                        }.padding(20)
                        settingDivider
                        generatorToggle("generator.uppercase", sample: "A–Z", value: $session.passwordOptions.uppercase)
                        settingDivider
                        generatorToggle("generator.digits", sample: "0–9", value: $session.passwordOptions.digits)
                        settingDivider
                        generatorToggle("generator.symbols", sample: "# & %", value: $session.passwordOptions.symbols)
                    }
                    Label(L10n.text("generator.footer"), systemImage: "clock.arrow.circlepath")
                        .aegisFont(size: 11).foregroundStyle(AegisTheme.secondary).frame(maxWidth: .infinity)
                }.padding(.horizontal, 24).padding(.bottom, 26).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
        }.background(AegisTheme.background).modifier(UtilitySize(embedded: embedded, height: 740)).vaultErrorPresenter()
            .onAppear(perform: regenerate).onChange(of: session.passwordOptions) { _, _ in regenerate() }
            .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); copied = false } }.privacySensitive()
    }
    private var styledPassword: AttributedString {
        password.reduce(into: AttributedString()) { result, character in
            var value = AttributedString(String(character))
            value.foregroundColor = character.isNumber ? AegisTheme.gold : character.isLetter ? AegisTheme.text : AegisTheme.teal
            result += value
        }
    }
    private func generatorToggle(_ key: String, sample: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            HStack {
                Text(L10n.text(key)).aegisFont(size: 13).foregroundStyle(AegisTheme.text)
                Spacer()
                Text(sample).aegisFont(size: 11, design: .monospaced).foregroundStyle(AegisTheme.secondary).padding(.trailing, 12)
            }
        }.toggleStyle(.switch).tint(AegisTheme.teal).padding(.horizontal, 20).padding(.vertical, 16)
    }
    private var settingDivider: some View { Rectangle().fill(AegisTheme.border).frame(height: 1).padding(.horizontal, 20) }
    private func regenerate() {
        do { password = try PasswordGenerator.generate(options: session.passwordOptions); copied = false; session.touch() }
        catch { session.error = error.localizedDescription }
    }
}

private struct UtilitySize: ViewModifier {
    let embedded: Bool
    let height: CGFloat
    func body(content: Content) -> some View {
        if embedded { content.frame(maxWidth: .infinity, maxHeight: .infinity) }
        else { content.aegisSheetSize(width: 580, height: height) }
    }
}

struct EncryptedBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.aegisVaultBackup] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
extension UTType {
    /// ABB v1 binary backups (`.aegis`), the only format new exports produce.
    static let aegisVaultBackup = UTType(exportedAs: "app.aegis.backup", conformingTo: .data)
}

struct SettingsView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    @State private var showExport = false
    @State private var showImport = false
    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text("action.settings"), subtitle: L10n.text("ui.settingsSubtitle"), symbol: "slider.horizontal.3", close: embedded ? nil : { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(spacing: 15) {
                        AegisMark(size: 50)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text("app.vault")).aegisFont(size: 17, weight: .semibold).foregroundStyle(AegisTheme.text)
                            Text(L10n.text("ui.privateItem")).aegisFont(size: 12).foregroundStyle(AegisTheme.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark.shield.fill").font(.system(size: 23)).foregroundStyle(AegisTheme.teal)
                    }.aegisCard()
                    AegisSection(title: L10n.text("settings.security")) {
                        HStack(spacing: 14) {
                            SettingsRowText(symbol: "touchid", title: "biometric.title", detail: "biometric.description")
                            Toggle(L10n.text("biometric.title"), isOn: Binding(get: { session.biometricEnabled }, set: { enabled in Task { await session.setBiometrics(enabled) } }))
                                .labelsHidden().toggleStyle(.switch).tint(AegisTheme.teal)
                        }.padding(18)
                        settingDivider
                        #if os(macOS)
                        SettingsRowText(symbol: "lock", title: "settings.lockTitle", detail: "settings.lockDescription.mac").padding(18)
                        #else
                        SettingsRowText(symbol: "lock", title: "settings.lockTitle", detail: "settings.lockDescription").padding(18)
                        #endif
                        settingDivider
                        SettingsRowText(symbol: "doc.on.clipboard", title: "settings.clipboardTitle", detail: "settings.clipboardDescription").padding(18)
                    }
                    AegisSection(title: L10n.text("sync.title")) {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(spacing: 12) {
                                Image(systemName: "icloud").font(.system(size: 24, weight: .light)).foregroundStyle(AegisTheme.teal)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(session.syncTitle).aegisFont(size: 14, weight: .medium).foregroundStyle(AegisTheme.text)
                                    Text(L10n.text("sync.description")).aegisFont(size: 12).lineSpacing(3).foregroundStyle(AegisTheme.secondary)
                                }
                            }
                            if case .failed(let detail) = session.syncStatus { Text(detail).aegisFont(size: 12).foregroundStyle(.orange) }
                            Button { Task { await session.connectCloud() } } label: { Label(L10n.text("sync.now"), systemImage: "arrow.triangle.2.circlepath") }
                                .buttonStyle(AegisButtonStyle(fullWidth: true))
                        }.padding(20)
                    }
                    AegisSection(title: L10n.text("settings.backup"), subtitle: L10n.text("settings.backupDescription")) {
                        settingsAction("settings.export", symbol: "square.and.arrow.up") { showExport = true }
                        settingDivider
                        settingsAction("settings.import", symbol: "square.and.arrow.down") { showImport = true }
                    }
                    AegisSection(title: L10n.text("settings.autofill")) {
                        SettingsRowText(symbol: "rectangle.and.pencil.and.ellipsis", title: "settings.autofill", detail: "settings.autofillDescription").padding(18)
                    }
                    HStack {
                        Text("Aegis").aegisFont(size: 18, weight: .medium, design: .serif)
                        Spacer()
                        Text(L10n.text("settings.version")).aegisFont(size: 11)
                        Text("·")
                        Text(L10n.text("settings.languageValue")).aegisFont(size: 11)
                    }.foregroundStyle(AegisTheme.secondary).padding(.horizontal, 4).padding(.vertical, 8)
                }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: 650).frame(maxWidth: .infinity)
            }
        }.background(AegisTheme.background).modifier(UtilitySize(embedded: embedded, height: 760)).vaultErrorPresenter()
            .sheet(isPresented: $showImport) { ImportBackupView().environment(session) }
            .sheet(isPresented: $showExport) { ExportBackupView().environment(session) }
    }
    private var settingDivider: some View { Rectangle().fill(AegisTheme.border).frame(height: 1).padding(.leading, 64) }
    private func settingsAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(AegisTheme.teal).frame(width: 32)
                Text(L10n.text(title)).aegisFont(size: 13).foregroundStyle(AegisTheme.text)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(AegisTheme.secondary)
            }.padding(18).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct SettingsRowText: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(AegisTheme.teal)
                .frame(width: 32, height: 32).background(AegisTheme.inset, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text(title)).aegisFont(size: 13, weight: .medium).foregroundStyle(AegisTheme.text)
                Text(L10n.text(detail)).aegisFont(size: 11).lineSpacing(4).foregroundStyle(AegisTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Export sheet (Docs/BACKUP_FORMAT_DESIGN_V1.md §4.2, §9): mode choice, device-owner check, sealing, save.
struct ExportBackupView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var usesBackupPassword = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var passwordOnly = false
    @State private var needsMasterPassword = false
    @State private var masterPassword = ""
    @State private var document: EncryptedBackupDocument?
    @State private var showIncomplete = false
    @State private var showExporter = false

    // Backup passwords are NFC-normalized before sealing, so confirmation compares the same form.
    private var normalizedPassword: String { password.precomposedStringWithCanonicalMapping }
    private var passwordsMatch: Bool {
        normalizedPassword.utf8.elementsEqual(confirmation.precomposedStringWithCanonicalMapping.utf8)
    }
    private var canExport: Bool {
        guard !session.isBusy, !(needsMasterPassword && masterPassword.isEmpty) else { return false }
        return !usesBackupPassword || (normalizedPassword.count >= BackupCryptor.minimumPasswordCharacters && passwordsMatch)
    }

    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text("backup.exportTitle"), symbol: "square.and.arrow.up", close: { dismiss() }, closeDisabled: session.isBusy)
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
                            if session.isBusy { ProgressView().controlSize(.small).tint(AegisTheme.disabledText) }
                            Text(L10n.text(session.isBusy ? "backup.exporting" : "backup.exportAction"))
                        }
                    }.buttonStyle(PrimaryButtonStyle()).disabled(!canExport).accessibilityIdentifier("exportBackupButton")
                }.padding(24)
            }
        }.background(AegisTheme.background).aegisSheetSize(width: 540, height: 660).vaultErrorPresenter()
            .interactiveDismissDisabled(session.isBusy).privacySensitive()
            .alert(L10n.text("backup.incompleteTitle"), isPresented: $showIncomplete) {
                Button(L10n.text("backup.saveAnyway")) { showExporter = true }
                Button(L10n.text("action.cancel"), role: .cancel) { document = nil }
            } message: { Text(L10n.text("backup.incompleteMessage")) }
            .fileExporter(isPresented: $showExporter, document: document, contentType: .aegisVaultBackup,
                          defaultFilename: "Aegis-\(Date.now.formatted(.iso8601.year().month().day()))") { result in
                document = nil
                switch result {
                case .success: dismiss()
                case .failure(let error as CocoaError) where error.code == .userCancelled: break
                case .failure(let error): session.error = error.localizedDescription
                }
            }
    }

    private func export() {
        Task {
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
                let result = try await session.exportBackup(backupPassword: usesBackupPassword ? password : nil,
                                                            includeVaultSlot: !usesBackupPassword || !passwordOnly)
                password = ""; confirmation = ""
                document = EncryptedBackupDocument(data: result.data)
                if result.incompleteHistory { showIncomplete = true } else { showExporter = true }
            } catch { session.error = error.localizedDescription }
        }
    }

    private func modeOption(selected: Bool, title: String, detail: String, symbol: String, identifier: String,
                            action: @escaping () -> Void) -> some View {
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
        }.buttonStyle(.plain).disabled(session.isBusy).accessibilityIdentifier(identifier)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Import sheet (§10): one credential, a validated preview, then an explicit confirmation.
struct ImportBackupView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var selection: BackupContainer?
    @State private var credential = ""
    @State private var preview: VaultSession.BackupImportPreview?

    private var credentialTitle: String {
        guard let container = selection else { return L10n.text("backup.credential.any") }
        let password = container.header.slots.contains { if case .password = $0 { true } else { false } }
        let vault = container.header.slots.contains { if case .vault = $0 { true } else { false } }
        return L10n.text(password && vault ? "backup.credential.any" : password ? "backup.credential.password" : "backup.credential.vault")
    }

    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text("backup.importTitle"), symbol: "arrow.down.doc", close: { dismiss() }, closeDisabled: session.isBusy)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(L10n.text("backup.description")).aegisFont(size: 13).lineSpacing(5).foregroundStyle(AegisTheme.secondary)
                    Button { showPicker = true } label: {
                        VStack(spacing: 13) {
                            Image(systemName: selection == nil ? "doc.badge.plus" : "checkmark.circle.fill").font(.system(size: 30, weight: .light))
                            Text(L10n.text(selection == nil ? "backup.choose" : "backup.selected")).aegisFont(size: 14, weight: .medium)
                        }.foregroundStyle(AegisTheme.teal).frame(maxWidth: .infinity).padding(.vertical, 28)
                            .background(AegisTheme.selected.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AegisTheme.teal.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    }.buttonStyle(.plain).disabled(session.isBusy)
                    if let preview { previewCard(preview) } else { credentialStep }
                }.padding(24)
            }
        }.background(AegisTheme.background).aegisSheetSize(width: 520, height: 620).vaultErrorPresenter()
            .interactiveDismissDisabled(session.isBusy).privacySensitive()
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.aegisVaultBackup]) { result in
                selection = nil; preview = nil; credential = ""
                Task {
                    do {
                        let url = try result.get()
                        let loaded = try await Task.detached(priority: .userInitiated) { try Self.load(url) }.value
                        if session.backupImportBlockedByLock { throw VaultSession.BackupFlowError.unlockFirst }
                        selection = loaded
                    } catch { session.error = error.localizedDescription }
                }
            }
    }

    @ViewBuilder private var credentialStep: some View {
        AegisInput(title: credentialTitle, icon: "lock") {
            SecureField(credentialTitle, text: $credential).textContentType(.password).accessibilityIdentifier("backupCredential")
        }.disabled(session.isBusy)
        if !session.isBusy && (selection == nil || credential.isEmpty) {
            Label(L10n.text(selection == nil ? "backup.chooseHint" : "backup.credentialHint"), systemImage: "info.circle")
                .aegisFont(size: 11).foregroundStyle(AegisTheme.secondary)
        }
        Button(action: verify) {
            HStack {
                if session.isBusy { ProgressView().controlSize(.small).tint(AegisTheme.disabledText) }
                Text(L10n.text(session.isBusy ? "backup.verifying" : "backup.verifyAction"))
            }
        }.buttonStyle(PrimaryButtonStyle()).disabled(selection == nil || credential.isEmpty || session.isBusy)
            .accessibilityIdentifier("verifyBackupButton")
    }

    private func previewCard(_ preview: VaultSession.BackupImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("backup.preview.title")).aegisFont(size: 15, weight: .semibold).foregroundStyle(AegisTheme.text)
                previewRow("backup.preview.exportedAt", preview.exportedAt.formatted(date: .abbreviated, time: .shortened))
                previewRow("backup.preview.items", preview.itemCount.formatted())
                previewRow("backup.preview.trashed", preview.trashedCount.formatted())
                previewRow("backup.preview.conflicts", preview.conflictCount.formatted())
                previewRow("backup.preview.revisions", preview.payload.revisions.count.formatted())
                previewRow("backup.preview.new", preview.newRevisionCount.formatted())
            }.aegisCard()
            if preview.payload.incompleteHistory {
                Label(L10n.text("backup.preview.incomplete"), systemImage: "exclamationmark.triangle")
                    .aegisFont(size: 12).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
            }
            if preview.openedWith == .backupPassword {
                Label(L10n.text("backup.preview.passwordNote"), systemImage: "info.circle")
                    .aegisFont(size: 12).lineSpacing(4).foregroundStyle(AegisTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task {
                    if await session.commitBackup(preview) { dismiss() } else { self.preview = nil }
                }
            } label: {
                HStack {
                    if session.isBusy { ProgressView().controlSize(.small).tint(AegisTheme.disabledText) }
                    Text(L10n.text(session.isBusy ? "backup.importing" : "backup.confirmRestore"))
                }
            }.buttonStyle(PrimaryButtonStyle()).disabled(session.isBusy).accessibilityIdentifier("confirmRestoreButton")
        }
    }

    private func previewRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(L10n.text(key)).aegisFont(size: 13).foregroundStyle(AegisTheme.secondary)
            Spacer()
            Text(value).aegisFont(size: 13, weight: .medium).monospacedDigit().foregroundStyle(AegisTheme.text)
        }
    }

    private func verify() {
        guard let container = selection, !credential.isEmpty, !session.isBusy else { return }
        let submitted = credential; credential = ""
        Task { preview = await session.previewBackup(container, credential: submitted) }
    }

    /// Reads the picked file once; validation and commit later use these exact bytes, never the path again.
    nonisolated private static func load(_ url: URL) throws -> BackupContainer {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= BackupLimits.maxFileLength else { throw BackupError.limitExceeded }
        let data = try Data(contentsOf: url)
        guard data.count <= BackupLimits.maxFileLength else { throw BackupError.limitExceeded }
        guard data.starts(with: BackupHeader.magic) else { throw BackupError.notABackup }
        return try BackupContainer.parse(data)
    }
}
