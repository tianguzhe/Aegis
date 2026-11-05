import AegisCore
import Foundation
import LocalAuthentication
import Security

enum DeviceKeyStore {
    private static let service = "app.aegis.device-key.v1"

    static func save(_ data: Data, vaultID: UUID) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                         .biometryCurrentSet, &error) else {
            throw error?.takeRetainedValue() as Error? ?? VaultError.damagedData
        }
        delete(vaultID: vaultID)
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

    static func delete(vaultID: UUID) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                       kSecAttrAccount: vaultID.uuidString, kSecUseDataProtectionKeychain: true] as CFDictionary)
    }
    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey:
            (SecCopyErrorMessageString(status, nil) as String?) ?? L10n.text("error.keychain")])
    }
}
