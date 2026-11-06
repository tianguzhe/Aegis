import Foundation

/// Authenticates a decrypted backup's records and version graph (Docs/BACKUP_FORMAT_DESIGN_V1.md §8.2).
public enum BackupValidator {
    /// Returns the head entries after every revision has been authenticated with the backup's
    /// vault key. Throws `BackupError.invalidContent` for any record or graph inconsistency.
    public static func validate(_ payload: BackupPayload) async throws -> [VaultEntry] {
        try checkGraph(payload)
        let crypto = VaultCrypto()
        do {
            try await crypto.unlock(deviceKey: payload.vaultKey, header: payload.header)
            let entries = try await crypto.entries(from: payload.revisions)
            await crypto.lock()
            return entries
        } catch {
            await crypto.lock()
            throw BackupError.invalidContent
        }
    }

    /// Parents present in the file must belong to the same item and form no cycle. Parents absent
    /// from the file are allowed only when the exporter flagged the history as incomplete.
    static func checkGraph(_ payload: BackupPayload) throws {
        let byID = Dictionary(uniqueKeysWithValues: payload.revisions.map { ($0.id, $0) })
        var children: [UUID: [UUID]] = [:]
        var pendingParents: [UUID: Int] = [:]
        for revision in payload.revisions {
            var inFile = 0
            for parentID in revision.parents {
                guard let parent = byID[parentID] else {
                    guard payload.incompleteHistory else { throw BackupError.invalidContent }
                    continue
                }
                guard parent.itemID == revision.itemID else { throw BackupError.invalidContent }
                children[parentID, default: []].append(revision.id)
                inFile += 1
            }
            pendingParents[revision.id] = inFile
        }
        // Kahn's algorithm: every revision becomes ready once all its in-file parents are; any
        // revision never reached sits on a cycle.
        var ready = payload.revisions.filter { pendingParents[$0.id] == 0 }.map(\.id)
        var visited = 0
        while let id = ready.popLast() {
            visited += 1
            for child in children[id, default: []] {
                pendingParents[child, default: 0] -= 1
                if pendingParents[child] == 0 { ready.append(child) }
            }
        }
        guard visited == payload.revisions.count else { throw BackupError.invalidContent }
    }
}
