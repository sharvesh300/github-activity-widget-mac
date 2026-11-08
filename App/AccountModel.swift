import Observation
import WidgetKit

/// Drives the settings window: the one GitHub username every widget shows,
/// and that user's latest contributions.
///
/// Sign in with GitHub (`DeviceFlowSignIn`) is kept in the project but not offered
/// for now: public contributions only need a username.
@MainActor
@Observable
final class AccountModel {
    /// The shared username, or `nil` until someone enters one here or in a widget.
    private(set) var username: String?
    private(set) var calendar: ContributionCalendar?
    /// The theme every widget uses unless one picks its own.
    private(set) var theme: ContributionTheme
    private(set) var isRefreshing = false
    /// The last problem worth showing, cleared when something succeeds.
    private(set) var errorMessage: String?

    private let store: ContributionStore
    private let service: GitHubService
    /// Bumped by every refresh and username change, so a slow load that finishes
    /// after you've moved on is thrown away instead of overwriting the screen.
    private var refreshGeneration = 0

    init(store: ContributionStore = .shared, service: GitHubService = GitHubService()) {
        self.store = store
        self.service = service
        self.username = store.username
        self.calendar = store.cachedCalendar
        self.theme = store.theme
    }

    /// Saves the theme for every widget and redraws them.
    func setTheme(_ newTheme: ContributionTheme) {
        guard newTheme != theme else { return }
        theme = newTheme
        store.theme = newTheme
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Saves `input` as the username for the app and every widget.
    /// Returns `false` (and sets `errorMessage`) if it can't be used.
    @discardableResult
    func setUsername(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a GitHub username."
            return false
        }
        guard let login = GitHubService.normalizedLogin(trimmed) else {
            errorMessage = GitHubError.invalidUsername.localizedDescription
            return false
        }

        refreshGeneration += 1
        isRefreshing = false
        store.username = login
        username = login
        calendar = store.cachedCalendar(for: login)
        errorMessage = nil
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }

    // MARK: Refresh

    /// Refreshes when the window opens if the data is missing or older than ten minutes.
    func refreshIfStale() async {
        // A widget may have changed the username while the app was closed.
        if let saved = store.username, saved != username {
            username = saved
            calendar = store.cachedCalendar(for: saved)
        }
        if let calendar, calendar.fetchedAt.timeIntervalSinceNow > -600 { return }
        await refresh()
    }

    func refresh() async {
        guard let login = username else { return }

        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true

        let result = await store.loadCalendar(username: login, using: service)

        // The username changed or another refresh started while this was loading.
        guard generation == refreshGeneration else { return }
        isRefreshing = false
        if let fresh = result.calendar { calendar = fresh }
        errorMessage = result.error?.localizedDescription
        WidgetCenter.shared.reloadAllTimelines()
    }
}
