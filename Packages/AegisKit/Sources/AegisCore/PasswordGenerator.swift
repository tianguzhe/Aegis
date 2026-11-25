import Foundation

public enum PasswordMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case random
    case passphrase

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .random: L10n.text("generator.mode.random")
        case .passphrase: L10n.text("generator.mode.passphrase")
        }
    }
}

public enum PassphraseSeparator: String, Codable, CaseIterable, Identifiable, Sendable {
    case hyphen = "-"
    case dot = "."
    case space = " "
    case underscore = "_"

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .hyphen: L10n.text("generator.separator.hyphen")
        case .dot: L10n.text("generator.separator.dot")
        case .space: L10n.text("generator.separator.space")
        case .underscore: L10n.text("generator.separator.underscore")
        }
    }
}

public struct PasswordOptions: Codable, Equatable, Sendable {
    public var mode: PasswordMode = .random
    public var length = 16
    public var uppercase = true
    public var digits = true
    public var symbols = true
    public var wordCount = 5
    public var separator: PassphraseSeparator = .hyphen
    public var capitalizeWords = true
    public var includeNumber = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case mode, length, uppercase, digits, symbols, wordCount, separator, capitalizeWords, includeNumber
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? container.decodeIfPresent(PasswordMode.self, forKey: .mode)) ?? .random
        length = (try? container.decodeIfPresent(Int.self, forKey: .length)) ?? 16
        uppercase = (try? container.decodeIfPresent(Bool.self, forKey: .uppercase)) ?? true
        digits = (try? container.decodeIfPresent(Bool.self, forKey: .digits)) ?? true
        symbols = (try? container.decodeIfPresent(Bool.self, forKey: .symbols)) ?? true
        wordCount = (try? container.decodeIfPresent(Int.self, forKey: .wordCount)) ?? 5
        separator = (try? container.decodeIfPresent(PassphraseSeparator.self, forKey: .separator)) ?? .hyphen
        capitalizeWords = (try? container.decodeIfPresent(Bool.self, forKey: .capitalizeWords)) ?? true
        includeNumber = (try? container.decodeIfPresent(Bool.self, forKey: .includeNumber)) ?? true
    }
}

public enum PasswordPreferences {
    private static let key = "aegis.password-generator.v1"
    public static func load(from defaults: UserDefaults = .standard) -> PasswordOptions {
        guard let data = defaults.data(forKey: key),
              var options = try? JSONDecoder().decode(PasswordOptions.self, from: data) else { return .init() }
        options.length = min(max(options.length, 12), 64)
        options.wordCount = min(max(options.wordCount, 4), 8)
        return options
    }

    public static func save(_ options: PasswordOptions, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        defaults.set(data, forKey: key)
    }
}

public enum PasswordGenerator {
    public static func generate(options: PasswordOptions = .init()) throws -> String {
        switch options.mode {
        case .random:
            try generateRandom(options: options)
        case .passphrase:
            try generatePassphrase(options: options)
        }
    }

    public static func generatePassphrase(options: PasswordOptions = .init()) throws -> String {
        let count = min(max(options.wordCount, 4), 10)
        let list = PassphraseWordlist.words
        var words: [String] = []
        words.reserveCapacity(count)
        for _ in 0 ..< count {
            var word = try list[randomIndex(upperBound: list.count)]
            if options.capitalizeWords, let first = word.first {
                word = first.uppercased() + word.dropFirst()
            }
            words.append(word)
        }
        if options.includeNumber {
            let slot = try randomIndex(upperBound: words.count)
            let digit = try randomIndex(upperBound: 10)
            words[slot].append(String(digit))
        }
        return words.joined(separator: options.separator.rawValue)
    }

    private static func generateRandom(options: PasswordOptions) throws -> String {
        let length = min(max(options.length, 12), 128)
        var groups = [Array("abcdefghijkmnopqrstuvwxyz")]
        if options.uppercase {
            groups.append(Array("ABCDEFGHJKLMNPQRSTUVWXYZ"))
        }
        if options.digits {
            groups.append(Array("23456789"))
        }
        if options.symbols {
            groups.append(Array("!@#$%^&*()-_=+[]{}:,.?"))
        }
        let alphabet = groups.flatMap(\.self)
        var result = try groups.map { try choose($0) }
        while result.count < length {
            try result.append(choose(alphabet))
        }
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            let target = try randomIndex(upperBound: index + 1)
            result.swapAt(index, target)
        }
        return String(result)
    }

    private static func choose(_ values: [Character]) throws -> Character {
        try values[randomIndex(upperBound: values.count)]
    }

    private static func randomIndex(upperBound: Int) throws -> Int {
        precondition(upperBound > 0)
        let bound = UInt64(upperBound)
        let range = UInt64(UInt32.max) + 1
        // Rejection sampling avoids modulo bias across arbitrary alphabet or wordlist sizes.
        let limit = range - (range % bound)
        while true {
            let bytes = try SecureRandom.bytes(count: 4)
            let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            if value < limit {
                return Int(value % bound)
            }
        }
    }
}
