import Foundation

public struct PasswordOptions: Codable, Equatable, Sendable {
    public var length = 16
    public var uppercase = true
    public var digits = true
    public var symbols = true
    public init() {}
}

public enum PasswordPreferences {
    private static let key = "aegis.password-generator.v1"
    public static func load(from defaults: UserDefaults = .standard) -> PasswordOptions {
        guard let data = defaults.data(forKey: key),
              var options = try? JSONDecoder().decode(PasswordOptions.self, from: data) else { return .init() }
        options.length = min(max(options.length, 12), 64)
        return options
    }
    public static func save(_ options: PasswordOptions, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        defaults.set(data, forKey: key)
    }
}

public enum PasswordGenerator {
    public static func generate(options: PasswordOptions = .init()) throws -> String {
        let length = min(max(options.length, 12), 128)
        var groups = [Array("abcdefghijkmnopqrstuvwxyz")]
        if options.uppercase { groups.append(Array("ABCDEFGHJKLMNPQRSTUVWXYZ")) }
        if options.digits { groups.append(Array("23456789")) }
        if options.symbols { groups.append(Array("!@#$%^&*()-_=+[]{}:,.?")) }
        let alphabet = groups.flatMap { $0 }
        var result = try groups.map { try choose($0) }
        while result.count < length { result.append(try choose(alphabet)) }
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            let target = try randomIndex(upperBound: index + 1)
            result.swapAt(index, target)
        }
        return String(result)
    }

    private static func choose(_ values: [Character]) throws -> Character {
        values[try randomIndex(upperBound: values.count)]
    }
    private static func randomIndex(upperBound: Int) throws -> Int {
        // Rejection sampling avoids modulo bias.
        let limit = 256 - 256 % upperBound
        while true {
            let byte = Int(try SecureRandom.bytes(count: 1)[0])
            if byte < limit { return byte % upperBound }
        }
    }
}
