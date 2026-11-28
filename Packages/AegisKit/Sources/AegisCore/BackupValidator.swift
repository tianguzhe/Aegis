import Foundation

/// Authenticates a decrypted backup's records and version graph (Docs/BACKUP_FORMAT_DESIGN_V1.md §8.2).
public enum BackupValidator {
    /// Returns the head entries after every revision has been authenticated with the backup's
    /// vault key. Throws `BackupError.invalidContent` for any record or graph inconsistency.
    public static func validate(_ payload: BackupPayload) async throws -> [VaultEntry] {
        try checkGraph(payload)
        let crypto = VaultCrypto()
        do {
            try await crypto.unlock(verifiedKey: payload.vaultKey, header: payload.header)
            let entries = try await crypto.entries(from: payload.revisions)
            await crypto.lock()
            return entries
        } catch {
            await crypto.lock()
            throw BackupError.invalidContent
        }
    }

    static func checkGraph(_ payload: BackupPayload) throws {
        do { try VaultRevisionValidation.checkGraph(payload.revisions) }
        catch { throw BackupError.invalidContent }
    }
}

public enum VaultRevisionValidation {
    /// Checks a snapshot before it can be advertised.
    public static func validateSyncSnapshot(_ revisions: [EncryptedRevision]) throws {
        try checkGraph(revisions)
    }

    /// Validates graph shape after appending `incoming` to `local` and returns the union. Callers
    /// must authenticate the records separately and commit against the same local snapshot.
    /// Throws `VaultError.damagedData` on an ID already in `local` or an invalid graph.
    public static func validateSyncUnion(local: [EncryptedRevision], incoming: [EncryptedRevision]) throws -> [EncryptedRevision] {
        let localIDs = Set(local.map(\.id))
        guard incoming.allSatisfy({ !localIDs.contains($0.id) }) else { throw VaultError.damagedData }
        let combined = local + incoming
        try checkGraph(combined)
        return combined
    }

    /// Every parent must be present and belong to the same item, and the graph must be acyclic.
    /// History is always exchanged per whole item, so a missing parent means damaged data.
    static func checkGraph(_ revisions: [EncryptedRevision]) throws {
        var byID: [UUID: EncryptedRevision] = [:]
        for revision in revisions {
            guard byID.updateValue(revision, forKey: revision.id) == nil else { throw VaultError.damagedData }
        }
        var children: [UUID: [UUID]] = [:]
        var pendingParents: [UUID: Int] = [:]
        for revision in revisions {
            for parentID in revision.parents {
                guard let parent = byID[parentID], parent.itemID == revision.itemID else { throw VaultError.damagedData }
                children[parentID, default: []].append(revision.id)
            }
            pendingParents[revision.id] = revision.parents.count
        }
        // Kahn's algorithm: every revision becomes ready once all its parents are; any
        // revision never reached sits on a cycle.
        var ready = revisions.filter { pendingParents[$0.id] == 0 }.map(\.id)
        var visited = 0
        while let id = ready.popLast() {
            visited += 1
            for child in children[id, default: []] {
                pendingParents[child, default: 0] -= 1
                if pendingParents[child] == 0 {
                    ready.append(child)
                }
            }
        }
        guard visited == revisions.count else { throw VaultError.damagedData }
    }
}
