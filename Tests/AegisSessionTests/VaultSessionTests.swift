import AegisCore
import AegisStorage
import Foundation
import Testing

/// Session-layer behavior over an in-memory store. No Keychain, App Group or network is touched:
/// the test bundle has no App Group in its Info.plist, so AutoFill publication is skipped.
@MainActor
struct VaultSessionTests {
    private static let password = "Synthetic session test passphrase"

    private func makeSession() async throws -> VaultSession {
        let session = VaultSession()
        session.store = try VaultStore.make(inMemory: true)
        session.localState = LocalVaultStateStore(directory: nil)
        session.phase = .setup
        await session.create(password: Self.password)
        #expect(session.error == nil)
        try #require(session.phase == .unlocked)
        session.recoveryAcknowledged = true
        session.confirmRecovery()
        return session
    }

    private func saved(_ title: String, in session: VaultSession) async throws -> VaultEntry {
        let item = VaultItem(title: title, username: "alice", password: "secret")
        try #require(await session.save(item, parents: []))
        return try #require(session.entries.first { $0.item.id == item.id })
    }

    private func relock(_ session: VaultSession) async {
        session.lock()
        await session.lockingTask?.value
        await session.unlock(password: Self.password)
    }

    @Test func lockClearsPlaintextAndPasswordUnlockRestoresIt() async throws {
        let session = try await makeSession()
        let entry = try await saved("Example", in: session)

        session.lock()
        #expect(session.phase == .locked)
        #expect(session.entries.isEmpty)
        await session.lockingTask?.value
        await #expect(throws: VaultError.locked) { try await session.crypto.deviceKey() }

        await session.unlock(password: "Wrong session test passphrase")
        #expect(session.phase == .locked && session.error != nil)
        session.error = nil
        await session.unlock(password: Self.password)
        #expect(session.phase == .unlocked)
        #expect(session.entries.map(\.item.id) == [entry.item.id])
    }

    @Test func lockFlushesAPendingDraft() async throws {
        let session = try await makeSession()
        let entry = try await saved("Original", in: session)
        var edited = entry.item
        edited.title = "Typed just before locking"
        session.retainDraftSoon(VaultDraft(item: edited, original: entry.item, parents: [entry.id]))

        await relock(session)
        #expect(session.recoverableDrafts.map(\.item.title) == ["Typed just before locking"])
    }

    @Test func discardingBeforeTheDelayDoesNotResurrectTheDraft() async throws {
        let session = try await makeSession()
        let entry = try await saved("Original", in: session)
        var edited = entry.item
        edited.title = "Unsaved"
        session.retainDraftSoon(VaultDraft(item: edited, original: entry.item, parents: [entry.id]))
        session.discardDraft(entry.item.id)

        try await Task.sleep(for: VaultSession.draftWriteDelay * 3)
        #expect(session.recoverableDrafts.isEmpty)
        await relock(session)
        #expect(session.recoverableDrafts.isEmpty)
    }

    @Test func aDirectRetainSupersedesTheOlderPendingDraft() async throws {
        let session = try await makeSession()
        let entry = try await saved("Original", in: session)
        var older = entry.item, newer = entry.item
        older.title = "Older keystroke"
        newer.title = "Kept on close"
        session.retainDraftSoon(VaultDraft(item: older, original: entry.item, parents: [entry.id]))
        session.retainDraft(VaultDraft(item: newer, original: entry.item, parents: [entry.id]))

        try await Task.sleep(for: VaultSession.draftWriteDelay * 3)
        #expect(session.recoverableDrafts.map(\.item.title) == ["Kept on close"])
    }

    @Test func pendingDraftsForDifferentItemsAreBothKept() async throws {
        let session = try await makeSession()
        let first = try await saved("First", in: session)
        let second = try await saved("Second", in: session)
        var a = first.item, b = second.item
        a.title = "First edited"
        b.title = "Second edited"
        session.retainDraftSoon(VaultDraft(item: a, original: first.item, parents: [first.id]))
        session.retainDraftSoon(VaultDraft(item: b, original: second.item, parents: [second.id]))

        try await Task.sleep(for: VaultSession.draftWriteDelay * 3)
        #expect(Set(session.recoverableDrafts.map(\.item.title)) == ["First edited", "Second edited"])
    }

    @Test func anEditorCannotResurrectAPermanentlyDeletedItem() async throws {
        let session = try await makeSession()
        let entry = try await saved("Doomed", in: session)
        await session.trash(entry)
        let trashed = try #require(session.entries.first { $0.item.id == entry.item.id })
        await session.deleteImmediately(trashed)
        #expect(!session.entries.contains { $0.item.id == entry.item.id })

        // An editor opened before the deletion still holds the original parents.
        var stale = entry.item
        stale.title = "Edited elsewhere"
        session.error = nil
        #expect(await session.save(stale, parents: [entry.id]) == false)
        #expect(session.error != nil)
        #expect(!session.entries.contains { $0.item.id == entry.item.id })
    }

    @Test func savesSurviveRepeatedReadsOfTheCachedStore() async throws {
        let session = try await makeSession()
        let entry = try await saved("Version 1", in: session)
        var item = entry.item
        var parent = entry.id
        for version in 2 ... 5 {
            item.title = "Version \(version)"
            try #require(await session.save(item, parents: [parent]))
            parent = try #require(session.entries.first { $0.item.id == item.id }).id
        }
        await relock(session)
        let current = try #require(session.entries.first { $0.item.id == item.id })
        #expect(current.item.title == "Version 5" && !current.isConflict)
        #expect(try await session.store?.revisions().count == 5)
    }
}
