import AppIntents
import WidgetKit

/// What people can change from the widget's "Edit Widget" panel.
struct ContributionWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "GitHub Activity"
    static let description = IntentDescription("Show a GitHub contribution graph on your desktop.")

    @Parameter(title: "Theme", default: .github)
    var theme: ContributionTheme

    /// Empty means "whoever is connected in the app". Setting it lets one widget
    /// follow someone else, and keeps widgets working without a shared App Group.
    @Parameter(title: "GitHub username", description: "Leave empty to use the account connected in the app.")
    var username: String?

    init() {}

    init(theme: ContributionTheme, username: String? = nil) {
        self.theme = theme
        self.username = username
    }

    /// The username to show, if one was typed and it's valid.
    var overrideLogin: String? {
        username.flatMap(GitHubService.normalizedLogin)
    }
}

/// The ↻ button on the widget. Fetches fresh data; WidgetKit then reloads the
/// timeline, which reuses what this just cached instead of fetching twice.
struct RefreshContributionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Contributions"
    static let isDiscoverable = false

    @Parameter(title: "GitHub username")
    var username: String?

    init() {}

    init(username: String?) {
        self.username = username
    }

    func perform() async throws -> some IntentResult {
        _ = await ContributionStore.shared.loadCalendar(username: username)
        return .result()
    }
}

extension ContributionTheme: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Theme" }

    static var caseDisplayRepresentations: [ContributionTheme: DisplayRepresentation] {
        [
            .github: "GitHub",
            .ocean: "Ocean",
            .amber: "Amber",
            .mono: "Mono",
        ]
    }
}
