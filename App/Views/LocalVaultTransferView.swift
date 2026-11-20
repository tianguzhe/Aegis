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
    @State private var passwordRequest: (id: UUID, continuation: CheckedContinuation<String, Error>)?
    @State private var selectedPeer: String?
    @State private var masterPassword = ""
    @State private var preparing = false
    @State private var preview: VaultSession.BackupImportPreview?
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()

    private var busy: Bool {
        preparing || session.isBusy || transfer.state == .transferring
    }

    private var peer: LocalVaultTransfer.Peer? {
        transfer.peers.first { $0.id == selectedPeer }
    }

    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text(mode == .send ? "lan.send.title" : "lan.receive.title"),
                             symbol: "wifi", close: { dismiss() }, closeDisabled: session.isBusy && preview != nil)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(L10n.text(descriptionKey))
                        .aegisFont(size: 13).lineSpacing(5).foregroundStyle(AegisTheme.secondary)
                    if let comparison = transfer.comparisonID {
                        comparisonView(comparison)
                    } else if passwordRequest != nil {
                        pairingPassword
                    } else if transfer.state == .connecting || transfer.state == .transferring {
                        ProgressView(L10n.text(transfer.state == .connecting ? "lan.pair.connecting" : "lan.transferring"))
                    } else if mode == .send {
                        sending
                    } else {
                        receiving
                    }
                    if let error = transfer.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .aegisFont(size: 12).foregroundStyle(AegisTheme.danger).fixedSize(horizontal: false, vertical: true)
                    }
                    if transfer.state == .failed {
                        Button(L10n.text("lan.retry")) {
                            selectedPeer = nil
                            if mode == .receive {
                                transfer.search()
                            } else {
                                transfer.stop()
                            }
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
            .onChange(of: transfer.state) {
                _, state in if state == .received {
                    validateReceived()
                }
            }
            .onChange(of: session.phase) { _, phase in
                if (mode == .send && phase != .unlocked) || (mode == .receive && phase != .setup) {
                    cancel(); dismiss()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    cancel(); dismiss()
                }
            }
            .onDisappear { cancel() }
    }

    @ViewBuilder private var sending: some View {
        switch transfer.state {
        case .starting, .offering:
            VStack(alignment: .leading, spacing: 16) {
                Label(transfer.offerName, systemImage: "laptopcomputer.and.iphone")
                    .aegisFont(size: 15, weight: .semibold).foregroundStyle(AegisTheme.text)
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("lan.send.waiting")).aegisFont(size: 12)
                }.foregroundStyle(AegisTheme.secondary)
            }.aegisCard()
            Button(L10n.text("lan.stop")) { cancel() }.buttonStyle(AegisButtonStyle(fullWidth: true))
        case .sent:
            Label(L10n.text("lan.send.completed"), systemImage: "checkmark.circle.fill")
                .aegisFont(size: 14).foregroundStyle(AegisTheme.teal)
            Button(L10n.text("action.done")) { dismiss() }.buttonStyle(PrimaryButtonStyle())
        case .failed: EmptyView()
        default:
            Button(action: beginOffering) { Text(L10n.text("lan.send.start")) }
                .buttonStyle(PrimaryButtonStyle()).disabled(busy)
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
            }.aegisCard()
            BackupImportSelectionView(plan: preview.selection, selectedItemIDs: $selectedItemIDs, busy: busy)
            Text(L10n.text("backup.selection.syncHint")).aegisFont(size: 11).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
            Button {
                let token = operationID
                operation = Task {
                    if await session.commitBackup(preview, selectedItemIDs: selectedItemIDs), token == operationID {
                        dismiss()
                    }
                }
            } label: {
                HStack {
                    if session.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Text(L10n.text("lan.receive.confirm"))
                }
            }.buttonStyle(PrimaryButtonStyle()).disabled(busy || !preview.selection.canImport(selectedItemIDs))
                .accessibilityIdentifier("confirmLocalImportButton")
        } else if preparing {
            ProgressView(L10n.text("backup.verifying"))
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
            Button {
                guard let peer else { return }
                transfer.receivePairing(from: peer)
            } label: { Text(L10n.text("lan.receive.connect")) }
                .buttonStyle(PrimaryButtonStyle()).disabled(peer == nil || busy)
                .accessibilityIdentifier("receiveLocalVaultButton")
        }
    }

    private var descriptionKey: String {
        mode == .send ? "lan.pair.sendDescription" : "lan.pair.receiveDescription"
    }

    private func comparisonView(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(transfer.comparisonCode)
                .aegisFont(size: 32, weight: .semibold, design: .monospaced)
                .foregroundStyle(AegisTheme.teal)
                .accessibilityIdentifier("localPairingComparison")
            Text(L10n.text(transfer.state == .awaitingPeer ? "lan.pair.waiting" : "lan.pair.compare"))
                .aegisFont(size: 13).foregroundStyle(AegisTheme.secondary)
            if transfer.state == .comparing {
                Button(L10n.text("lan.pair.approve")) { transfer.approvePairing(id) }
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("approveLocalPairing")
                Button(L10n.text("lan.pair.reject")) { transfer.rejectPairing(id) }
                    .buttonStyle(AegisButtonStyle(fullWidth: true))
            } else {
                Button(L10n.text("lan.stop")) { cancel(); dismiss() }
                    .buttonStyle(AegisButtonStyle(fullWidth: true))
            }
        }.aegisCard()
    }

    private var pairingPassword: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("backup.masterFallback")).aegisFont(size: 12).foregroundStyle(AegisTheme.secondary)
            AegisInput(title: L10n.text("welcome.master"), icon: "lock") {
                SecureField(L10n.text("welcome.master"), text: $masterPassword).textContentType(.password)
                    .accessibilityIdentifier("localExportMasterPassword")
            }
            Button(L10n.text("lan.pair.authorize")) {
                guard let request = passwordRequest else { return }
                let submitted = masterPassword
                masterPassword = ""; passwordRequest = nil
                request.continuation.resume(returning: submitted)
            }.buttonStyle(PrimaryButtonStyle()).disabled(masterPassword.isEmpty)
        }
    }

    private func exportPairedSnapshot(credential: String, token: UUID) async throws -> Data {
        try Task.checkCancellation()
        guard token == operationID, session.phase == .unlocked else { throw CancellationError() }
        switch await session.authorizeExport() {
        case .authorized: break
        case .cancelled: throw CancellationError()
        case .needsMasterPassword:
            let id = UUID()
            let password = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { pending in
                    passwordRequest = (id, pending)
                }
            } onCancel: {
                Task { @MainActor in
                    guard let request = passwordRequest, request.id == id else { return }
                    passwordRequest = nil; masterPassword = ""
                    request.continuation.resume(throwing: CancellationError())
                }
            }
            try Task.checkCancellation()
            guard await session.authorizeExport(masterPassword: password) else { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard token == operationID, session.phase == .unlocked else { throw CancellationError() }
        return try await session.exportBackup(backupPassword: credential, includeVaultSlot: true)
    }

    private func beginOffering() {
        guard !busy, session.phase == .unlocked else { return }
        let token = operationID
        do {
            try transfer.offerPairing { credential in
                try await exportPairedSnapshot(credential: credential, token: token)
            }
            session.touch()
        } catch { session.error = error.localizedDescription }
    }

    private func validateReceived() {
        guard !preparing, let (data, credential) = transfer.takeReceivedSnapshot() else { return }
        let token = operationID
        preparing = true
        operation = Task {
            defer {
                if token == operationID {
                    preparing = false
                }
            }
            do {
                let container = try BackupContainer.parse(data)
                let result = await session.previewBackup(container, credential: credential, requireNewVault: true)
                guard token == operationID, !Task.isCancelled else { return }
                preview = result
                selectedItemIDs = result?.selection.itemIDs ?? []
                if result == nil {
                    transfer.search()
                }
            } catch {
                if token == operationID {
                    session.error = error.localizedDescription; transfer.search()
                }
            }
        }
    }

    private func cancel() {
        operationID = UUID(); operation?.cancel(); operation = nil
        if let request = passwordRequest {
            passwordRequest = nil
            request.continuation.resume(throwing: CancellationError())
        }
        transfer.stop(); selectedPeer = nil; masterPassword = ""; preview = nil; selectedItemIDs = []; preparing = false
    }
}
