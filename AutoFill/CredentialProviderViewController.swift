import AegisCore
import AuthenticationServices
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

final class CredentialProviderViewController: ASCredentialProviderViewController {
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        presentVault(services: serviceIdentifiers)
    }

    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        presentVault(services: [credentialRequest.credentialIdentity.serviceIdentifier])
    }

    override func prepareInterfaceForExtensionConfiguration() { presentVault(services: []) }

    private func presentVault(services: [ASCredentialServiceIdentifier]) {
        let content = AutoFillView(services: services.map(\.identifier), complete: { [weak self] item in
            self?.extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: item.username, password: item.password), completionHandler: nil)
        }, cancel: { [weak self] in
            self?.extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue))
        })
        #if os(iOS)
        for child in children { child.willMove(toParent: nil); child.view.removeFromSuperview(); child.removeFromParent() }
        let host = UIHostingController(rootView: content)
        addChild(host); view.addSubview(host.view); host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        host.didMove(toParent: self)
        #else
        let host = NSHostingController(rootView: content)
        children.forEach { $0.removeFromParent() }
        addChild(host); view = host.view
        preferredContentSize = NSSize(width: 420, height: 560)
        #endif
    }
}

private struct AutoFillView: View {
    let services: [String]
    let complete: (VaultItem) -> Void
    let cancel: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var password = ""
    @State private var entries: [VaultEntry] = []
    @State private var error: String?
    @State private var busy = false
    @State private var unlocked = false
    @State private var selected: VaultItem?
    @State private var generation = UUID()

    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text("autofill.title"), symbol: "key.horizontal", close: cancel)
            Divider().overlay(AegisTheme.border)
            if unlocked {
                if entries.isEmpty {
                    AegisEmptyState(title: L10n.text("autofill.empty"), message: L10n.text("autofill.emptyDescription"), symbol: "key.horizontal")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(L10n.text("autofill.domainWarning")).font(.system(size: 12)).foregroundStyle(AegisTheme.secondary).lineSpacing(4)
                                ForEach(services, id: \.self) { Text($0).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(AegisTheme.teal) }
                            }.padding(16).background(AegisTheme.selected, in: RoundedRectangle(cornerRadius: 12))
                            ForEach(entries) { entry in
                                Button { selected = entry.item } label: {
                                    HStack(spacing: 12) {
                                        ItemIcon(item: entry.item)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(entry.item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(AegisTheme.text)
                                            Text(entry.item.username).font(.system(size: 12)).foregroundStyle(AegisTheme.secondary)
                                            Text(entry.item.website).font(.system(size: 11)).foregroundStyle(AegisTheme.secondary).lineLimit(1)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(AegisTheme.secondary)
                                    }.padding(16).aegisSurface()
                                }.buttonStyle(.plain)
                            }
                        }.padding(20)
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        AegisMark(size: 64).padding(.top, 12)
                        VStack(alignment: .leading, spacing: 9) {
                            Text(L10n.text("unlock.title")).font(.system(size: 26, weight: .semibold)).foregroundStyle(AegisTheme.text)
                            Text(L10n.text("unlock.description")).font(.system(size: 13)).foregroundStyle(AegisTheme.secondary)
                        }
                        AegisInput(title: L10n.text("welcome.master"), icon: "lock") {
                            SecureField(L10n.text("welcome.master"), text: $password).textContentType(.password)
                        }
                        Button { unlock() } label: {
                            HStack { if busy { ProgressView().controlSize(.small).tint(.white) }; Text(L10n.text("action.unlock")) }
                        }.buttonStyle(PrimaryButtonStyle()).disabled(password.isEmpty || busy)
                    }.padding(28)
                }
            }
        }.background(AegisTheme.background).tint(AegisTheme.teal)
        .alert(L10n.text("app.error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.text("action.done")) { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog(L10n.text("autofill.confirm"), isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            Button(L10n.text("autofill.confirm")) { if let selected { complete(selected) }; clear() }
            Button(L10n.text("action.cancel"), role: .cancel) { selected = nil }
        } message: {
            Text([selected?.title, selected?.username, selected?.website].compactMap { $0 }.joined(separator: "\n"))
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { clear() } }
        .onDisappear { clear() }.privacySensitive()
    }

    private func clear() { generation = UUID(); entries = []; password = ""; unlocked = false; selected = nil }
    private func unlock() {
        let submitted = password, token = generation
        password = ""; busy = true
        Task {
            let crypto = VaultCrypto()
            defer { busy = false }
            do {
                guard let group = Bundle.main.object(forInfoDictionaryKey: "AegisAppGroup") as? String, !group.isEmpty,
                      let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
                      let data = try? Data(contentsOf: directory.appendingPathComponent("autofill.aegis")), data.count <= 32 * 1024 * 1024 else {
                    throw NSError(domain: "Aegis", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("autofill.unavailable")])
                }
                let backup = try JSONDecoder().decode(VaultBackup.self, from: data)
                try backup.validate()
                try await crypto.unlock(password: submitted, header: backup.header)
                let loaded = try await crypto.entries(from: backup.revisions).filter { $0.item.kind == .login && $0.item.deletedAt == nil }
                await crypto.lock()
                guard token == generation else { return }
                entries = loaded.sorted { lhs, rhs in
                    let left = matches(lhs.item.website), right = matches(rhs.item.website)
                    return left == right ? lhs.item.title < rhs.item.title : left
                }
                unlocked = true
            } catch { await crypto.lock(); self.error = error.localizedDescription }
        }
    }
    private func matches(_ website: String) -> Bool {
        func host(_ value: String) -> String? {
            URL(string: value.contains("://") ? value : "https://" + value)?.host?.lowercased()
        }
        guard let itemHost = host(website) else { return false }
        return services.contains { host($0) == itemHost }
    }
}
