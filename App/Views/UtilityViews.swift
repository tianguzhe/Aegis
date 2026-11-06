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
    static var readableContentTypes: [UTType] { [.aegisBackup, .data, .json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
extension UTType { static let aegisBackup = UTType(exportedAs: "app.aegis.encrypted-backup", conformingTo: .data) }

struct SettingsView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    @State private var showExport = false
    @State private var document: EncryptedBackupDocument?
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
                        settingsAction("settings.export", symbol: "square.and.arrow.up") {
                            Task {
                                do { document = EncryptedBackupDocument(data: try await session.exportBackup()); showExport = true }
                                catch { session.error = error.localizedDescription }
                            }
                        }
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
            .fileExporter(isPresented: $showExport, document: document, contentType: .aegisBackup, defaultFilename: "Aegis-\(Date.now.formatted(.iso8601.year().month().day()))") { result in
                if case .failure(let error) = result { session.error = error.localizedDescription }; document = nil
            }
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

struct ImportBackupView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var data: Data?
    @State private var password = ""
    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text("backup.importTitle"), symbol: "arrow.down.doc", close: { dismiss() }, closeDisabled: session.isBusy)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(L10n.text("backup.description")).aegisFont(size: 13).lineSpacing(5).foregroundStyle(AegisTheme.secondary)
                    Button { showPicker = true } label: {
                        VStack(spacing: 13) {
                            Image(systemName: data == nil ? "doc.badge.plus" : "checkmark.circle.fill").font(.system(size: 30, weight: .light))
                            Text(L10n.text(data == nil ? "backup.choose" : "backup.selected")).aegisFont(size: 14, weight: .medium)
                        }.foregroundStyle(AegisTheme.teal).frame(maxWidth: .infinity).padding(.vertical, 28)
                            .background(AegisTheme.selected.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AegisTheme.teal.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    }.buttonStyle(.plain).disabled(session.isBusy)
                    AegisInput(title: L10n.text("backup.password"), icon: "lock") {
                        SecureField(L10n.text("welcome.master"), text: $password).textContentType(.password)
                    }.disabled(session.isBusy)
                    if !session.isBusy && (data == nil || password.isEmpty) {
                        Label(L10n.text(data == nil ? "backup.chooseHint" : "backup.passwordHint"), systemImage: "info.circle")
                            .aegisFont(size: 11).foregroundStyle(AegisTheme.secondary)
                    }
                    Button {
                        guard let data, !session.isBusy, !password.isEmpty else { return }
                        let submitted = password; password = ""
                        Task { if await session.importBackup(data: data, password: submitted) { dismiss() } }
                    } label: {
                        HStack { if session.isBusy { ProgressView().controlSize(.small).tint(AegisTheme.disabledText) }; Text(L10n.text(session.isBusy ? "backup.importing" : "backup.importAction")) }
                    }.buttonStyle(PrimaryButtonStyle()).disabled(data == nil || password.isEmpty || session.isBusy)
                }.padding(24)
            }
        }.background(AegisTheme.background).aegisSheetSize(width: 520, height: 520).vaultErrorPresenter()
            .interactiveDismissDisabled(session.isBusy)
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.aegisBackup, .data, .json]) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 32 * 1024 * 1024 else { throw VaultError.oversizedRecord }
                    data = try Data(contentsOf: url)
                } catch { session.error = error.localizedDescription }
            }
    }
}
