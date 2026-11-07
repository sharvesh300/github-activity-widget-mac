import AppIntents
import WidgetKit

/// What people can change from the widget's "Edit Widget" panel.
struct ContributionWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "GitHub Activity"
    static let description = IntentDescription("Show a GitHub contribution graph on your desktop.")

    @Parameter(title: "Theme", default: .github)
    var theme: ContributionTheme

    /// Typing a username here sets it for every GitHub Activity widget (and the app),
    /// and it's remembered until someone enters a different one.
    @Parameter(
        title: "GitHub username",
        description: "Used by all your GitHub Activity widgets until you enter a different one."
    )
    var username: String?

    init() {}

    init(theme: ContributionTheme, username: String? = nil) {
        self.theme = theme
        self.username = username
    }

    /// The username typed into this widget, if any and if it's valid.
    var enteredLogin: String? {
        username.flatMap(GitHubService.normalizedLogin)
    }
}

/// The ↻ button on the widget. Fetches fresh data for the shared username;
/// WidgetKit then reloads the timeline, which reuses what this just cached.
struct RefreshContributionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Contributions"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        _ = await ContributionStore.shared.loadCalendar()
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
