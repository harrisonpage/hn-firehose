import SafariServices
import SwiftUI

struct StoryListView: View {
    @State private var killfile: KillfileStore
    @State private var store: StoryStore
    @State private var showAbout = false
    @State private var showKillfile = false
    @State private var safariItem: SafariItem?
    @State private var toast: String?
    @State private var toastDismissal: Task<Void, Never>?

    @Environment(\.openURL) private var openURL

    private let ageTick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    init() {
        let killfile = KillfileStore()
        _killfile = State(initialValue: killfile)
        _store = State(initialValue: StoryStore(killfile: killfile))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            main
                .blur(radius: showAbout ? 5 : 0)
            if showAbout {
                AboutPanel { showAbout = false }
            }
            if let toast {
                toastView(toast)
            }
        }
        .background(Theme.ground.ignoresSafeArea())
        .task { await store.refresh() }
        .onReceive(ageTick) { store.now = $0 }
        .onChange(of: killfile.rules) { store.applyKillfile() }
        .sheet(isPresented: $showKillfile) {
            KillfileView(
                killfile: killfile,
                hiddenCount: store.hiddenCount,
                loadedCount: store.stories.count + store.hiddenCount
            ) { showKillfile = false }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $safariItem) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 0.15), value: showAbout)
        .preferredColorScheme(nil)
    }

    private var main: some View {
        VStack(spacing: 0) {
            header
            if store.loadState == .refreshFailed {
                OfflineBanner(lastRefresh: store.lastSuccessfulRefresh) {
                    Task { await store.refresh() }
                }
            }
            content
        }
    }

    // MARK: Header — 36pt, flush left, bottom rule 2px

    private var header: some View {
        HStack(spacing: 8) {
            Text("HN FIREHOSE")
                .font(Theme.wordmark)
                .kerning(2.4)
                .foregroundStyle(Theme.headerInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(Version.version)/\(Version.build)")
                .font(Theme.stamp)
                .kerning(0.66)
                .foregroundStyle(Theme.headerInk)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                showKillfile = true
            } label: {
                Image(systemName: store.hiddenCount > 0 ? "eye.slash.fill" : "eye.slash")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.headerInk)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Killfile")
            Button {
                showAbout = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.headerInk)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(Theme.headerFill.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.headerRule).frame(height: 2)
        }
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if store.loadState == .cold {
            SkeletonList()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.stories) { story in
                        row(for: story)
                    }
                    if store.loadState == .pageFailed {
                        PaginationFailureFooter {
                            Task { await store.loadOlder() }
                        }
                    }
                }
            }
            .refreshable { await store.refresh() }
            .opacity(store.loadState == .refreshFailed ? 0.55 : 1)
        }
    }

    private func row(for story: Story) -> some View {
        StoryRow(story: story, now: store.now)
            .onTapGesture { safariItem = SafariItem(url: story.url) }
            .contextMenu {
                menuItems(for: story)
            } preview: {
                UnfurlCard(story: story, metadata: store.metadata)
            }
            .onAppear {
                if store.shouldLoadOlder(after: story) {
                    Task { await store.loadOlder() }
                }
            }
    }

    @ViewBuilder
    private func menuItems(for story: Story) -> some View {
        if SSReadingList.default() != nil, SSReadingList.supportsURL(story.url) {
            Button {
                // Fire-and-forget: addItem has no completion callback.
                try? SSReadingList.default()?.addItem(with: story.url, title: story.title, previewText: nil)
                showToast("Added to Reading List")
            } label: {
                Label("Add to Reading List", systemImage: "eyeglasses")
            }
        }
        Button {
            UIPasteboard.general.url = story.url
        } label: {
            Label("Copy Link", systemImage: "link")
        }
        ShareLink(item: story.url) {
            Label("Share…", systemImage: "square.and.arrow.up")
        }
        Button {
            openURL(story.url)  // real Safari, leaves the app
        } label: {
            Label("Open in Safari", systemImage: "safari")
        }
        Divider()
        Button {
            killfile.add(.domain(story.host))
            showToast("Hiding \(story.host)")
        } label: {
            Label("Hide \(story.host)", systemImage: "eye.slash")
        }
    }

    // MARK: Toast

    private func showToast(_ message: String) {
        toastDismissal?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        toastDismissal = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { toast = nil }
        }
    }

    private func toastView(_ message: String) -> some View {
        Text(message)
            .font(Theme.meta)
            .foregroundStyle(Theme.headerInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.headerFill, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 24)
            .transition(.opacity)
    }
}

private struct SafariItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Offline banner

/// Inline under the header, never a modal. Cached rows stay visible below.
private struct OfflineBanner: View {
    let lastRefresh: Date?
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Offline — showing \(timeLabel)")
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.bannerTitle)
                Text("Last refresh failed.")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.bannerBody)
            }
            Spacer(minLength: 8)
            Button(action: retry) {
                Text("Retry")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.bannerAction)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .border(Theme.bannerAction, width: 2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bannerFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.accent).frame(height: 2)
        }
    }

    private var timeLabel: String {
        guard let lastRefresh else { return "nothing" }
        return lastRefresh.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Pagination failure footer

private struct PaginationFailureFooter: View {
    let retry: () -> Void

    var body: some View {
        HStack {
            Text("Couldn't load older stories.")
                .font(Theme.meta)
                .foregroundStyle(Theme.metaGrey)
            Spacer(minLength: 8)
            Button(action: retry) {
                Text("Try again")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .border(Theme.ink, width: 2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 24)
    }
}

// MARK: - Skeleton

/// Cold load: six rows at the real row rhythm, never a spinner.
private struct SkeletonList: View {
    private static let widths: [(CGFloat, CGFloat, CGFloat)] = [
        (0.95, 0.74, 0.42), (0.85, 0.90, 0.57), (0.78, 0.81, 0.39),
        (0.92, 0.76, 0.51), (0.88, 0.83, 0.44), (0.80, 0.95, 0.48),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { index in
                row(Self.widths[index])
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ widths: (CGFloat, CGFloat, CGFloat)) -> some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                bar(Theme.skeletonHeadline, width: geometry.size.width * widths.0, height: 11)
                    .padding(.bottom, 8)
                bar(Theme.skeletonHeadline, width: geometry.size.width * widths.1, height: 11)
                    .padding(.bottom, 12)
                bar(Theme.skeletonMeta, width: geometry.size.width * widths.2, height: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .frame(height: 76)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rowRule).frame(height: 2)
        }
    }

    private func bar(_ color: Color, width: CGFloat, height: CGFloat) -> some View {
        Rectangle().fill(color).frame(width: width, height: height)
    }
}
