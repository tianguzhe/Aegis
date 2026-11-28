import AegisCore
import Foundation
import LocalAuthentication
import Security

enum DeviceKeyStore {
    private static let service = "app.aegis.device-key.v1"

    /// Whether biometric unlock is offered. Requires the key check, so a device that only has the
    /// key (or an older Bool flag) asks for the password once and re-enables biometrics.
    static func isEnabled(vaultID: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: enabledKey(vaultID)) && keyCheck(vaultID: vaultID) != nil
    }

    /// The commitment from `VaultCrypto.deviceKeyCheck`. Kept outside the Keychain item on purpose:
    /// it must detect a Keychain entry that no longer holds this vault's key.
    static func keyCheck(vaultID: UUID) -> Data? {
        UserDefaults.standard.data(forKey: checkKey(vaultID))
    }

    /// Removes the flags only; callers delete the Keychain item separately so its errors surface.
    static func forget(vaultID: UUID) {
        UserDefaults.standard.removeObject(forKey: enabledKey(vaultID))
        UserDefaults.standard.removeObject(forKey: checkKey(vaultID))
    }

    private static func enabledKey(_ vaultID: UUID) -> String {
        "biometry.\(vaultID)"
    }

    private static func checkKey(_ vaultID: UUID) -> String {
        "biometryCheck.\(vaultID)"
    }

    /// Stores `data` behind biometrics and records its key check. `data` must be the vault key of an
    /// unlocked session, since the check is what later confirms it.
    static func save(_ data: Data, vaultID: UUID) throws {
        try saveItem(data, vaultID: vaultID)
        UserDefaults.standard.set(VaultCrypto.deviceKeyCheck(data, vaultID: vaultID), forKey: checkKey(vaultID))
        UserDefaults.standard.set(true, forKey: enabledKey(vaultID))
    }

    #if DEBUG
        static func markEnabledForPreview(key: Data, vaultID: UUID) {
            UserDefaults.standard.set(VaultCrypto.deviceKeyCheck(key, vaultID: vaultID), forKey: checkKey(vaultID))
            UserDefaults.standard.set(true, forKey: enabledKey(vaultID))
        }
    #endif

    private static func saveItem(_ data: Data, vaultID: UUID) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .biometryCurrentSet, &error)
        else {
            throw error?.takeRetainedValue() as Error? ?? VaultError.damagedData
        }
        try delete(vaultID: vaultID)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: vaultID.uuidString,
                                    kSecAttrAccessControl as String: access,
                                    kSecUseDataProtectionKeychain as String: true,
                                    kSecValueData as String: data]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    static func read(vaultID: UUID) throws -> Data {
        let context = LAContext()
        context.localizedReason = L10n.text("biometric.reason")
        context.localizedFallbackTitle = ""
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: vaultID.uuidString,
                                    kSecUseDataProtectionKeychain as String: true,
                                    kSecUseAuthenticationContext as String: context,
                                    kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw keychainError(status) }
        return data
    }

    static func delete(vaultID: UUID) throws {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                     kSecAttrAccount: vaultID.uuidString, kSecUseDataProtectionKeychain: true] as CFDictionary
        let status: OSStatus
        #if DEBUG
            status = PreviewFixtures.keychainDeleteFails ? errSecInteractionNotAllowed : SecItemDelete(query)
        #else
            status = SecItemDelete(query)
        #endif
        // An absent item already satisfies the caller's request to revoke biometric access.
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey:
                (SecCopyErrorMessageString(status, nil) as String?) ?? L10n.text("error.keychain")])
    }
}
