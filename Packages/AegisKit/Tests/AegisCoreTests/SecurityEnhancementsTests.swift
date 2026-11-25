@testable import AegisCore
import Foundation
import XCTest

final class SecurityEnhancementsTests: XCTestCase {
    // MARK: - SecurityPreferences

    func testSecurityPreferencesRoundTripAndResilientDecode() throws {
        let suite = "app.aegis.test.security.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(SecurityPreferences.load(from: defaults), SecuritySettings())

        let custom = SecuritySettings(autoLock: .fifteenMinutes, clipboardClear: .sixtySeconds)
        SecurityPreferences.save(custom, to: defaults)
        XCTAssertEqual(SecurityPreferences.load(from: defaults), custom)

        // Unknown raw values fall back to safe defaults instead of throwing.
        let malformed = Data(#"{"autoLock": 999999, "clipboardClear": -5}"#.utf8)
        defaults.set(malformed, forKey: "aegis.security-settings.v1")
        XCTAssertEqual(SecurityPreferences.load(from: defaults), SecuritySettings())
    }

    // MARK: - PasswordStrength

    func testPasswordStrengthClassifiesWeakAndStrongInputs() {
        XCTAssertEqual(PasswordStrength.evaluate("").level, .weak)
        XCTAssertEqual(PasswordStrength.evaluate("password123").level, .weak)
        XCTAssertEqual(PasswordStrength.evaluate("123456789012").level, .weak)
        XCTAssertEqual(PasswordStrength.evaluate("aaaaaaaaaaaa").level, .weak)
        XCTAssertEqual(PasswordStrength.evaluate("qwertyuiop12").level, .weak)

        let strongRandom = PasswordStrength.evaluate("K9#mP2!vX8@qL4$nR7")
        XCTAssertEqual(strongRandom.level, .strong)
        XCTAssertTrue(strongRandom.suggestions.isEmpty)

        let strongPassphrase = PasswordStrength.evaluate("Amber-Canyon-7-Velvet-Harbor-Quartz-Spruce")
        XCTAssertGreaterThanOrEqual(strongPassphrase.level, .good)
    }

    // MARK: - Passphrase Generator

    func testPassphraseWordlistIntegrityAndGeneration() throws {
        let words = PassphraseWordlist.words
        XCTAssertGreaterThanOrEqual(words.count, 512)
        XCTAssertEqual(Set(words).count, words.count)
        XCTAssertTrue(words.allSatisfy { $0.count >= 4 && $0.count <= 7 && $0 == $0.lowercased() })

        var options = PasswordOptions()
        options.mode = .passphrase
        options.wordCount = 6
        options.separator = .dot
        options.capitalizeWords = true
        options.includeNumber = true

        let phrase = try PasswordGenerator.generate(options: options)
        let parts = phrase.split(separator: ".")
        XCTAssertEqual(parts.count, 6)
        XCTAssertTrue(parts.allSatisfy { $0.first?.isUppercase == true })
        XCTAssertTrue(phrase.contains(where: \.isNumber))
    }

    func testPasswordOptionsDecodesLegacyPayload() throws {
        let legacy = Data(#"{"length":24,"uppercase":true,"digits":true,"symbols":false}"#.utf8)
        let decoded = try JSONDecoder().decode(PasswordOptions.self, from: legacy)
        XCTAssertEqual(decoded.mode, .random)
        XCTAssertEqual(decoded.length, 24)
        XCTAssertFalse(decoded.symbols)
        XCTAssertEqual(decoded.wordCount, 5)
        XCTAssertEqual(decoded.separator, .hyphen)
    }

    // MARK: - DomainMatcher

    func testDomainMatcherRanksExactSubdomainMultiPartAndBundleIDs() {
        XCTAssertEqual(DomainMatcher.registrableDomain(for: "login.example.com"), "example.com")
        XCTAssertEqual(DomainMatcher.registrableDomain(for: "accounts.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(DomainMatcher.registrableDomain(for: "mail.company.com.cn"), "company.com.cn")
        XCTAssertEqual(DomainMatcher.registrableDomain(for: "alice.github.io"), "alice.github.io")
        XCTAssertNil(DomainMatcher.registrableDomain(for: "127.0.0.1"))
        XCTAssertNil(DomainMatcher.registrableDomain(for: "localhost"))

        XCTAssertEqual(DomainMatcher.rank(website: "https://login.example.com/signin", against: ["login.example.com"]), .exactHost)
        XCTAssertEqual(DomainMatcher.rank(website: "https://example.com", against: ["login.example.com"]), .registrableDomain)
        XCTAssertEqual(DomainMatcher.rank(website: "https://accounts.example.com", against: ["login.example.com"]), .registrableDomain)
        // Separate tenants on shared hosting must never match each other.
        XCTAssertEqual(DomainMatcher.rank(website: "https://alice.github.io", against: ["bob.github.io"]), .none)
        // Reverse-DNS Apple bundle identifiers match their forward registrable domain.
        XCTAssertEqual(DomainMatcher.rank(website: "https://github.com", against: ["com.github.stormcrow"]), .registrableDomain)

        func credential(_ title: String, website: String) -> AutoFillCredential {
            let item = VaultItem(kind: .login, title: title, username: "u", password: "p", website: website)
            let rev = EncryptedRevision(vaultID: UUID(), itemID: item.id, id: UUID(), parents: [], ciphertext: Data())
            return AutoFillCredential(entry: VaultEntry(item: item, revision: rev, isConflict: false))
        }
        let exact = credential("Exact", website: "https://login.example.com")
        let sub = credential("Sub", website: "https://example.com")
        let other = credential("Alpha", website: "https://other.org")
        let sorted = DomainMatcher.sortCredentials([other, sub, exact], for: ["login.example.com"])
        XCTAssertEqual(sorted.map(\.title), ["Exact", "Sub", "Alpha"])
    }

    // MARK: - VaultHistory

    func testItemHistoryOrdersRevisionsMarksHeadsAndIgnoresTamperedRecords() async throws {
        let crypto = VaultCrypto()
        let (header, _) = try await crypto.create(password: "history test master password")

        var v1 = VaultItem(kind: .login, title: "Example", username: "alice", password: "OldPassword!123")
        v1.modifiedAt = Date(timeIntervalSince1970: 1000)
        let r1 = try await crypto.encrypt(v1, parents: [])

        var v2 = v1
        v2.password = "NewPassword!456"
        v2.modifiedAt = Date(timeIntervalSince1970: 2000)
        let r2 = try await crypto.encrypt(v2, parents: [r1.id])

        // Concurrent branch creates a conflict head.
        var v3 = v1
        v3.username = "alice@example.com"
        v3.modifiedAt = Date(timeIntervalSince1970: 1500)
        let r3 = try await crypto.encrypt(v3, parents: [r1.id])

        // Tampered revision for the same item must be ignored.
        let tampered = EncryptedRevision(vaultID: header.vaultID, itemID: v1.id, id: UUID(), parents: [r2.id], ciphertext: Data([1, 2, 3]))

        let history = try await crypto.itemHistory(for: v1.id, in: [r1, r2, r3, tampered])
        XCTAssertEqual(history.map(\.id), [r2.id, r3.id, r1.id])
        XCTAssertTrue(history[0].isCurrentHead)
        XCTAssertTrue(history[0].isConflictHead)
        XCTAssertTrue(history[1].isCurrentHead)
        XCTAssertTrue(history[1].isConflictHead)
        XCTAssertFalse(history[2].isCurrentHead)

        XCTAssertEqual(VaultHistoryDiff.changes(from: nil, to: v1), [.created])
        XCTAssertEqual(VaultHistoryDiff.changes(from: v1, to: v2), [.password])
        XCTAssertEqual(VaultHistoryDiff.changes(from: v1, to: v3), [.username])
    }

    // MARK: - PasswordHealth

    func testPasswordHealthDetectsWeakReusedAndAgedLogins() async throws {
        let crypto = VaultCrypto()
        _ = try await crypto.create(password: "health test master password")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        func makeEntry(_ item: VaultItem) async throws -> VaultEntry {
            let revision = try await crypto.encrypt(item, parents: [])
            return VaultEntry(item: item, revision: revision, isConflict: false)
        }

        var weakItem = VaultItem(kind: .login, title: "Weak", username: "a", password: "password123")
        weakItem.modifiedAt = now

        var reusedA = VaultItem(kind: .login, title: "Site A", username: "a", password: "Shared!Strong#Pass99")
        reusedA.modifiedAt = now

        var reusedB = VaultItem(kind: .login, title: "Site B", username: "b", password: "Shared!Strong#Pass99")
        reusedB.modifiedAt = now.addingTimeInterval(-200 * 86400)

        var healthy = VaultItem(kind: .login, title: "Healthy", username: "c", password: "Unique#9K!mP2$vX8@qL4")
        healthy.modifiedAt = now

        var trashed = VaultItem(kind: .login, title: "Trashed", username: "d", password: "123")
        trashed.deletedAt = now
        trashed.modifiedAt = now

        let entries = try await [makeEntry(weakItem), makeEntry(reusedA), makeEntry(reusedB), makeEntry(healthy), makeEntry(trashed)]
        let report = PasswordHealth.analyze(entries, now: now)

        XCTAssertEqual(report.totalLogins, 4)
        XCTAssertEqual(report.loginsWithPassword, 4)
        XCTAssertEqual(report.weak.map(\.entry.item.title), ["Weak"])
        XCTAssertEqual(report.reusedGroups.count, 1)
        XCTAssertEqual(report.reusedGroups[0].entries.map(\.item.title), ["Site A", "Site B"])
        XCTAssertFalse(report.reusedGroups[0].id.contains("Shared"))
        XCTAssertEqual(report.aged.map(\.entry.item.title), ["Site B"])
        XCTAssertEqual(report.aged.first?.ageDays, 200)
        XCTAssertEqual(report.affectedEntryCount, 3)
        XCTAssertLessThan(report.score, 100)
    }
}
