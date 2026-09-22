import Foundation
import Observation

enum KillRule: Hashable, Identifiable {
    case phrase(String)     // matched against title
    case domain(String)     // matched against host

    var id: String { "\(kind):\(value)" }

    var value: String {
        switch self {
        case .phrase(let phrase): phrase
        case .domain(let domain): domain
        }
    }

    var kind: Kind {
        switch self {
        case .phrase: .phrase
        case .domain: .domain
        }
    }

    enum Kind: String, Codable, CaseIterable {
        case domain, phrase

        var label: String {
            switch self {
            case .domain: "Site"
            case .phrase: "Word"
            }
        }
    }

    /// Builds a normalized rule from user input, or nil if there is nothing
    /// usable in it. Domains are lowercased with any scheme, path, port and
    /// leading "www." stripped, so a pasted URL becomes its host. Phrases are
    /// lowercased with whitespace collapsed; matching tokenizes anyway, so
    /// punctuation is kept only for display.
    init?(kind: Kind, input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch kind {
        case .domain:
            var host = trimmed.lowercased()
            if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
            if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !host.isEmpty, host.contains(where: \.isLetter), !host.contains(where: \.isWhitespace) else { return nil }
            self = .domain(host)
        case .phrase:
            let phrase = trimmed.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !Killfile.tokens(phrase).isEmpty else { return nil }
            self = .phrase(phrase)
        }
    }

    /// Guesses the kind from the shape of the input: something that looks
    /// like a hostname or URL is a domain, anything else is a phrase.
    static func guessKind(for input: String) -> Kind {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") { return .domain }
        guard !trimmed.contains(where: \.isWhitespace), trimmed.contains(".") else { return .phrase }
        let labels = trimmed.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last else { return .phrase }
        return tld.allSatisfy(\.isLetter) && tld.count >= 2 ? .domain : .phrase
    }
}

/// Stored as `{"kind":"domain","value":"example.com"}` — this is what goes
/// through iCloud, so keep it obvious rather than relying on the synthesized
/// enum encoding.
extension KillRule: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)
        switch kind {
        case .phrase: self = .phrase(value)
        case .domain: self = .domain(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(value, forKey: .value)
    }
}

/// Pure matching. Rules live in `KillfileStore`; this only knows how to
/// apply them.
enum Killfile {
    static func kills(title: String, host: String, rules: [KillRule]) -> Bool {
        rules.contains { rule in
            switch rule {
            case .phrase(let phrase): phraseMatches(phrase, title: title)
            case .domain(let domain): domainMatches(domain, host: host)
            }
        }
    }

    /// Token-boundary matching, not substring matching — a substring rule of
    /// "AI" would silently kill "Ukraine" and "explain". The rule's token
    /// sequence must appear as a consecutive run in the title's tokens.
    static func phraseMatches(_ phrase: String, title: String) -> Bool {
        let ruleTokens = tokens(phrase)
        guard !ruleTokens.isEmpty else { return false }
        let titleTokens = tokens(title)
        guard titleTokens.count >= ruleTokens.count else { return false }
        for start in 0...(titleTokens.count - ruleTokens.count) {
            if Array(titleTokens[start..<(start + ruleTokens.count)]) == ruleTokens {
                return true
            }
        }
        return false
    }

    /// Suffix matching on label boundaries: "wikipedia.org" matches
    /// "en.wikipedia.org" but not "notwikipedia.org".
    static func domainMatches(_ domain: String, host: String) -> Bool {
        let ruleLabels = labels(domain)
        let hostLabels = labels(host)
        guard !ruleLabels.isEmpty, ruleLabels.count <= hostLabels.count else { return false }
        return Array(hostLabels.suffix(ruleLabels.count)) == ruleLabels
    }

    /// Lowercase, split on any non-alphanumeric character, discard empties.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    private static func labels(_ host: String) -> [String] {
        host.lowercased().split(separator: ".").map(String.init)
    }
}

// MARK: - Persistence

/// The two stores share this surface. `NSUbiquitousKeyValueStore` and
/// `UserDefaults` both already have these methods; the protocol just lets
/// tests substitute a throwaway `UserDefaults` suite for iCloud.
protocol KeyValueBacking: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueBacking {}
extension NSUbiquitousKeyValueStore: KeyValueBacking {}

/// The user's rules, kept in iCloud key-value storage (well under its 1 MB
/// cap) and mirrored to UserDefaults so the list is right on launch before
/// the first sync lands — and permanently, for people not signed in to
/// iCloud. Whole-array, last-writer-wins: fine for a list edited by one
/// person on a couple of devices.
@MainActor
@Observable
final class KillfileStore {
    static let key = "killfile.rules"

    private(set) var rules: [KillRule] = []

    private let cloud: KeyValueBacking
    private let local: KeyValueBacking
    private var observer: NSObjectProtocol?

    init(
        cloud: KeyValueBacking = NSUbiquitousKeyValueStore.default,
        local: KeyValueBacking = UserDefaults.standard
    ) {
        self.cloud = cloud
        self.local = local

        if let stored = Self.decode(cloud.data(forKey: Self.key)) {
            rules = stored
            local.set(cloud.data(forKey: Self.key), forKey: Self.key)
        } else if let stored = Self.decode(local.data(forKey: Self.key)) {
            // Rules made before iCloud was reachable (or before this build
            // existed): push them up so the other devices pick them up.
            rules = stored
            cloud.set(local.data(forKey: Self.key), forKey: Self.key)
        }

        if let cloud = cloud as? NSUbiquitousKeyValueStore {
            observer = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: cloud,
                queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated { self?.cloudDidChange(note) }
            }
            cloud.synchronize()
        }
    }

    /// Whether edits will leave this device. `ubiquityIdentityToken` is nil
    /// with no iCloud account or with iCloud Drive off for the app.
    var isCloudBacked: Bool {
        cloud is NSUbiquitousKeyValueStore && FileManager.default.ubiquityIdentityToken != nil
    }

    func contains(_ rule: KillRule) -> Bool { rules.contains(rule) }

    /// Appends unless already present. Returns false if it was a duplicate.
    @discardableResult
    func add(_ rule: KillRule) -> Bool {
        guard !rules.contains(rule) else { return false }
        rules.append(rule)
        save()
        return true
    }

    func remove(_ rule: KillRule) {
        rules.removeAll { $0 == rule }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        for index in offsets.sorted(by: >) where rules.indices.contains(index) {
            rules.remove(at: index)
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        local.set(data, forKey: Self.key)
        cloud.set(data, forKey: Self.key)
        (cloud as? NSUbiquitousKeyValueStore)?.synchronize()
    }

    private func cloudDidChange(_ note: Notification) {
        let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        guard reason != NSUbiquitousKeyValueStoreQuotaViolationChange else { return }
        let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
        guard changed.contains(Self.key) || reason == NSUbiquitousKeyValueStoreAccountChange else { return }
        guard let stored = Self.decode(cloud.data(forKey: Self.key)) else { return }
        rules = stored
        local.set(cloud.data(forKey: Self.key), forKey: Self.key)
    }

    private static func decode(_ data: Data?) -> [KillRule]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([KillRule].self, from: data)
    }
}
