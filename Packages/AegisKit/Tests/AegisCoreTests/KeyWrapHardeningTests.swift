@testable import AegisCore
import Foundation
import Testing

/// Key-wrap AAD binding, master password normalization, and device key checks.
struct KeyWrapHardeningTests {
    private static let password = "Synthetic hardening passphrase"

    private static func tampered(_ header: VaultHeader, salt: Data? = nil, kdf: KDFParameters? = nil) -> VaultHeader {
        VaultHeader(vaultID: header.vaultID, salt: salt ?? header.salt, kdf: kdf ?? header.kdf,
                    wrappedKey: header.wrappedKey, recoveryWrappedKey: header.recoveryWrappedKey)
    }

    @Test func changedKDFParametersFailBothUnwraps() async throws {
        let crypto = VaultCrypto()
        let created = try await crypto.create(password: Self.password)
        var stronger = created.header.kdf
        stronger.iterations += 1
        let header = Self.tampered(created.header, kdf: stronger)
        try header.validate()
        #expect(throws: VaultError.invalidPassword) { try VaultCrypto.unwrapVaultKey(password: Self.password, header: header) }
        // The recovery key needs neither field, yet its wrap is bound to them too.
        #expect(throws: VaultError.invalidPassword) {
            try VaultCrypto.unwrapVaultKey(recoveryKey: created.recoveryKey, header: header)
        }
        #expect(throws: Never.self) { try VaultCrypto.unwrapVaultKey(recoveryKey: created.recoveryKey, header: created.header) }
    }

    @Test func changedSaltFailsTheRecoveryUnwrap() async throws {
        let created = try await VaultCrypto().create(password: Self.password)
        let header = Self.tampered(created.header, salt: Data(repeating: 7, count: 16))
        #expect(throws: VaultError.invalidPassword) {
            try VaultCrypto.unwrapVaultKey(recoveryKey: created.recoveryKey, header: header)
        }
    }

    @Test func masterPasswordIsComparedAfterNFCNormalization() async throws {
        let decomposed = "Cafe\u{0301} au lait sans sucre"
        let composed = "Caf\u{00E9} au lait sans sucre"
        #expect(Array(decomposed.utf8) != Array(composed.utf8))
        let created = try await VaultCrypto().create(password: decomposed)
        #expect(throws: Never.self) { try VaultCrypto.unwrapVaultKey(password: composed, header: created.header) }
        #expect(throws: Never.self) { try VaultCrypto.unwrapVaultKey(password: decomposed, header: created.header) }
    }

    @Test func deviceKeyMustMatchItsCheck() async throws {
        let crypto = VaultCrypto()
        let created = try await crypto.create(password: Self.password)
        let key = try await crypto.deviceKey()
        let check = VaultCrypto.deviceKeyCheck(key, vaultID: created.header.vaultID)
        await crypto.lock()

        let wrong = Data(repeating: 0, count: 32)
        await #expect(throws: VaultError.deviceKeyMismatch) {
            try await crypto.unlock(deviceKey: wrong, header: created.header, keyCheck: check)
        }
        await #expect(throws: VaultError.deviceKeyMismatch) {
            try await crypto.unlock(deviceKey: key, header: created.header, keyCheck: Data())
        }
        // A check for another vault ID does not transfer.
        let foreign = VaultCrypto.deviceKeyCheck(key, vaultID: UUID())
        await #expect(throws: VaultError.deviceKeyMismatch) {
            try await crypto.unlock(deviceKey: key, header: created.header, keyCheck: foreign)
        }
        await #expect(throws: VaultError.locked) { try await crypto.deviceKey() }

        try await crypto.unlock(deviceKey: key, header: created.header, keyCheck: check)
        #expect(try await crypto.deviceKey() == key)
    }
}
