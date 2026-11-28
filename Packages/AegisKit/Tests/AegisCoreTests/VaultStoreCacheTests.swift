import AegisCore
@testable import AegisStorage
import Foundation
import Testing

/// The decoded-revision mirror must always equal what a fresh read of the database returns.
struct VaultStoreCacheTests {
    private struct InjectedFailure: Error {}

    private static func reopened(_ directory: URL) async throws -> Set<UUID> {
        try await Set(VaultStore.make(directory: directory).revisions().map(\.id))
    }

    @Test func mirrorMatchesTheDatabaseAcrossWritesAndFailedCommits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = VaultCrypto()
        let created = try await crypto.create(password: "Synthetic store cache passphrase")
        let store = try VaultStore.make(directory: directory)
        try await store.saveHeader(created.header)

        let first = try await crypto.encrypt(VaultItem(title: "First"), parents: [])
        try await store.saveRevision(first)
        // Populate the mirror, then keep writing through every path that updates it.
        #expect(try await store.revisions().map(\.id) == [first.id])
        let second = try await crypto.encrypt(VaultItem(title: "Second"), parents: [])
        try await store.saveRevision(second)
        try await store.saveRevision(second)
        let expected = try await store.snapshot()
        let third = try await crypto.encrypt(VaultItem(title: "Third"), parents: [])
        _ = try await store.appendSyncedRevisions([third], expected: expected)

        let stored = Set([first.id, second.id, third.id])
        #expect(try await Set(store.revisions().map(\.id)) == stored)
        #expect(try await store.localRevisions().unreadableRowCount == 0)
        #expect(try await Self.reopened(directory) == stored)

        // A commit that fails after inserting rows must leave both the database and the mirror unchanged.
        let fourth = try await crypto.encrypt(VaultItem(title: "Fourth"), parents: [])
        let current = try await store.snapshot()
        await #expect(throws: InjectedFailure.self) {
            try await store.appendSyncedRevisions([fourth], expected: current) { throw InjectedFailure() }
        }
        #expect(try await Set(store.revisions().map(\.id)) == stored)
        #expect(try await Self.reopened(directory) == stored)

        // A stale snapshot is rejected before any write.
        await #expect(throws: VaultError.vaultChanged) {
            try await store.appendSyncedRevisions([fourth], expected: expected)
        }
        #expect(try await Self.reopened(directory) == stored)
    }
}
