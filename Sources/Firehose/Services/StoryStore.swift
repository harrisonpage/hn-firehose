import Foundation
import Observation

@MainActor
@Observable
final class StoryStore {
    enum LoadState {
        case cold           // nothing loaded yet — skeleton rows
        case loaded
        case refreshFailed  // offline banner; any loaded rows stay visible
        case pageFailed     // footer retry; loaded rows unaffected
    }

    /// What the list shows: `accepted` minus whatever the killfile eats.
    private(set) var stories: [Story] = []
    /// Stories the killfile removed from `accepted`.
    private(set) var hiddenCount = 0
    private(set) var loadState: LoadState = .cold
    private(set) var lastSuccessfulRefresh: Date?

    /// Ticked periodically so relative ages re-render.
    var now = Date()

    let metadata = MetadataCache()
    let killfile: KillfileStore

    private let client = AlgoliaClient()
    /// Every story that survived URL/title validation and dedup, killfile or
    /// not, so a rule change can be applied without refetching.
    private var accepted: [Story] = []
    private var loadedIDs = Set<String>()
    /// Smallest created_at_i across all raw hits seen (including dropped
    /// ones), so the cursor always advances even through pages the killfile
    /// eats entirely.
    private var cursor: Int?
    private var lastPageWasFull = false
    private var isLoadingOlder = false

    /// If filtering leaves too few rows to scroll, the scroll-triggered
    /// pagination can never fire — below this count we fetch more eagerly.
    private static let minimumScrollableCount = 25

    init(killfile: KillfileStore) {
        self.killfile = killfile
    }

    /// Pull-to-refresh and cold load: discard everything and refetch page one
    /// from scratch. On failure the previously loaded rows are kept and the
    /// offline banner shows. An empty response is treated as a failure — the
    /// API always returns stories.
    func refresh() async {
        do {
            let hits = try await client.fetchPage()
            guard !hits.isEmpty else { throw URLError(.badServerResponse) }
            accepted.removeAll()
            loadedIDs.removeAll()
            cursor = nil
            metadata.clear()
            ingest(hits)
            lastSuccessfulRefresh = Date()
            now = Date()
            loadState = .loaded
            await topUpIfNeeded()
        } catch {
            loadState = .refreshFailed
        }
    }

    func loadOlder() async {
        guard !isLoadingOlder, let cursor, loadState != .cold else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let hits = try await client.fetchPage(olderThan: cursor)
            ingest(hits)
            now = Date()
            if loadState == .pageFailed { loadState = .loaded }
            await topUpIfNeeded()
        } catch {
            loadState = .pageFailed
        }
    }

    func shouldLoadOlder(after story: Story) -> Bool {
        guard let index = stories.lastIndex(of: story) else { return false }
        return index >= stories.count - 20
    }

    private func ingest(_ hits: [AlgoliaHit]) {
        lastPageWasFull = hits.count >= 200
        for hit in hits {
            if let oldest = cursor {
                cursor = min(oldest, hit.created_at_i)
            } else {
                cursor = hit.created_at_i
            }
            guard let story = Story(hit: hit) else { continue }
            guard !loadedIDs.contains(story.id) else { continue }
            loadedIDs.insert(story.id)
            accepted.append(story)
        }
        // Algolia's ordering (newest first) is preserved: appends only.
        applyKillfile()
    }

    /// Re-derives the visible list from `accepted`. Called after every
    /// ingest and whenever the rules change, so muting a site from the
    /// context menu takes effect on rows already on screen.
    func applyKillfile() {
        let rules = killfile.rules
        let visible = accepted.filter { !Killfile.kills(title: $0.title, host: $0.host, rules: rules) }
        hiddenCount = accepted.count - visible.count
        if visible != stories { stories = visible }
    }

    private func topUpIfNeeded() async {
        var guardrail = 5
        while stories.count < Self.minimumScrollableCount, lastPageWasFull, guardrail > 0, let cursor {
            guardrail -= 1
            guard let hits = try? await client.fetchPage(olderThan: cursor) else { break }
            ingest(hits)
        }
    }
}
