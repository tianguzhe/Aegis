import Foundation

/// User-selected card network; no issuer or product is inferred from the PAN.
public enum CardBrand: String, Codable, CaseIterable, Identifiable, Sendable {
    case unionPay, visa, mastercard, americanExpress
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .unionPay: L10n.text("card.brand.unionPay")
        case .visa: L10n.text("card.brand.visa")
        case .mastercard: L10n.text("card.brand.mastercard")
        case .americanExpress: L10n.text("card.brand.americanExpress")
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "centurion" {
            self = .americanExpress
        } else if let brand = Self(rawValue: value) {
            self = brand
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported card network")
        }
    }
}

public enum PaymentCardType: String, Codable, CaseIterable, Identifiable, Sendable {
    case debit, credit
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .debit: L10n.text("card.type.debit")
        case .credit: L10n.text("card.type.credit")
        }
    }
}

public enum CardNumberValidation: Sendable, Equatable {
    case empty, tooShort, tooLong, invalidChecksum, valid
    public var allowsSaving: Bool { self == .empty || self == .valid }
    public var message: String {
        switch self {
        case .empty: L10n.text("card.number.empty")
        case .tooShort: L10n.format("card.number.tooShort", Int64(CardNumberRules.minimumLength))
        case .tooLong: L10n.format("card.number.tooLong", Int64(CardNumberRules.maximumLength))
        case .invalidChecksum: L10n.text("card.number.invalid")
        case .valid: L10n.text("card.number.valid")
        }
    }
}

/// PAN syntax and checksum only; does not identify an issuer, network, or funding type.
public enum CardNumberRules {
    public static let minimumLength = 8
    public static let maximumLength = 19

    public static func digits(from value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.compactMap { scalar in
            switch scalar.value {
            case 48...57: scalar
            case 0xFF10...0xFF19: UnicodeScalar(scalar.value - 0xFF10 + 48)
            default: nil
            }
        }))
    }

    public static func validate(_ value: String) -> CardNumberValidation {
        let bytes = Array(digits(from: value).utf8)
        guard !bytes.isEmpty else { return .empty }
        guard bytes.count >= minimumLength else { return .tooShort }
        guard bytes.count <= maximumLength else { return .tooLong }
        guard bytes.contains(where: { $0 != 48 }) else { return .invalidChecksum }
        let sum = bytes.reversed().enumerated().reduce(0) { total, entry in
            let digit = Int(entry.element - 48)
            let doubled = entry.offset.isMultiple(of: 2) ? digit : digit * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum.isMultiple(of: 10) ? .valid : .invalidChecksum
    }
}

extension VaultItem {
    public var cardLastFour: String {
        String(CardNumberRules.digits(from: cardNumber).suffix(4))
    }

    public var maskedCardNumber: String {
        let tail = cardLastFour
        return "••••  ••••  ••••  " + (tail.count == 4 ? tail : "••••")
    }

    public var cardDescription: String {
        let labels = [cardBrand?.title, cardType?.title].compactMap { $0 }
        return labels.isEmpty ? ItemKind.card.title : labels.joined(separator: " · ")
    }
}
