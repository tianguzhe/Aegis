import Foundation

public enum DomainMatchRank: Int, Comparable, Sendable {
    case none = 0
    case registrableDomain = 1
    case exactHost = 2

    public static func < (lhs: DomainMatchRank, rhs: DomainMatchRank) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Matches login websites against AutoFill service identifiers, supporting exact hosts,
/// subdomains via eTLD+1 registrable domains, and reverse-DNS Apple bundle identifiers.
public enum DomainMatcher {
    /// Common multi-part public suffixes and shared hosting domains where the third-level label
    /// owns a distinct site (so `alice.github.io` will not match `bob.github.io`).
    private static let multiPartSuffixes: Set<String> = [
        // Country-code second-level domains
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.hk", "org.hk", "edu.hk", "gov.hk", "net.hk",
        "com.tw", "org.tw", "edu.tw", "gov.tw", "net.tw", "idv.tw",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ed.jp", "gr.jp",
        "co.kr", "or.kr", "go.kr", "ac.kr", "ne.kr",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.nz", "org.nz", "net.nz", "govt.nz", "ac.nz",
        "com.sg", "org.sg", "edu.sg", "gov.sg", "net.sg",
        "com.my", "net.my", "org.my", "gov.my", "edu.my",
        "com.br", "org.br", "net.br", "gov.br", "edu.br",
        "com.mx", "org.mx", "gob.mx", "edu.mx",
        "com.ar", "org.ar", "gob.ar", "edu.ar",
        "co.in", "org.in", "net.in", "gov.in", "ac.in", "firm.in",
        "co.za", "org.za", "gov.za", "ac.za",
        "co.il", "org.il", "ac.il", "gov.il",
        "com.tr", "org.tr", "gov.tr", "edu.tr",
        "com.ua", "org.ua", "gov.ua", "edu.ua",
        "com.vn", "org.vn", "gov.vn", "edu.vn",
        "com.ph", "org.ph", "gov.ph", "edu.ph",
        "co.id", "or.id", "go.id", "ac.id",
        "co.th", "or.th", "go.th", "ac.th",
        "com.sa", "org.sa", "gov.sa", "edu.sa",
        "com.eg", "org.eg", "gov.eg", "edu.eg",
        "com.pl", "net.pl", "org.pl", "gov.pl",
        "com.es", "org.es", "gob.es", "edu.es",
        "com.ru", "org.ru", "net.ru",
        "eu.org",
        // Shared hosting suffixes (each tenant is its own security boundary)
        "github.io", "gitlab.io", "pages.dev", "workers.dev",
        "vercel.app", "netlify.app", "herokuapp.com", "appspot.com",
        "azurewebsites.net", "cloudfront.net", "s3.amazonaws.com",
        "fly.dev", "railway.app", "onrender.com", "firebaseapp.com", "web.app",
    ]

    private static let reverseDNSTLDs: Set<String> = [
        "com", "org", "net", "io", "app", "dev", "co", "ai", "me", "tv", "cc",
        "cn", "jp", "uk", "de", "fr", "au", "ca", "sg", "hk", "tw", "kr", "eu",
        "edu", "gov", "mil", "int", "xyz", "tech", "cloud", "info", "biz",
    ]

    public static func normalizedHost(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var host = URL(string: candidate)?.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host.isEmpty ? nil : host
    }

    public static func registrableDomain(for host: String) -> String? {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !lower.isEmpty, !isIPAddress(lower) else { return nil }
        let labels = lower.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if labels.count >= 3 {
            let lastThree = labels.suffix(3).joined(separator: ".")
            if multiPartSuffixes.contains(lastThree) {
                return labels.count >= 4 ? labels.suffix(4).joined(separator: ".") : nil
            }
            if multiPartSuffixes.contains(lastTwo) {
                return labels.suffix(3).joined(separator: ".")
            }
        } else if multiPartSuffixes.contains(lastTwo) {
            return nil
        }
        return lastTwo
    }

    /// Extracts forward domain candidates from a service identifier, including reverse-DNS iOS/macOS
    /// bundle IDs such as `com.example.client` -> `example.com`.
    public static func serviceHosts(from identifier: String) -> [String] {
        guard let host = normalizedHost(from: identifier) else { return [] }
        var hosts = [host]
        let labels = host.split(separator: ".").map(String.init)
        // Reverse-DNS bundle IDs start with a TLD (e.g. `com.apple.Safari` or `uk.co.bbc.news`).
        if labels.count >= 2, !identifier.contains("://"), !identifier.contains("/"),
           reverseDNSTLDs.contains(labels[0]), !reverseDNSTLDs.contains(labels.last ?? "")
        {
            let reversed = labels.reversed().joined(separator: ".")
            if let domain = registrableDomain(for: reversed) {
                hosts.append(domain)
            } else {
                hosts.append(reversed)
            }
        }
        return hosts
    }

    public static func rank(website: String, against services: [String]) -> DomainMatchRank {
        guard let itemHost = normalizedHost(from: website) else { return .none }
        let itemDomain = registrableDomain(for: itemHost)
        var best: DomainMatchRank = .none

        for service in services {
            let candidates = serviceHosts(from: service)
            for (index, serviceHost) in candidates.enumerated() {
                if index == 0, itemHost == serviceHost {
                    return .exactHost
                }
                if best < .registrableDomain,
                   let itemDomain,
                   let serviceDomain = registrableDomain(for: serviceHost),
                   itemDomain == serviceDomain
                {
                    best = .registrableDomain
                }
            }
        }
        return best
    }

    public static func sortCredentials(_ credentials: [AutoFillCredential], for services: [String]) -> [AutoFillCredential] {
        credentials.sorted { lhs, rhs in
            let leftRank = rank(website: lhs.website, against: services)
            let rightRank = rank(website: rhs.website, against: services)
            if leftRank != rightRank {
                return leftRank > rightRank
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") {
            return true
        }
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let byte = UInt8(part) else { return false }
            return String(byte) == part
        }
    }
}
