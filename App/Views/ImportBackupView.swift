import AegisCore
import SwiftUI
import UniformTypeIdentifiers

/// Import sheet (§10): one credential, a validated preview, then an explicit confirmation.
struct ImportBackupView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var loadingFile = false
    @State private var selection: BackupContainer?
    @State private var credential = ""
    @State private var preview: VaultSession.BackupImportPreview?
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var fileRequest = UUID()
    #if DEBUG
        @State private var cancelledPreviewPicker = false
    #endif

    private var credentialTitle: String {
        guard let container = selection else { return L10n.text("backup.credential.any") }
        let password = container.header.slots.contains {
            if case .password = $0 {
                true
            } else {
                false
            }
        }
        let vault = container.header.slots.contains {
            if case .vault = $0 {
                true
            } else {
                false
            }
        }
        return L10n.text(password && vault ? "backup.credential.any" : password ? "backup.credential.password" : "backup.credential.vault")
    }

    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text("backup.importTitle"), symbol: "arrow.down.doc", close: { dismiss() }, closeDisabled: session.isBusy || loadingFile)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(L10n.text("backup.description")).aegisFont(size: 13).lineSpacing(5).foregroundStyle(AegisTheme.secondary)
                    Button(action: chooseFile) {
                        VStack(spacing: 13) {
                            Image(systemName: selection == nil ? "doc.badge.plus" : "checkmark.circle.fill").font(.system(size: 30, weight: .light))
                            Text(L10n.text(selection == nil ? "backup.choose" : "backup.selected")).aegisFont(size: 14, weight: .medium)
                        }.foregroundStyle(AegisTheme.teal).frame(maxWidth: .infinity).padding(.vertical, 28)
                            .background(AegisTheme.selected.opacity(0.6), in: RoundedRectangle(cornerRadius: AegisMetrics.panelRadius))
                            .overlay(RoundedRectangle(cornerRadius: AegisMetrics.panelRadius).strokeBorder(AegisTheme.teal.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    }.buttonStyle(.plain).disabled(session.isBusy || loadingFile)
                        .accessibilityIdentifier("chooseBackupFile")
                    if loadingFile {
                        ProgressView(L10n.text("backup.readingFile")).frame(maxWidth: .infinity)
                    } else if let preview {
                        previewCard(preview)
                    } else {
                        credentialStep
                    }
                }.padding(24)
            }
        }.background(AegisTheme.background).aegisSheetSize(width: 520, height: 620).vaultErrorPresenter()
            .interactiveDismissDisabled(session.isBusy || loadingFile).privacySensitive()
            .task {
                #if DEBUG
                    let request = fileRequest
                    let generation = session.backupImportGeneration
                    if let fixture = await PreviewFixtures.importSelectionPreview(in: session),
                       request == fileRequest, generation == session.backupImportGeneration
                    {
                        preview = fixture; selectedItemIDs = fixture.selection.itemIDs
                    }
                #endif
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.aegisVaultBackup], onCompletion: selectFile)
    }

    private func chooseFile() {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-onboarding"),
               ProcessInfo.processInfo.arguments.contains("--preview-failed-backup-replacement")
            {
                if cancelledPreviewPicker {
                    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    selectFile(.success(missing))
                } else {
                    cancelledPreviewPicker = true
                    selectFile(.failure(CocoaError(.userCancelled)))
                }
                return
            }
        #endif
        showPicker = true
    }

    private func selectFile(_ result: Result<URL, Error>) {
        if case let .failure(error as CocoaError) = result, error.code == .userCancelled {
            return
        }
        // Selecting another file revokes the previous preview before any asynchronous work.
        let request = UUID(), generation = session.backupImportGeneration
        fileRequest = request
        selection = nil; preview = nil; selectedItemIDs = []; credential = ""
        loadingFile = true
        Task {
            defer {
                if request == fileRequest {
                    loadingFile = false
                }
            }
            do {
                let url = try result.get()
                let loaded = try await Task.detached(priority: .userInitiated) { try Self.load(url) }.value
                guard request == fileRequest, generation == session.backupImportGeneration else { return }
                guard !session.backupImportBlockedByLock else { throw VaultSession.BackupFlowError.unlockFirst }
                selection = loaded
            } catch {
                guard request == fileRequest, generation == session.backupImportGeneration else { return }
                session.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var credentialStep: some View {
        AegisInput(title: credentialTitle, icon: "lock") {
            SecureField(credentialTitle, text: $credential).textContentType(.password).accessibilityIdentifier("backupCredential")
        }.disabled(session.isBusy || loadingFile)
        if !session.isBusy, selection == nil || credential.isEmpty {
            Label(L10n.text(selection == nil ? "backup.chooseHint" : "backup.credentialHint"), systemImage: "info.circle")
                .aegisFont(size: 11).foregroundStyle(AegisTheme.secondary)
        }
        Button(action: verify) {
            HStack {
                if session.isBusy {
                    ProgressView().controlSize(.small).tint(AegisTheme.disabledText)
                }
                Text(L10n.text(session.isBusy ? "backup.verifying" : "backup.verifyAction"))
            }
        }.buttonStyle(PrimaryButtonStyle()).disabled(selection == nil || credential.isEmpty || session.isBusy || loadingFile || session.backupImportBlockedByLock)
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
            BackupImportSelectionView(plan: preview.selection, selectedItemIDs: $selectedItemIDs, busy: session.isBusy)
            if preview.requiresEmptyVault || !preview.isCrossVault {
                Text(L10n.text("backup.selection.syncHint")).aegisFont(size: 11).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
            }
            if preview.isCrossVault {
                Label(L10n.text("backup.preview.crossVault"), systemImage: "info.circle")
                    .aegisFont(size: 12).lineSpacing(4).foregroundStyle(AegisTheme.secondary).fixedSize(horizontal: false, vertical: true)
            } else if preview.openedWith == .backupPassword {
                Label(L10n.text("backup.preview.passwordNote"), systemImage: "info.circle")
                    .aegisFont(size: 12).lineSpacing(4).foregroundStyle(AegisTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                let request = fileRequest
                Task {
                    guard request == fileRequest, !loadingFile, let preview = self.preview else { return }
                    if await session.commitBackup(preview, selectedItemIDs: selectedItemIDs) {
                        dismiss()
                    }
                }
            } label: {
                HStack {
                    if session.isBusy {
                        ProgressView().controlSize(.small).tint(AegisTheme.disabledText)
                    }
                    Text(L10n.text(session.isBusy ? "backup.importing" : "backup.confirmRestore"))
                }
            }.buttonStyle(PrimaryButtonStyle()).disabled(session.isBusy || loadingFile || !preview.selection.canImport(selectedItemIDs))
                .accessibilityIdentifier("confirmRestoreButton")
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
        guard let container = selection, !credential.isEmpty, !session.isBusy, !loadingFile,
              !session.backupImportBlockedByLock else { return }
        let request = fileRequest, generation = session.backupImportGeneration
        let submitted = credential; credential = ""
        Task {
            guard request == fileRequest, generation == session.backupImportGeneration else { return }
            let verified = await session.previewBackup(container, credential: submitted)
            guard request == fileRequest, generation == session.backupImportGeneration else { return }
            preview = verified
            selectedItemIDs = verified?.selection.itemIDs ?? []
        }
    }

    /// Reads the picked file once; validation and commit later use these exact bytes, never the path again.
    private nonisolated static func load(_ url: URL) throws -> BackupContainer {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= BackupLimits.maxFileLength else { throw BackupError.limitExceeded }
        let data = try Data(contentsOf: url)
        guard data.count <= BackupLimits.maxFileLength else { throw BackupError.limitExceeded }
        return try BackupContainer.parse(data)
    }
}
