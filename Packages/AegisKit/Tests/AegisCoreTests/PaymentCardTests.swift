import AegisCore
import Foundation
import Testing

struct PaymentCardTests {
    @Test func legacyCenturionSelectionBecomesAmericanExpress() throws {
        let brand = try JSONDecoder().decode(CardBrand.self, from: Data("\"centurion\"".utf8))
        #expect(brand == .americanExpress)
        #expect(String(decoding: try JSONEncoder().encode(brand), as: UTF8.self) == "\"americanExpress\"")
    }
    @Test func oldEncryptedItemPayloadNeedsNoNewFields() throws {
        var original = VaultItem(kind: .card, title: "Legacy card", notes: "Preserve my note")
        original.cardNumber = "1234 5678 9012 3456"
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "cardBrand")
        object.removeValue(forKey: "cardType")
        let restored = try JSONDecoder().decode(VaultItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.id == original.id)
        #expect(restored.cardNumber == original.cardNumber)
        #expect(restored.notes == original.notes)
        #expect(restored.cardBrand == nil)
        #expect(restored.cardType == nil)
    }

    @Test func allEightAppearancesSurviveEncryptedStorage() async throws {
        let crypto = VaultCrypto()
        let created = try await crypto.create(password: "Synthetic card fixture passphrase")
        var versions: [EncryptedRevision] = []
        for brand in CardBrand.allCases {
            for type in PaymentCardType.allCases {
                var item = VaultItem(kind: .card, title: brand.rawValue)
                item.cardBrand = brand; item.cardType = type
                versions.append(try await crypto.encrypt(item, parents: []))
            }
        }
        await crypto.lock()
        try await crypto.unlock(password: "Synthetic card fixture passphrase", header: created.header)
        let restored = try await crypto.entries(from: versions)
        #expect(restored.count == 8)
        let appearances = restored.map { "\($0.item.cardBrand!.rawValue)-\($0.item.cardType!.rawValue)" }
        #expect(Set(appearances).count == 8)
    }

    @Test func previewOnlyExposesLastFourAndNeverIncompleteNumbers() {
        var item = VaultItem(kind: .card)
        item.cardNumber = "4242-4242 4242 8088"
        #expect(item.maskedCardNumber == "••••  ••••  ••••  8088")
        item.cardNumber = "123"
        #expect(item.maskedCardNumber == "••••  ••••  ••••  ••••")
        item.cardNumber = ""
        let containsDigits = item.maskedCardNumber.contains { $0.isNumber }
        #expect(!containsDigits)
    }

    @Test func luhnChecksOddEvenLengthsWithoutInferringTheCardBrand() {
        for valid in ["4111111111111111", "5555555555554444", "378282246310005", "79927398713"] {
            #expect(CardNumberRules.validate(valid) == .valid)
        }
        #expect(CardNumberRules.validate("4111111111111112") == .invalidChecksum)
        #expect(CardNumberRules.validate("0000000000000000") == .invalidChecksum)
        #expect(CardNumberRules.validate("1234567") == .tooShort)
        #expect(CardNumberRules.validate("41111111111111111111") == .tooLong)
        #expect(CardNumberRules.validate("") == .empty)
    }

    @Test func digitFilteringSupportsPastingWithoutSilentlyTruncating() {
        #expect(CardNumberRules.digits(from: "４１１１ 1111-1111x1111") == "4111111111111111")
        let tooLong = "41111111111111111111"
        #expect(CardNumberRules.digits(from: tooLong) == tooLong)
        #expect(!CardNumberRules.validate(tooLong).allowsSaving)
        #expect(CardNumberRules.validate("").allowsSaving)
    }
}
