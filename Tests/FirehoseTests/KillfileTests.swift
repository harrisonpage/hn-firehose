import XCTest
@testable import Firehose

/// The killfile is the one place where bugs are silent — a bad rule quietly
/// eats stories the user never learns existed.
final class KillfileTests: XCTestCase {

    // MARK: Phrase matching — token boundaries, not substrings

    func testMultiTokenPhraseMatchesConsecutiveRun() {
        XCTAssertTrue(Killfile.phraseMatches("machine learning", title: "New machine learning benchmark"))
    }

    func testMultiTokenPhraseRequiresConsecutiveTokens() {
        XCTAssertFalse(Killfile.phraseMatches("machine learning", title: "learning about machine tools"))
        XCTAssertFalse(Killfile.phraseMatches("machine learning", title: "machine deep learning"))
    }

    func testSingleTokenPhraseDoesNotMatchSubstrings() {
        XCTAssertTrue(Killfile.phraseMatches("AI", title: "AI startup raises"))
        XCTAssertFalse(Killfile.phraseMatches("AI", title: "Ukraine ceasefire talks resume"))
        XCTAssertFalse(Killfile.phraseMatches("AI", title: "He said it plainly"))
        XCTAssertFalse(Killfile.phraseMatches("AI", title: "How to explain chain reactions"))
    }

    func testPhraseMatchingIsCaseInsensitive() {
        XCTAssertTrue(Killfile.phraseMatches("BITCOIN", title: "bitcoin hits new low"))
        XCTAssertTrue(Killfile.phraseMatches("bitcoin", title: "BITCOIN HITS NEW LOW"))
    }

    func testPunctuationActsAsTokenBoundary() {
        XCTAssertTrue(Killfile.phraseMatches("AI", title: "AI: the next platform"))
        XCTAssertTrue(Killfile.phraseMatches("AI", title: "The problem with (AI) agents"))
    }

    func testRuleWithPunctuationTokenizesLikeTitles() {
        XCTAssertTrue(Killfile.phraseMatches("node.js", title: "Node.js 22 released"))
        XCTAssertTrue(Killfile.phraseMatches("node.js", title: "Why node js still matters"))
    }

    func testPhraseAtTitleEdges() {
        XCTAssertTrue(Killfile.phraseMatches("show hn", title: "Show HN: a tiny thing"))
        XCTAssertTrue(Killfile.phraseMatches("rust", title: "Rewritten in Rust"))
    }

    func testEmptyAndDegenerateInputs() {
        XCTAssertFalse(Killfile.phraseMatches("", title: "Anything at all"))
        XCTAssertFalse(Killfile.phraseMatches("...", title: "Anything at all"))
        XCTAssertFalse(Killfile.phraseMatches("rust", title: ""))
        XCTAssertFalse(Killfile.phraseMatches("one two three", title: "one two"))
    }

    // MARK: Domain matching — suffix on label boundaries

    func testDomainMatchesExactHost() {
        XCTAssertTrue(Killfile.domainMatches("wikipedia.org", host: "wikipedia.org"))
    }

    func testDomainMatchesSubdomains() {
        XCTAssertTrue(Killfile.domainMatches("wikipedia.org", host: "en.wikipedia.org"))
        XCTAssertTrue(Killfile.domainMatches("wikipedia.org", host: "en.m.wikipedia.org"))
    }

    func testDomainDoesNotMatchLabelSubstrings() {
        XCTAssertFalse(Killfile.domainMatches("wikipedia.org", host: "notwikipedia.org"))
    }

    func testDomainSuffixMustAlignToLabelBoundaries() {
        XCTAssertFalse(Killfile.domainMatches("wikipedia.org", host: "wikipedia.org.evil.com"))
        XCTAssertFalse(Killfile.domainMatches("wikipedia.org", host: "org"))
    }

    func testBareTLDRuleMatchesBroadly() {
        // A rule of "com" matching nearly everything is the developer's
        // problem, not a bug to guard against.
        XCTAssertTrue(Killfile.domainMatches("com", host: "example.com"))
        XCTAssertFalse(Killfile.domainMatches("com", host: "example.org"))
    }

    func testDomainMatchingIsCaseInsensitive() {
        XCTAssertTrue(Killfile.domainMatches("Wikipedia.ORG", host: "en.wikipedia.org"))
    }

    func testEmptyDomainRuleMatchesNothing() {
        XCTAssertFalse(Killfile.domainMatches("", host: "example.com"))
    }

    // MARK: Rule dispatch

    func testKillsChecksBothRuleTypes() {
        let rules: [KillRule] = [.domain("wikipedia.org"), .phrase("bitcoin")]
        XCTAssertTrue(Killfile.kills(title: "History of the semicolon", host: "en.wikipedia.org", rules: rules))
        XCTAssertTrue(Killfile.kills(title: "Bitcoin hits new low", host: "example.com", rules: rules))
        XCTAssertFalse(Killfile.kills(title: "History of the semicolon", host: "example.com", rules: rules))
        XCTAssertFalse(Killfile.kills(title: "History of the semicolon", host: "en.wikipedia.org", rules: []))
    }

    // MARK: Rule construction from user input

    func testDomainInputIsNormalizedToHost() {
        XCTAssertEqual(KillRule(kind: .domain, input: "  WWW.Example.com  "), .domain("example.com"))
        XCTAssertEqual(KillRule(kind: .domain, input: "https://www.example.com/path?q=1"), .domain("example.com"))
        XCTAssertEqual(KillRule(kind: .domain, input: "example.com:8080"), .domain("example.com"))
        XCTAssertEqual(KillRule(kind: .domain, input: "en.wikipedia.org"), .domain("en.wikipedia.org"))
    }

    func testDomainInputRejectsGarbage() {
        XCTAssertNil(KillRule(kind: .domain, input: ""))
        XCTAssertNil(KillRule(kind: .domain, input: "   "))
        XCTAssertNil(KillRule(kind: .domain, input: "..."))
        XCTAssertNil(KillRule(kind: .domain, input: "two words.com"))
    }

    func testPhraseInputIsLowercasedAndCollapsed() {
        XCTAssertEqual(KillRule(kind: .phrase, input: "  Machine   Learning "), .phrase("machine learning"))
        XCTAssertNil(KillRule(kind: .phrase, input: "!!!"))
        XCTAssertNil(KillRule(kind: .phrase, input: ""))
    }

    func testKindGuessing() {
        XCTAssertEqual(KillRule.guessKind(for: "example.com"), .domain)
        XCTAssertEqual(KillRule.guessKind(for: "https://example.com/x"), .domain)
        XCTAssertEqual(KillRule.guessKind(for: "en.wikipedia.org"), .domain)
        XCTAssertEqual(KillRule.guessKind(for: "machine learning"), .phrase)
        XCTAssertEqual(KillRule.guessKind(for: "rust"), .phrase)
        XCTAssertEqual(KillRule.guessKind(for: "web 3.0"), .phrase)
    }

    // MARK: Codable

    func testRulesRoundTripThroughJSON() throws {
        let rules: [KillRule] = [.domain("example.com"), .phrase("machine learning")]
        let data = try JSONEncoder().encode(rules)
        XCTAssertEqual(try JSONDecoder().decode([KillRule].self, from: data), rules)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""kind":"domain""#), json)
        XCTAssertTrue(json.contains(#""value":"example.com""#), json)
    }

    // MARK: Store

    @MainActor
    func testStorePersistsToBothBackings() throws {
        let suite = "KillfileTests.\(UUID().uuidString)"
        let cloud = try XCTUnwrap(UserDefaults(suiteName: suite + ".cloud"))
        let local = try XCTUnwrap(UserDefaults(suiteName: suite + ".local"))
        defer {
            cloud.removePersistentDomain(forName: suite + ".cloud")
            local.removePersistentDomain(forName: suite + ".local")
        }

        let store = KillfileStore(cloud: cloud, local: local)
        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertTrue(store.add(.domain("example.com")))
        XCTAssertFalse(store.add(.domain("example.com")), "duplicates are ignored")
        store.add(.phrase("rust"))
        XCTAssertEqual(store.rules, [.domain("example.com"), .phrase("rust")])

        // A fresh store over the same backings sees the same rules.
        XCTAssertEqual(KillfileStore(cloud: cloud, local: local).rules, store.rules)

        store.remove(.domain("example.com"))
        XCTAssertEqual(store.rules, [.phrase("rust")])
        store.remove(atOffsets: IndexSet(integer: 0))
        XCTAssertTrue(store.rules.isEmpty)
    }

    @MainActor
    func testStorePrefersCloudAndPushesLocalUp() throws {
        let suite = "KillfileTests.\(UUID().uuidString)"
        let cloud = try XCTUnwrap(UserDefaults(suiteName: suite + ".cloud"))
        let local = try XCTUnwrap(UserDefaults(suiteName: suite + ".local"))
        defer {
            cloud.removePersistentDomain(forName: suite + ".cloud")
            local.removePersistentDomain(forName: suite + ".local")
        }

        // Only local has data: it seeds the cloud.
        local.set(try JSONEncoder().encode([KillRule.phrase("local")]), forKey: KillfileStore.key)
        XCTAssertEqual(KillfileStore(cloud: cloud, local: local).rules, [.phrase("local")])
        XCTAssertNotNil(cloud.data(forKey: KillfileStore.key))

        // Both have data: cloud wins and overwrites local.
        cloud.set(try JSONEncoder().encode([KillRule.phrase("cloud")]), forKey: KillfileStore.key)
        XCTAssertEqual(KillfileStore(cloud: cloud, local: local).rules, [.phrase("cloud")])
        XCTAssertEqual(
            try JSONDecoder().decode([KillRule].self, from: XCTUnwrap(local.data(forKey: KillfileStore.key))),
            [.phrase("cloud")]
        )
    }

    // MARK: Tokenizer

    func testTokenizerSplitsOnNonAlphanumerics() {
        XCTAssertEqual(Killfile.tokens("Node.js 22 — what's new?"), ["node", "js", "22", "what", "s", "new"])
        XCTAssertEqual(Killfile.tokens("  "), [])
    }
}
