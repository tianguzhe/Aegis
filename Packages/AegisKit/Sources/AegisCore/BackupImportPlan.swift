import Foundation

/// Item-level selection over already authenticated revisions. Each item is an indivisible history,
/// including every conflict branch and terminal deletion marker.
public struct BackupImportPlan: Sendable {
    public struct Item: Identifiable, Sendable {
        public let id: UUID
        public let title: String
        public let username: String
        public let kind: ItemKind?
        public let isTrashed: Bool
        public let isConflict: Bool
        public let isPermanentlyDeleted: Bool
    }

    public struct Summary: Sendable {
        public let itemCount: Int
        public let revisionCount: Int
        public let newRevisionCount: Int
    }

    public let items: [Item]
    public let itemIDs: Set<UUID>
    private let revisions: [EncryptedRevision]
    private let existingRevisionIDs: Set<UUID>

    /// Both arguments must come from the same fully validated snapshot, in destination identities.
    public init(revisions: [EncryptedRevision], entries: [VaultEntry], existingRevisionIDs: Set<UUID> = []) {
        self.revisions = revisions
        self.existingRevisionIDs = existingRevisionIDs
        itemIDs = Set(revisions.map(\.itemID))
        let groups = Dictionary(grouping: entries, by: \.item.id)
        items = itemIDs.map { id in
            let group = groups[id] ?? []
            let representative = group.sorted {
                if $0.item.modifiedAt != $1.item.modifiedAt {
                    return $0.item.modifiedAt > $1.item.modifiedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }.first?.item
            let title = representative?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Item(id: id, title: title, username: representative?.username ?? "", kind: representative?.kind,
                        isTrashed: !group.isEmpty && group.allSatisfy { $0.item.deletedAt != nil },
                        isConflict: group.count > 1, isPermanentlyDeleted: group.isEmpty)
        }.sorted {
            if $0.isPermanentlyDeleted != $1.isPermanentlyDeleted {
                return !$0.isPermanentlyDeleted
            }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    public func canImport(_ selectedItemIDs: Set<UUID>) -> Bool {
        selectedItemIDs.isSubset(of: itemIDs) && (items.isEmpty || !selectedItemIDs.isEmpty)
    }

    public func summary(for selectedItemIDs: Set<UUID>) -> Summary {
        let selected = revisions.filter { selectedItemIDs.contains($0.itemID) }
        return Summary(itemCount: selectedItemIDs.intersection(itemIDs).count, revisionCount: selected.count,
                       newRevisionCount: selected.filter { !existingRevisionIDs.contains($0.id) }.count)
    }

    public func selectedRevisions(for selectedItemIDs: Set<UUID>) throws -> [EncryptedRevision] {
        guard selectedItemIDs.isSubset(of: itemIDs) else { throw BackupSelectionError.invalidSelection }
        guard items.isEmpty || !selectedItemIDs.isEmpty else { throw BackupSelectionError.noSelection }
        return revisions.filter { selectedItemIDs.contains($0.itemID) }
    }
}

public enum BackupSelectionError: Error, LocalizedError, Sendable {
    case noSelection, invalidSelection
    public var errorDescription: String? {
        switch self {
        case .noSelection: L10n.text("backup.selection.chooseHint")
        case .invalidSelection: L10n.text("backup.selection.invalid")
        }
    }
}
