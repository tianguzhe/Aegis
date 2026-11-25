import AegisCore
import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case security, data, about
    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .security: L10n.text("settings.tab.security")
        case .data: L10n.text("settings.tab.data")
        case .about: L10n.text("settings.tab.about")
        }
    }
}

struct SettingsView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    var onOpenItem: ((UUID) -> Void)?
    @State private var tab: SettingsTab = .security
    @State private var showExport = false
    @State private var showImport = false
    @State private var showPasswordCSV = false
    @State private var showLocalTransfer = false
    @State private var showChangePassword = false
    @State private var showHealth = false
    @AppStorage("aegis.appearance") private var appearance: AegisAppearance = .system
    private var versionLabel: String {
        L10n.format("settings.versionFormat", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
    }

    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text("action.settings"), subtitle: L10n.text("settings.subtitle"),
                             symbol: "slider.horizontal.3", close: embedded ? nil : { dismiss() })
            Picker(L10n.text("action.settings"), selection: $tab) {
                ForEach(SettingsTab.allCases) { tab in Text(tab.title).tag(tab) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.vertical, 18)
                .accessibilityIdentifier("settingsTabs")
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch tab {
                    case .security: securitySettings
                    case .data: dataSettings
                    case .about: aboutSettings
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24)
                    .frame(maxWidth: 650).frame(maxWidth: .infinity, alignment: .top)
            }
        }.background(AegisTheme.background).modifier(UtilitySize(embedded: embedded, height: 640)).vaultErrorPresenter()
            .sheet(isPresented: $showImport) { ImportBackupView().environment(session) }
            .sheet(isPresented: $showPasswordCSV) { PasswordCSVImportView().environment(session) }
            .sheet(isPresented: $showExport) { ExportBackupView().environment(session) }
            .sheet(isPresented: $showLocalTransfer) { LocalVaultTransferView(mode: .send).environment(session) }
            .sheet(isPresented: $showChangePassword) { ChangeMasterPasswordView().environment(session) }
            .sheet(isPresented: $showHealth) { PasswordHealthView(onOpen: onOpenItem).environment(session) }
            .onChange(of: tab) { _, _ in session.touch() }
    }

    private var securitySettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            AegisSection(title: L10n.text("settings.security")) {
                HStack(spacing: 14) {
                    SettingsRowText(symbol: "touchid", title: "biometric.title", detail: "biometric.description")
                    Toggle(L10n.text("biometric.title"), isOn: Binding(get: { session.biometricEnabled }, set: { enabled in Task { await session.setBiometrics(enabled) } }))
                        .labelsHidden().toggleStyle(.switch).tint(AegisTheme.accentFill)
                        .disabled(session.isUpdatingBiometrics || session.isBusy)
                        .accessibilityIdentifier("biometricsToggle")
                    if session.isUpdatingBiometrics {
                        ProgressView().controlSize(.small)
                    }
                }.padding(18)
                settingDivider
                HStack(spacing: 14) {
                    #if os(macOS)
                        SettingsRowText(symbol: "lock", title: "settings.lockTitle", detail: "settings.lockDescription.mac")
                    #else
                        SettingsRowText(symbol: "lock", title: "settings.lockTitle", detail: "settings.lockDescription")
                    #endif
                    Picker(L10n.text("settings.lockTitle"), selection: Bindable(session).securitySettings.autoLock) {
                        ForEach(AutoLockTimeout.allCases) { value in Text(value.title).tag(value) }
                    }.labelsHidden().fixedSize().accessibilityIdentifier("autoLockPicker")
                }.padding(18)
                settingDivider
                HStack(spacing: 14) {
                    SettingsRowText(symbol: "doc.on.clipboard", title: "settings.clipboardTitle", detail: "settings.clipboardDescription")
                    Picker(L10n.text("settings.clipboardTitle"), selection: Bindable(session).securitySettings.clipboardClear) {
                        ForEach(ClipboardTimeout.allCases) { value in Text(value.title).tag(value) }
                    }.labelsHidden().fixedSize().accessibilityIdentifier("clipboardPicker")
                }.padding(18)
                settingDivider
                settingsAction("rotation.title", symbol: "key") { showChangePassword = true }
                    .accessibilityIdentifier("changeMasterPasswordButton")
            }
            AegisSection(title: L10n.text("health.title"), subtitle: L10n.text("health.subtitle")) {
                settingsAction("health.open", symbol: "heart.text.square") { showHealth = true }
                    .accessibilityIdentifier("passwordHealthButton")
            }
            AegisSection(title: L10n.text("settings.autofill")) {
                SettingsRowText(symbol: "rectangle.and.pencil.and.ellipsis", title: "settings.autofill", detail: "settings.autofillDescription").padding(18)
            }
        }
    }

    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            AegisSection(title: L10n.text("lan.settings.title"), subtitle: L10n.text("lan.settings.description")) {
                settingsAction("lan.send.title", symbol: "wifi") { showLocalTransfer = true }
                    .accessibilityIdentifier("sendLocalVaultButton")
                settingDivider
                HStack(spacing: 14) {
                    SettingsRowText(symbol: "arrow.triangle.2.circlepath", title: "lan.sync.title", detail: "lan.sync.description")
                    Toggle(L10n.text("lan.sync.title"), isOn: Binding(
                        get: { session.lanSyncEnabled },
                        set: { enabled in session.setLANSyncEnabled(enabled) }
                    ))
                    .labelsHidden().toggleStyle(.switch).tint(AegisTheme.accentFill)
                    .disabled(session.unreadableRevisionCount > 0 && !session.lanSyncEnabled)
                    .accessibilityIdentifier("lanSyncToggle")
                }.padding(18)
                if session.lanSyncEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lanSyncStatus).accessibilityIdentifier("lanSyncStatus")
                        if let last = session.lanSync.lastSuccess {
                            Text(L10n.format("lan.sync.lastSuccess", last.formatted(date: .abbreviated, time: .shortened)))
                        }
                    }.aegisFont(size: 12).foregroundStyle(AegisTheme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .bottom], 18)
                }
            }
            AegisSection(title: L10n.text("settings.backup"), subtitle: L10n.text("settings.backupDescription")) {
                settingsAction("settings.export", symbol: "square.and.arrow.up") { showExport = true }
                settingDivider
                settingsAction("settings.import", symbol: "square.and.arrow.down") { showImport = true }
                settingDivider
                settingsAction("csv.title", symbol: "tablecells") { showPasswordCSV = true }
                    .disabled(session.unreadableRevisionCount > 0)
                    .accessibilityIdentifier("importPasswordCSVButton")
            }
            Label(L10n.format("trash.retention", Int64(TrashPolicy.retentionDays)), systemImage: "trash")
                .aegisFont(size: 12).foregroundStyle(AegisTheme.secondary)
        }
    }

    private var lanSyncStatus: String {
        if session.lanSyncBlockedByDamage {
            return L10n.text("lan.sync.damaged")
        }
        switch session.lanSync.state {
        case .idle, .waiting: return L10n.text("lan.sync.waiting")
        case .syncing: return L10n.text("lan.sync.syncing")
        case .permissionDenied: return L10n.text("lan.sync.permissionDenied")
        case .failed: return L10n.text("lan.sync.failed")
        }
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            AegisSection(title: L10n.text("appearance.title")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.text("appearance.title"), selection: $appearance) {
                        ForEach(AegisAppearance.allCases) { value in Text(value.title).tag(value) }
                    }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("appearancePicker")
                    Text(L10n.text("appearance.hint")).aegisFont(size: 12).foregroundStyle(AegisTheme.secondary)
                }.padding(18)
            }
            HStack(spacing: 16) {
                AegisMark(size: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Aegis").aegisFont(size: 24, weight: .semibold).foregroundStyle(AegisTheme.text)
                    Text(versionLabel).aegisFont(size: 12).foregroundStyle(AegisTheme.secondary)
                }
                Spacer()
            }.frame(maxWidth: .infinity).aegisCard()
            AegisSection(title: L10n.text("ui.personalVault")) {
                SettingsRowText(symbol: "checkmark.shield", title: "ui.protected", detail: "settings.privacySummary").padding(18)
                settingDivider
                HStack {
                    Label(L10n.text("settings.language"), systemImage: "globe").foregroundStyle(AegisTheme.text)
                    Spacer()
                    Text(L10n.text("settings.languageValue")).foregroundStyle(AegisTheme.secondary)
                }.aegisFont(size: 13).padding(18)
            }
        }
    }

    private var settingDivider: some View {
        Rectangle().fill(AegisTheme.border).frame(height: 0.5).padding(.leading, 64)
    }

    private func settingsAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(AegisTheme.teal)
                    .frame(width: 32, height: 32).background(AegisTheme.inset, in: RoundedRectangle(cornerRadius: 8))
                Text(L10n.text(title)).aegisFont(size: 13, weight: .medium).foregroundStyle(AegisTheme.text)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(AegisTheme.secondary)
            }.padding(16).contentShape(Rectangle())
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
