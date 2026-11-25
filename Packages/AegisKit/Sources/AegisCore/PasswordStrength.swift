import Foundation

public enum PasswordStrength {
    public enum Level: Int, Comparable, CaseIterable, Sendable {
        case weak = 0
        case fair = 1
        case good = 2
        case strong = 3

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public var title: String {
            switch self {
            case .weak: L10n.text("strength.weak")
            case .fair: L10n.text("strength.fair")
            case .good: L10n.text("strength.good")
            case .strong: L10n.text("strength.strong")
            }
        }
    }

    public enum Suggestion: String, Equatable, Sendable {
        case tooShort
        case addVariety
        case avoidRepetition
        case avoidSequence
        case avoidCommonWord

        public var message: String {
            switch self {
            case .tooShort: L10n.text("strength.hint.tooShort")
            case .addVariety: L10n.text("strength.hint.addVariety")
            case .avoidRepetition: L10n.text("strength.hint.avoidRepetition")
            case .avoidSequence: L10n.text("strength.hint.avoidSequence")
            case .avoidCommonWord: L10n.text("strength.hint.avoidCommonWord")
            }
        }
    }

    public struct Evaluation: Equatable, Sendable {
        public let level: Level
        public let score: Int
        public let estimatedBits: Double
        public let suggestions: [Suggestion]

        public init(level: Level, score: Int, estimatedBits: Double, suggestions: [Suggestion]) {
            self.level = level
            self.score = score
            self.estimatedBits = estimatedBits
            self.suggestions = suggestions
        }
    }

    private static let commonPasswords: Set<String> = [
        "123456", "12345678", "123456789", "1234567890", "000000", "111111", "654321",
        "password", "password1", "password123", "passw0rd", "p@ssword", "p@ssw0rd",
        "qwerty", "qwerty123", "qwertyuiop", "asdfgh", "asdfghjkl", "zxcvbn", "zxcvbnm",
        "admin", "admin123", "administrator", "root", "welcome", "welcome123", "letmein",
        "iloveyou", "monkey", "dragon", "sunshine", "princess", "football", "baseball",
        "abc123", "abcdef", "abcdefg", "trustno1", "master", "shadow", "superman",
        "changeme", "default", "guest", "login", "secret", "aegis", "aegis123",
    ]

    private static let keyboardRows = [
        "qwertyuiop",
        "asdfghjkl",
        "zxcvbnm",
        "1234567890",
    ]

    public static func evaluate(_ password: String) -> Evaluation {
        guard !password.isEmpty else {
            return Evaluation(level: .weak, score: 0, estimatedBits: 0, suggestions: [.tooShort])
        }

        let characters = Array(password)
        let length = characters.count
        let lower = password.lowercased()
        let stripped = lower.filter { $0.isLetter || $0.isNumber }

        var hasLower = false
        var hasUpper = false
        var hasDigit = false
        var hasSymbol = false
        var hasNonASCII = false

        for character in characters {
            if character.isASCII {
                if character.isLowercase {
                    hasLower = true
                } else if character.isUppercase {
                    hasUpper = true
                } else if character.isNumber {
                    hasDigit = true
                } else {
                    hasSymbol = true
                }
            } else {
                hasNonASCII = true
            }
        }

        var pool = 0
        if hasLower {
            pool += 26
        }
        if hasUpper {
            pool += 26
        }
        if hasDigit {
            pool += 10
        }
        if hasSymbol {
            pool += 33
        }
        if hasNonASCII {
            pool += 64
        }
        pool = max(pool, 1)

        let varietyCount = [hasLower, hasUpper, hasDigit, hasSymbol || hasNonASCII].filter(\.self).count

        // Penalize repeated characters by discounting excessive reuse.
        let uniqueCount = Set(characters).count
        let uniqueRatio = Double(uniqueCount) / Double(length)
        let hasHeavyRepetition = hasRepeatedRun(characters) || hasRepeatedPattern(lower) || (length >= 6 && uniqueRatio < 0.45)
        let hasSequence = containsSequence(lower)
        let isCommon = commonPasswords.contains(lower) || commonPasswords.contains(stripped)
        let containsCommonToken = !isCommon && commonPasswords.contains { $0.count >= 6 && lower.contains($0) }

        // Estimate character-based entropy.
        let effectiveLength: Double = if hasHeavyRepetition {
            min(Double(length), Double(uniqueCount) * 1.45)
        } else {
            Double(length)
        }
        var bits = effectiveLength * log2(Double(pool))

        // Recognize multi-word passphrases separated by spaces or punctuation so diceware-like
        // passphrases are evaluated fairly even when using mostly lowercase words.
        let words = password.split { $0.isWhitespace || "-_./:".contains($0) }.map(String.init).filter { $0.count >= 2 }
        if words.count >= 4 {
            let uniqueWords = Set(words.map { $0.lowercased() }).count
            let wordBits = Double(uniqueWords) * 10.5
                + (hasUpper ? 2.0 : 0)
                + (hasDigit ? 3.5 : 0)
                + (hasSymbol ? 2.0 : 0)
            bits = max(bits, min(bits, wordBits + 12))
            if uniqueWords >= 4, !hasHeavyRepetition, !isCommon {
                bits = max(bits, wordBits)
            }
        }

        if isCommon {
            bits = min(bits, 12)
        } else if containsCommonToken {
            bits *= 0.65
        }
        if hasSequence {
            bits *= 0.72
        }
        if hasHeavyRepetition {
            bits *= 0.72
        }
        if length < 8 {
            bits = min(bits, 28)
        }

        bits = max(0, bits)

        var suggestions: [Suggestion] = []
        if length < 12 {
            suggestions.append(.tooShort)
        }
        if isCommon || containsCommonToken {
            suggestions.append(.avoidCommonWord)
        }
        if hasHeavyRepetition {
            suggestions.append(.avoidRepetition)
        }
        if hasSequence {
            suggestions.append(.avoidSequence)
        }
        if varietyCount < 3, words.count < 4 {
            suggestions.append(.addVariety)
        }

        let level: Level = if bits < 36 || length < 8 || isCommon {
            .weak
        } else if bits < 52 {
            .fair
        } else if bits < 72 {
            .good
        } else {
            .strong
        }

        // Map 0...90 bits smoothly onto 0...100.
        let score = min(100, max(1, Int((bits / 90.0 * 100.0).rounded())))
        let trimmedSuggestions = level == .strong ? [] : Array(suggestions.prefix(2))
        return Evaluation(level: level, score: score, estimatedBits: bits, suggestions: trimmedSuggestions)
    }

    private static func hasRepeatedRun(_ characters: [Character]) -> Bool {
        guard characters.count >= 3 else { return false }
        var run = 1
        for index in 1 ..< characters.count {
            if characters[index] == characters[index - 1] {
                run += 1
                if run >= 3 {
                    return true
                }
            } else {
                run = 1
            }
        }
        return false
    }

    private static func hasRepeatedPattern(_ text: String) -> Bool {
        let chars = Array(text)
        let count = chars.count
        guard count >= 6 else { return false }
        for chunk in 2 ... min(6, count / 2) {
            var repeats = 1
            var offset = chunk
            while offset + chunk <= count {
                if chars[offset ..< (offset + chunk)] == chars[0 ..< chunk] {
                    repeats += 1
                    offset += chunk
                } else {
                    break
                }
            }
            if repeats >= 2, repeats * chunk >= count - 1 {
                return true
            }
        }
        return false
    }

    private static func containsSequence(_ lower: String) -> Bool {
        let scalars = lower.unicodeScalars.map(\.value)
        if scalars.count >= 4 {
            var asc = 1
            var desc = 1
            for index in 1 ..< scalars.count {
                let diff = Int64(scalars[index]) - Int64(scalars[index - 1])
                asc = diff == 1 ? asc + 1 : 1
                desc = diff == -1 ? desc + 1 : 1
                if asc >= 4 || desc >= 4 {
                    return true
                }
            }
        }
        for row in keyboardRows {
            let reversed = String(row.reversed())
            for candidate in [row, reversed] {
                let chars = Array(candidate)
                for start in 0 ... (chars.count - 4) {
                    let slice = String(chars[start ..< (start + 4)])
                    if lower.contains(slice) {
                        return true
                    }
                }
            }
        }
        return false
    }
}
