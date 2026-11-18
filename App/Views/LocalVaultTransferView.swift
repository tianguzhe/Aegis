import AegisCore
import AegisSync
import SwiftUI

/// Onboarding joins the source vault verbatim; sending is an explicit, authenticated export.
struct LocalVaultTransferView: View {
    enum Mode { case send, receive }
    let mode: Mode
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var transfer = LocalVaultTransfer()
    @State private var selectedPeer: String?
    @State private var code = ""
    @State private var masterPassword = ""
    @State private var needsMasterPassword = false
    @State private var preparing = false
    @State private var preview: VaultSession.BackupImportPreview?
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()

    private var busy: Bool { preparing || session.isBusy || transfer.state == .transferring }
    private var peer: LocalVaultTransfer.Peer? { transfer.peers.first { $0.id == selectedPeer } }
    private var validCode: Bool { (try? LocalTransferProtocol.normalizeCode(code)) != nil }

    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text(mode == .send ? "lan.send.title" : "lan.receive.title"),
                             symbol: "wifi", close: { dismiss() }, closeDisabled: session.isBusy && preview != nil)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(L10n.text(mode == .send ? "lan.send.description" : "lan.receive.description"))
                        .aegisFont(size: 13).lineSpacing(5).foregroundStyle(AegisTheme.secondary)
                    if mode == .send { sending } else { receiving }
                    if let error = transfer.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .aegisFont(size: 12).foregroundStyle(AegisTheme.danger).fixedSize(horizontal: false, vertical: true)
                    }
                    if transfer.state == .failed {
                        Button(L10n.text("lan.retry")) {
                            code = ""; selectedPeer = nil
                            if mode == .receive { transfer.search() } else { transfer.stop() }
                        }.buttonStyle(AegisButtonStyle(fullWidth: true))
                    }
                    Label(L10n.text("lan.networkHint"), systemImage: "info.circle")
                        .aegisFont(size: 11).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(24)
            }
        }.background(AegisTheme.background).aegisSheetSize(width: 550, height: 650)
            .privacySensitive().vaultErrorPresenter().interactiveDismissDisabled(session.isBusy && preview != nil)
            .task {
                guard mode == .receive else { return }
                #if DEBUG
                if let fixture = await PreviewFixtures.importSelectionPreview(in: session) {
                    preview = fixture; selectedItemIDs = fixture.selection.itemIDs
                    return
                }
                #endif
                transfer.search()
            }
            .onChange(of: transfer.state) { _, state in if state == .received { validateReceived() } }
            .onChange(of: session.phase) { _, phase in
                if (mode == .send && phase != .unlocked) || (mode == .receive && phase != .setup) {
                    cancel(); dismiss()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { cancel(); dismiss() }
            }
            .onDisappear { cancel() }
    }

    @ViewBuilder private var sending: some View {
        switch transfer.state {
        case .starting, .offering, .transferring:
            VStack(alignment: .leading, spacing: 16) {
                Label(transfer.offerName, systemImage: "laptopcomputer.and.iphone")
                    .aegisFont(size: 15, weight: .semibold).foregroundStyle(AegisTheme.text)
                Text(L10n.text("lan.code.title")).aegisFont(size: 12).foregroundStyle(AegisTheme.secondary)
                Text(LocalTransferProtocol.displayCode(transfer.pairingCode))
                    .aegisFont(size: 19, weight: .semibold, design: .monospaced).lineSpacing(5)
                    .foregroundStyle(AegisTheme.teal).textSelection(.enabled).accessibilityIdentifier("localPairingCode")
                Text(L10n.text("lan.send.codeHint")).aegisFont(size: 12).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text(transfer.state == .transferring ? "lan.transferring" : "lan.send.waiting")).aegisFont(size: 12)
                }.foregroundStyle(AegisTheme.secondary)
            }.aegisCard()
            Button(L10n.text("lan.stop")) { cancel() }.buttonStyle(AegisButtonStyle(fullWidth: true))
        case .sent:
            Label(L10n.text("lan.send.completed"), systemImage: "checkmark.circle.fill")
                .aegisFont(size: 14).foregroundStyle(AegisTheme.teal)
            Button(L10n.text("action.done")) { dismiss() }.buttonStyle(PrimaryButtonStyle())
        case .failed: EmptyView()
        default:
            if needsMasterPassword {
                Text(L10n.text("backup.masterFallback")).aegisFont(size: 12).foregroundStyle(AegisTheme.secondary)
                AegisInput(title: L10n.text("welcome.master"), icon: "lock") {
                    SecureField(L10n.text("welcome.master"), text: $masterPassword).textContentType(.password)
                        .accessibilityIdentifier("localExportMasterPassword")
                }.disabled(busy)
            }
            Button(action: beginOffering) {
                HStack {
                    if preparing { ProgressView().controlSize(.small) }
                    Text(L10n.text(preparing ? "lan.preparing" : "lan.send.start"))
                }
            }.buttonStyle(PrimaryButtonStyle()).disabled(busy || (needsMasterPassword && masterPassword.isEmpty))
                .accessibilityIdentifier("startLocalTransferButton")
        }
    }

    @ViewBuilder private var receiving: some View {
        if let preview {
            VStack(alignment: .leading, spacing: 14) {
                Label(L10n.text("lan.receive.verified"), systemImage: "checkmark.shield")
                    .aegisFont(size: 16, weight: .semibold).foregroundStyle(AegisTheme.teal)
                Text(L10n.format("lan.receive.items", Int64(preview.itemCount), Int64(preview.trashedCount)))
                    .aegisFont(size: 13).foregroundStyle(AegisTheme.text)
                Text(L10n.text("lan.receive.identityHint")).aegisFont(size: 12).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
                if preview.payload.incompleteHistory {
                    Label(L10n.text("backup.preview.incomplete"), systemImage: "exclamationmark.triangle")
                        .aegisFont(size: 12).foregroundStyle(AegisTheme.gold)
                }
            }.aegisCard()
            BackupImportSelectionView(plan: preview.selection, selectedItemIDs: $selectedItemIDs, busy: busy)
            Text(L10n.text("backup.selection.syncHint")).aegisFont(size: 11).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
            Button {
                let token = operationID
                operation = Task {
                    if await session.commitBackup(preview, selectedItemIDs: selectedItemIDs), token == operationID { dismiss() }
                }
            } label: {
                HStack {
                    if session.isBusy { ProgressView().controlSize(.small) }
                    Text(L10n.text("lan.receive.confirm"))
                }
            }.buttonStyle(PrimaryButtonStyle()).disabled(busy || !preview.selection.canImport(selectedItemIDs))
                .accessibilityIdentifier("confirmLocalImportButton")
        } else if preparing || transfer.state == .transferring {
            ProgressView(L10n.text(preparing ? "backup.verifying" : "lan.transferring"))
                .frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if transfer.state != .failed {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("lan.devices")).aegisFont(size: 14, weight: .semibold).foregroundStyle(AegisTheme.text)
                if transfer.peers.isEmpty {
                    ProgressView(L10n.text("lan.searching")).controlSize(.small)
                    Text(L10n.text("lan.noDevicesHint")).aegisFont(size: 12).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
                }
                ForEach(transfer.peers) { peer in
                    Button { selectedPeer = peer.id } label: {
                        HStack {
                            Label(peer.name, systemImage: "laptopcomputer.and.iphone")
                            Spacer()
                            Image(systemName: selectedPeer == peer.id ? "checkmark.circle.fill" : "circle")
                        }.aegisFont(size: 13).foregroundStyle(AegisTheme.teal).padding(.vertical, 10)
                    }.buttonStyle(.plain)
                }
            }.aegisCard().accessibilityIdentifier("localDevices")
            AegisInput(title: L10n.text("lan.code.title"), icon: "key") {
                TextField(L10n.text("lan.code.placeholder"), text: $code)
                    .autocorrectionDisabled().aegisFont(size: 14, design: .monospaced)
                    .accessibilityIdentifier("localPairingCodeInput")
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
            }
            Button {
                guard let peer else { return }
                do { try transfer.receive(from: peer, code: code); code = ""; session.touch() }
                catch { session.error = error.localizedDescription }
            } label: { Text(L10n.text("lan.receive.connect")) }
                .buttonStyle(PrimaryButtonStyle()).disabled(peer == nil || !validCode || busy)
                .accessibilityIdentifier("receiveLocalVaultButton")
        }
    }

    private func beginOffering() {
        guard !busy, session.phase == .unlocked else { return }
        preparing = true
        let token = operationID
        operation = Task {
            defer { if token == operationID { preparing = false } }
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
                let code = try LocalTransferProtocol.makeCode()
                let snapshot = try await session.exportBackup(backupPassword: code, includeVaultSlot: true)
                try Task.checkCancellation()
                guard token == operationID, session.phase == .unlocked else { return }
                try transfer.offer(snapshot.data, code: code)
            } catch { if token == operationID { session.error = error.localizedDescription } }
        }
    }

    private func validateReceived() {
        guard let data = transfer.receivedData, !preparing else { return }
        let credential = transfer.pairingCode, token = operationID
        transfer.discardReceivedBytes()
        preparing = true
        operation = Task {
            defer { if token == operationID { preparing = false } }
            do {
                let container = try BackupContainer.parse(data)
                let result = await session.previewBackup(container, credential: credential, requireNewVault: true)
                guard token == operationID, !Task.isCancelled else { return }
                preview = result
                selectedItemIDs = result?.selection.itemIDs ?? []
                if result == nil { transfer.search() }
            } catch { if token == operationID { session.error = error.localizedDescription; transfer.search() } }
        }
    }

    private func cancel() {
        operationID = UUID(); operation?.cancel(); operation = nil
        transfer.stop(); code = ""; masterPassword = ""; preview = nil; selectedItemIDs = []; preparing = false
    }
}
