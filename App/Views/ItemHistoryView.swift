import AegisCore
import SwiftUI

/// Read-only list of authenticated revisions for one item, with an explicit restore action.
struct ItemHistoryView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let itemID: UUID
    let title: String
    @State private var history: [VaultHistoryEntry] = []
    @State private var loading = true
    @State private var pendingRestore: VaultHistoryEntry?
    @State private var restoring = false

    var body: some View {
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text("history.title"), subtitle: title, symbol: "clock.arrow.circlepath",
                             close: { dismiss() }, closeDisabled: restoring)
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if history.isEmpty {
                AegisEmptyState(title: L10n.text("history.empty"), message: L10n.text("history.emptyDescription"), symbol: "clock")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(L10n.text("history.description"), systemImage: "info.circle")
                            .aegisFont(size: 12).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(history.enumerated()), id: \.element.id) { index, version in
                            HistoryRow(version: version, previous: previousVersion(of: version, at: index),
                                       restoreDisabled: restoring || session.unreadableRevisionCount > 0)
                            {
                                pendingRestore = version
                            }
                        }
                    }.padding(24)
                }
            }
        }
        .background(AegisTheme.background).aegisSheetSize(width: 580, height: 640).vaultErrorPresenter()
        .interactiveDismissDisabled(restoring).privacySensitive()
        .task { await load() }
        .onChange(of: session.phase) { _, phase in
            if phase != .unlocked {
                dismiss()
            }
        }
        .alert(L10n.text("history.restoreConfirm"), isPresented: Binding(get: { pendingRestore != nil }, set: {
            if !$0 {
                pendingRestore = nil
            }
        }), presenting: pendingRestore) { version in
            Button(L10n.text("history.restore")) { restore(version) }
            Button(L10n.text("action.cancel"), role: .cancel) {}
        } message: { _ in Text(L10n.text("history.restoreMessage")) }
    }

    /// The parent revision when present, otherwise the next older entry in the list.
    private func previousVersion(of version: VaultHistoryEntry, at index: Int) -> VaultItem? {
        if let parentID = version.revision.parents.first, let parent = history.first(where: { $0.id == parentID }) {
            return parent.item
        }
        return version.revision.parents.isEmpty ? nil : history.indices.contains(index + 1) ? history[index + 1].item : nil
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { history = try await session.history(for: itemID) }
        catch { session.error = error.localizedDescription }
    }

    private func restore(_ version: VaultHistoryEntry) {
        restoring = true
        Task {
            defer { restoring = false }
            if await session.restoreHistory(version) {
                dismiss()
            }
        }
    }
}

private struct HistoryRow: View {
    @Environment(VaultSession.self) private var session
    let version: VaultHistoryEntry
    let previous: VaultItem?
    let restoreDisabled: Bool
    let restore: () -> Void
    @State private var revealed = false

    private var changes: [VaultHistoryChange] {
        VaultHistoryDiff.changes(from: previous, to: version.item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(version.item.modifiedAt, format: .dateTime.year().month().day().hour().minute())
                    .aegisFont(size: 13, weight: .semibold).foregroundStyle(AegisTheme.text)
                if version.isConflictHead {
                    AegisPill(title: L10n.text("list.conflict"), symbol: "exclamationmark.circle", tint: .orange)
                } else if version.isCurrentHead {
                    AegisPill(title: L10n.text("history.current"), symbol: "checkmark.circle")
                }
                Spacer()
                if !version.isCurrentHead || version.isConflictHead {
                    Button(L10n.text("history.restore"), action: restore)
                        .buttonStyle(.bordered).controlSize(.small).disabled(restoreDisabled)
                        .accessibilityIdentifier("restoreHistory-\(version.id.uuidString)")
                }
            }
            if !changes.isEmpty {
                Text(changes.map(\.label).joined(separator: " · "))
                    .aegisFont(size: 11).foregroundStyle(AegisTheme.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                row("field.title", version.item.title)
                if version.item.kind == .login {
                    row("field.username", version.item.username)
                    HStack(spacing: 8) {
                        row("field.password", revealed ? version.item.password : (version.item.password.isEmpty ? "" : "••••••••"))
                        if !version.item.password.isEmpty {
                            AegisIconButton(symbol: revealed ? "eye.slash" : "eye", label: L10n.text(revealed ? "action.hide" : "action.show")) {
                                revealed.toggle(); session.touch()
                            }
                            AegisIconButton(symbol: "doc.on.doc", label: L10n.text("action.copyPassword")) {
                                SecureClipboard.copy(version.item.password); session.touch()
                            }
                        }
                    }
                    if !version.item.website.isEmpty {
                        row("field.website", version.item.website)
                    }
                } else if version.item.kind == .card {
                    row("field.cardholder", version.item.cardholder)
                    HStack(spacing: 8) {
                        row("field.cardNumber", revealed ? version.item.cardNumber : (version.item.cardNumber.isEmpty ? "" : "••••••••"))
                        if !version.item.cardNumber.isEmpty {
                            AegisIconButton(symbol: revealed ? "eye.slash" : "eye", label: L10n.text(revealed ? "action.hide" : "action.show")) {
                                revealed.toggle(); session.touch()
                            }
                            AegisIconButton(symbol: "doc.on.doc", label: L10n.text("action.copyCardNumber")) {
                                SecureClipboard.copy(version.item.cardNumber); session.touch()
                            }
                        }
                    }
                    if !version.item.expiry.isEmpty {
                        row("field.expiry", version.item.expiry)
                    }
                }
                if !version.item.notes.isEmpty {
                    row(version.item.kind == .note ? "field.secureNote" : "field.notes", version.item.notes)
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).aegisSurface()
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.text(key)).aegisFont(size: 11).foregroundStyle(AegisTheme.secondary).frame(width: 64, alignment: .leading)
            Text(value.isEmpty ? "—" : value).aegisFont(size: 12, design: key == "field.password" ? .monospaced : .default)
                .foregroundStyle(AegisTheme.text).lineLimit(2).textSelection(.enabled)
        }
    }
}
