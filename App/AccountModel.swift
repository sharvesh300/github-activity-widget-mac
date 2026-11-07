import AppKit
import Observation
import WidgetKit

/// Drives the settings window: signing in with GitHub, or following a public
/// profile without signing in, and refreshing the widget afterwards.
@MainActor
@Observable
final class AccountModel {
    enum State: Equatable {
        case signedOut
        case requestingCode
        case awaitingAuthorization(DeviceFlowSignIn.Code)
        /// Signed in with GitHub: exact counts from the API.
        case signedIn(GitHubProfile)
        /// No sign-in: public contributions for any username.
        case publicProfile(String)
    }

    private(set) var state: State
    private(set) var calendar: ContributionCalendar?
    private(set) var isRefreshing = false
    /// The last problem worth showing, cleared when something succeeds.
    private(set) var errorMessage: String?

    let canSignIn: Bool

    private let store: ContributionStore
    private let clientID: String?
    private var signInTask: Task<Void, Never>?

    init(store: ContributionStore = .shared, clientID: String? = DeviceFlowSignIn.configuredClientID) {
        self.store = store
        self.clientID = clientID
        self.canSignIn = clientID != nil
        self.calendar = store.cachedCalendar

        if store.token != nil, let account = store.account ?? store.username.map({ GitHubProfile(login: $0) }) {
            state = .signedIn(account)
        } else if let username = store.username {
            state = .publicProfile(username)
        } else {
            state = .signedOut
        }
    }

    // MARK: Sign in with GitHub

    func signIn() {
        guard let clientID else {
            errorMessage = DeviceFlowSignIn.Failure.notConfigured.localizedDescription
            return
        }
        signInTask?.cancel()
        errorMessage = nil
        state = .requestingCode

        signInTask = Task {
            let flow = DeviceFlowSignIn(clientID: clientID)
            do {
                let code = try await flow.requestCode()
                state = .awaitingAuthorization(code)
                copyToPasteboard(code.userCode)
                NSWorkspace.shared.open(code.verificationURL)

                let token = try await flow.waitForToken(code)
                let profile = try await GitHubService().fetchViewer(token: token)
                try store.setToken(token)
                store.account = profile
                store.username = profile.login
                state = .signedIn(profile)
                await refresh()
            } catch {
                // A cancelled attempt must not touch the state: a newer one may be running.
                guard !Task.isCancelled else { return }
                state = .signedOut
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        state = .signedOut
    }

    func copyCode() {
        if case .awaitingAuthorization(let code) = state { copyToPasteboard(code.userCode) }
    }

    func openVerificationPage() {
        if case .awaitingAuthorization(let code) = state { NSWorkspace.shared.open(code.verificationURL) }
    }

    func signOut() {
        signInTask?.cancel()
        store.signOut()
        calendar = nil
        errorMessage = nil
        state = .signedOut
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Public profile (no sign-in)

    /// Follows `input`'s public contributions, or explains why the username can't be used.
    func usePublicProfile(_ input: String) async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a GitHub username."
            return
        }
        guard let login = GitHubService.normalizedLogin(trimmed) else {
            errorMessage = GitHubError.invalidUsername.localizedDescription
            return
        }
        store.signOut()
        store.username = login
        calendar = nil
        state = .publicProfile(login)
        await refresh()
    }

    // MARK: Refresh

    /// Refreshes when the window opens if the data is missing or older than ten minutes.
    func refreshIfStale() async {
        switch state {
        case .signedIn, .publicProfile:
            if let calendar, calendar.fetchedAt.timeIntervalSinceNow > -600 { return }
            await refresh()
        default:
            return
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let result = await store.loadCalendar()
        if let fresh = result.calendar { calendar = fresh }
        errorMessage = result.error?.localizedDescription
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
