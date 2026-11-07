import AppKit
import SwiftUI
import WidgetKit

// MARK: - Entry

struct ContributionEntry: TimelineEntry {
    enum Content {
        /// Data to show. `error` is set when this is the cached copy because a refresh failed.
        case loaded(ContributionCalendar, error: GitHubError?)
        /// No username yet, in the app or any widget.
        case needsUsername
        /// Nothing cached and the fetch failed.
        case failed(GitHubError)
    }

    let date: Date
    let content: Content
    let avatar: Data?
    let theme: ContributionTheme

    static func sample(theme: ContributionTheme = .github) -> ContributionEntry {
        ContributionEntry(date: .now, content: .loaded(.sample, error: nil), avatar: nil, theme: theme)
    }
}

// MARK: - Provider

struct ContributionProvider: AppIntentTimelineProvider {
    /// Data younger than this is reused instead of fetched again.
    private static let reuseWindow: TimeInterval = 90
    private static let refreshInterval: TimeInterval = 30 * 60
    private static let retryInterval: TimeInterval = 10 * 60

    func placeholder(in context: Context) -> ContributionEntry {
        .sample()
    }

    func snapshot(for configuration: ContributionWidgetIntent, in context: Context) async -> ContributionEntry {
        // The widget gallery wants something instantly: use the cache, or the sample.
        let store = ContributionStore.shared
        guard let login = store.username, let cached = store.cachedCalendar(for: login) else {
            return .sample(theme: configuration.theme)
        }
        return ContributionEntry(
            date: .now,
            content: .loaded(cached, error: nil),
            avatar: store.cachedAvatar(for: login),
            theme: configuration.theme
        )
    }

    func timeline(for configuration: ContributionWidgetIntent, in context: Context) async -> Timeline<ContributionEntry> {
        let entry = await makeEntry(for: configuration)
        let delay: TimeInterval = switch entry.content {
        case .loaded(_, error: nil): Self.refreshInterval
        case .needsUsername: Self.refreshInterval
        case .loaded, .failed: Self.retryInterval
        }
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(delay)))
    }

    private func makeEntry(for configuration: ContributionWidgetIntent) async -> ContributionEntry {
        let store = ContributionStore.shared
        await adoptUsernameTypedIntoAnyWidget(configuration, store: store)

        // Every widget shows the one shared username.
        guard let login = store.username else {
            return ContributionEntry(date: .now, content: .needsUsername, avatar: nil, theme: configuration.theme)
        }

        let result = await store.loadCalendar(username: login, reuseIfNewerThan: Self.reuseWindow)
        let content: ContributionEntry.Content = switch result {
        case .fresh(let calendar): .loaded(calendar, error: nil)
        case .cached(let calendar, let error): .loaded(calendar, error: error)
        case .failed(let error): .failed(error)
        }

        var avatar: Data?
        if let profile = result.calendar?.profile {
            avatar = await loadAvatar(for: profile, store: store)
        }

        return ContributionEntry(date: .now, content: content, avatar: avatar, theme: configuration.theme)
    }

    /// If someone just typed a username into any widget's Edit Widget panel, make it
    /// the shared username and redraw every widget with it.
    private func adoptUsernameTypedIntoAnyWidget(_ configuration: ContributionWidgetIntent, store: ContributionStore) async {
        var inputs = await Self.usernamesTypedIntoWidgets()
        // The list can lag behind an edit that's being applied right now; count this widget's own entry.
        if let entered = configuration.enteredLogin,
           !inputs.contains(where: { $0.caseInsensitiveCompare(entered) == .orderedSame }) {
            inputs.append(entered)
        }
        if store.adoptUsername(fromWidgetInputs: inputs) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// The username field of every GitHub Activity widget on this Mac (empty ones left out).
    ///
    /// Uses the callback API: the async `currentConfigurations()` needs macOS 15.
    private static func usernamesTypedIntoWidgets() async -> [String] {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                let configurations = (try? result.get()) ?? []
                let usernames = configurations.compactMap {
                    $0.widgetConfigurationIntent(of: ContributionWidgetIntent.self)?.enteredLogin
                }
                continuation.resume(returning: usernames)
            }
        }
    }

    /// Widgets can't load images while drawing, so avatars are fetched here and cached.
    private func loadAvatar(for profile: GitHubProfile, store: ContributionStore) async -> Data? {
        if let cached = store.cachedAvatar(for: profile.login) { return cached }
        var request = URLRequest(url: profile.avatarImageURL)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              NSImage(data: data) != nil
        else { return store.cachedAvatar(for: profile.login, maxAge: .infinity) }
        store.cacheAvatar(data, for: profile.login)
        return data
    }
}

// MARK: - Widget

struct ContributionWidget: Widget {
    static let kind = "ContributionWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: ContributionWidgetIntent.self, provider: ContributionProvider()) { entry in
            ContributionWidgetView(entry: entry)
        }
        .configurationDisplayName("GitHub Activity")
        .description("Your contribution graph and streak, updated through the day.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main
struct GitHubActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContributionWidget()
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    ContributionWidget()
} timeline: {
    ContributionEntry.sample()
    ContributionEntry.sample(theme: .ocean)
}

#Preview("Medium", as: .systemMedium) {
    ContributionWidget()
} timeline: {
    ContributionEntry.sample()
    ContributionEntry(date: .now, content: .loaded(.sample, error: .network("Offline")), avatar: nil, theme: .amber)
}

#Preview("Large", as: .systemLarge) {
    ContributionWidget()
} timeline: {
    ContributionEntry.sample()
    ContributionEntry(date: .now, content: .needsUsername, avatar: nil, theme: .github)
}

#Preview("Extra large", as: .systemExtraLarge) {
    ContributionWidget()
} timeline: {
    ContributionEntry.sample()
    ContributionEntry(date: .now, content: .failed(.userNotFound("nobody")), avatar: nil, theme: .mono)
}
