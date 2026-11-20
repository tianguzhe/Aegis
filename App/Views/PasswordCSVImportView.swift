import AegisCore
import SwiftUI
import UniformTypeIdentifiers

struct PasswordCSVImportView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPicker = false
    @State private var isReading = false
    @State private var isSaving = false
    @State private var preview: VaultSession.PasswordCSVPreview?
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text("csv.title"), symbol: "tablecells", close: { dismiss() }, closeDisabled: isSaving)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.text("csv.plaintextHint")).aegisFont(size: 13).foregroundStyle(AegisTheme.secondary)
                    Button {
                        showPicker = true
                    } label: {
                        Label(L10n.text("csv.choose"), systemImage: "doc.badge.plus")
                    }.buttonStyle(AegisButtonStyle(fullWidth: true)).disabled(isReading || isSaving)
                        .accessibilityIdentifier("choosePasswordCSV")
                    if isReading {
                        ProgressView(L10n.text("backup.readingFile")).frame(maxWidth: .infinity)
                    } else if let preview {
                        previewContent(preview.content)
                    }
                }.padding(24)
            }
            if let preview, !preview.content.candidates.isEmpty {
                Button { commit(preview) } label: {
                    HStack {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        }
                        Text(L10n.text("csv.confirm"))
                    }
                }.buttonStyle(PrimaryButtonStyle()).disabled(selectedItemIDs.isEmpty || isSaving || session.isBusy)
                    .padding(24).accessibilityIdentifier("confirmPasswordCSV")
            }
        }.background(AegisTheme.background).aegisSheetSize(width: 520, height: 620)
            .vaultErrorPresenter().privacySensitive().interactiveDismissDisabled(isSaving)
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.commaSeparatedText], allowsMultipleSelection: false) { result in
                switch result {
                case let .success(urls):
                    if let url = urls.first {
                        read { try Self.load(url) }
                    }
                case let .failure(error as CocoaError) where error.code == .userCancelled: clear()
                case .failure:
                    clear()
                    session.error = L10n.text("csv.error.read")
                }
            } onCancellation: {
                clear()
            }
            .onChange(of: session.phase) { _, phase in
                if phase != .unlocked {
                    clear(); dismiss()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    clear(); dismiss()
                }
            }
            .onDisappear { clear() }
        #if DEBUG
            .task {
                if let fixture = PreviewFixtures.passwordCSV() {
                    read { try PasswordCSVImport.parse(Data(fixture.utf8)) }
                }
            }
        #endif
    }

    private func previewContent(_ content: PasswordCSVImport.Preview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(content.source.name, systemImage: "doc.plaintext")
                .aegisFont(size: 15, weight: .semibold).accessibilityIdentifier("passwordCSVSource")
            Text(L10n.format("csv.summary", Int64(content.candidates.count), Int64(content.issues.count)))
                .aegisFont(size: 13).foregroundStyle(AegisTheme.secondary)
            if content.hasUnsupportedFields {
                Label(L10n.text("csv.unsupportedFields"), systemImage: "info.circle")
                    .aegisFont(size: 12).foregroundStyle(AegisTheme.secondary)
            }
            if !content.issues.isEmpty {
                DisclosureGroup(L10n.text("csv.skipped")) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(content.issues, id: \.line) { issue in
                            Text(L10n.format("csv.issue", Int64(issue.line), issue.reason.message))
                                .aegisFont(size: 12).foregroundStyle(AegisTheme.secondary)
                        }
                    }.padding(.top, 8)
                }
            }
            if content.candidates.isEmpty {
                Text(L10n.text("csv.empty")).aegisFont(size: 13).foregroundStyle(AegisTheme.secondary)
            } else {
                HStack(spacing: 12) {
                    Text(L10n.format("backup.selection.count", Int64(selectedItemIDs.count), Int64(content.candidates.count)))
                    Spacer(minLength: 0)
                    Button(L10n.text("backup.selection.selectAll")) { selectedItemIDs = Set(content.candidates.map(\.id)) }
                    Button(L10n.text("backup.selection.clear")) { selectedItemIDs = [] }
                        .accessibilityIdentifier("clearPasswordCSVItems")
                }.buttonStyle(.plain).aegisFont(size: 12).foregroundStyle(AegisTheme.teal)
                LazyVStack(spacing: 0) {
                    ForEach(content.candidates) { candidate in
                        ImportItemToggle(title: candidate.title,
                                         detail: [candidate.username, candidate.host].filter { !$0.isEmpty }.joined(separator: " · "),
                                         symbol: ItemKind.login.symbol, itemID: candidate.id, selectedItemIDs: $selectedItemIDs)
                        Divider().overlay(AegisTheme.border)
                    }
                }
            }
        }.aegisCard().disabled(isSaving)
    }

    private func read(_ load: @escaping @Sendable () throws -> PasswordCSVImport.Parsed) {
        clear()
        let id = operationID
        isReading = true
        operation = Task {
            defer {
                if operationID == id {
                    isReading = false
                }
            }
            do {
                let loaded = try await session.previewPasswordCSV(load)
                guard operationID == id, !Task.isCancelled else { return }
                preview = loaded
                selectedItemIDs = Set(loaded.content.candidates.map(\.id))
            } catch is CancellationError {
                return
            } catch {
                guard operationID == id, !Task.isCancelled else { return }
                session.error = error.localizedDescription
            }
        }
    }

    private func commit(_ preview: VaultSession.PasswordCSVPreview) {
        let id = operationID
        let selected = selectedItemIDs
        isSaving = true
        operation = Task {
            defer {
                if operationID == id {
                    isSaving = false
                }
            }
            do {
                try await session.commitPasswordCSV(preview, selectedItemIDs: selected)
                guard operationID == id else { return }
                clear()
                dismiss()
            } catch is CancellationError {
                return
            } catch VaultError.vaultChanged, VaultError.differentVault {
                guard operationID == id else { return }
                clear()
                session.error = L10n.text("csv.error.changed")
            } catch {
                guard operationID == id else { return }
                session.error = error.localizedDescription
            }
        }
    }

    private func clear() {
        operationID = UUID()
        operation?.cancel()
        operation = nil
        preview = nil
        selectedItemIDs = []
        isReading = false
        isSaving = false
    }

    private nonisolated static func load(_ url: URL) throws -> PasswordCSVImport.Parsed {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let limit = PasswordCSVImport.maxFileBytes
        var data = Data()
        defer { data.resetBytes(in: 0 ..< data.count) }
        do {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            // A file provider may return short reads. The cap applies to the bytes actually read.
            while data.count <= limit {
                try Task.checkCancellation()
                guard let chunk = try file.read(upToCount: min(64 * 1024, limit + 1 - data.count)), !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Foundation file errors can include the original path.
            throw CSVReadFailure()
        }
        return try PasswordCSVImport.parse(data)
    }

    private struct CSVReadFailure: LocalizedError {
        var errorDescription: String? {
            L10n.text("csv.error.read")
        }
    }
}
