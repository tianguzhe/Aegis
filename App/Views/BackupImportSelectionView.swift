import AegisCore
import SwiftUI

/// Shared by file restore and LAN onboarding; titles and account names only, never secret fields.
struct BackupImportSelectionView: View {
    let plan: BackupImportPlan
    @Binding var selectedItemIDs: Set<UUID>
    var busy = false
    @State private var search = ""
    @State private var filter: Filter = .all

    private enum Filter: String, CaseIterable, Identifiable {
        case all, login, card, note, trash, deleted
        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .all: L10n.text("backup.selection.allTypes")
            case .login: ItemKind.login.title
            case .card: ItemKind.card.title
            case .note: ItemKind.note.title
            case .trash: L10n.text("nav.trash")
            case .deleted: L10n.text("backup.selection.deleted")
            }
        }

        func includes(_ item: BackupImportPlan.Item) -> Bool {
            switch self {
            case .all: true
            case .login: item.kind == .login
            case .card: item.kind == .card
            case .note: item.kind == .note
            case .trash: item.isTrashed
            case .deleted: item.isPermanentlyDeleted
            }
        }
    }

    private var filtered: [BackupImportPlan.Item] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return plan.items.filter { item in
            filter.includes(item) && (query.isEmpty || title(item).localizedStandardContains(query)
                || item.username.localizedStandardContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("backup.selection.title")).aegisFont(size: 15, weight: .semibold).foregroundStyle(AegisTheme.text)
            if plan.items.isEmpty {
                Text(L10n.text("backup.selection.emptyVault")).aegisFont(size: 12).foregroundStyle(AegisTheme.secondary)
            } else {
                HStack(spacing: 14) {
                    Text(L10n.format("backup.selection.count", Int64(selectedItemIDs.count), Int64(plan.items.count)))
                        .aegisFont(size: 12).foregroundStyle(AegisTheme.secondary).accessibilityIdentifier("importSelectionCount")
                    Spacer(minLength: 0)
                    Button(L10n.text("backup.selection.selectAll")) { selectedItemIDs = plan.itemIDs }
                        .foregroundStyle(AegisTheme.teal)
                        .accessibilityIdentifier("selectAllImportItems")
                    Button(L10n.text("backup.selection.clear")) { selectedItemIDs = [] }
                        .foregroundStyle(AegisTheme.teal)
                        .accessibilityIdentifier("clearImportItems")
                }.buttonStyle(.plain).aegisFont(size: 12).tint(AegisTheme.teal)
                AegisInput(title: L10n.text("backup.selection.search"), icon: "magnifyingglass") {
                    TextField(L10n.text("backup.selection.search"), text: $search).autocorrectionDisabled()
                        .accessibilityIdentifier("importItemSearch")
                }
                Picker(L10n.text("backup.selection.type"), selection: $filter) {
                    ForEach(Filter.allCases) { value in Text(value.title).tag(value) }
                }.tint(AegisTheme.teal).accessibilityIdentifier("importItemType")
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { item in
                        ImportItemToggle(title: title(item), detail: detail(item),
                                         symbol: item.isPermanentlyDeleted ? "trash.slash" : item.kind?.symbol ?? "doc",
                                         itemID: item.id, selectedItemIDs: $selectedItemIDs)
                            .accessibilityIdentifier("importItem-\(item.id.uuidString)")
                        Divider().overlay(AegisTheme.border)
                    }
                }
                if filtered.isEmpty {
                    Text(L10n.text("backup.selection.noResults")).aegisFont(size: 12).foregroundStyle(AegisTheme.secondary)
                }
                if selectedItemIDs.isEmpty {
                    Label(L10n.text("backup.selection.chooseHint"), systemImage: "info.circle")
                        .aegisFont(size: 11).foregroundStyle(AegisTheme.secondary)
                }
            }
            let summary = plan.summary(for: selectedItemIDs)
            Text(L10n.format("backup.selection.revisions", Int64(summary.revisionCount), Int64(summary.newRevisionCount)))
                .aegisFont(size: 12).foregroundStyle(AegisTheme.secondary).accessibilityIdentifier("importRevisionCount")
            Text(L10n.text("backup.selection.historyHint")).aegisFont(size: 11).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
        }.aegisCard().disabled(busy)
    }

    private func title(_ item: BackupImportPlan.Item) -> String {
        if item.isPermanentlyDeleted {
            return L10n.text("backup.selection.deletedItem")
        }
        return item.title.isEmpty ? L10n.text("list.untitled") : item.title
    }

    private func detail(_ item: BackupImportPlan.Item) -> String {
        if item.isPermanentlyDeleted {
            return String(item.id.uuidString.prefix(8))
        }
        var parts = [item.kind?.title ?? ""]
        if !item.username.isEmpty {
            parts.append(item.username)
        }
        if item.isTrashed {
            parts.append(L10n.text("nav.trash"))
        }
        if item.isConflict {
            parts.append(L10n.text("backup.selection.conflict"))
        }
        return parts.joined(separator: " · ")
    }
}

struct ImportItemToggle: View {
    let title: String
    let detail: String
    let symbol: String
    let itemID: UUID
    @Binding var selectedItemIDs: Set<UUID>

    private var isSelected: Bool {
        selectedItemIDs.contains(itemID)
    }

    var body: some View {
        Button {
            if isSelected {
                selectedItemIDs.remove(itemID)
            } else {
                selectedItemIDs.insert(itemID)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(AegisTheme.teal).frame(width: 22)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).aegisFont(size: 13, weight: .medium).foregroundStyle(AegisTheme.text).lineLimit(2)
                    if !detail.isEmpty {
                        Text(detail).aegisFont(size: 11).foregroundStyle(AegisTheme.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20)).foregroundStyle(AegisTheme.teal)
            }.padding(.vertical, 12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityValue(L10n.text(isSelected ? "backup.selection.selected" : "backup.selection.unselected"))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
