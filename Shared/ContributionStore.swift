import Darwin
import Foundation
import Security

/// Settings, cached calendars and avatars, shared by the app and every widget.
///
/// Everything is stored as plain files in one folder that both the app and the
/// widget extension may use: `~/Library/Application Support/GitHub Activity`.
/// Both targets are granted it through a home-relative sandbox exception in their
/// entitlements, which (unlike an App Group) works whether or not the build is
/// signed with an Apple team. If the folder can't be used, each process falls back
/// to its own container, so widgets still remember settings between themselves.
struct ContributionStore: Sendable {
    /// Where this store reads and writes.
    let directory: URL
    /// `true` when `directory` is the folder shared by the app and the widgets.
    let isShared: Bool
    let keychain: TokenKeychain

    static let shared = ContributionStore()

    init(appGroupID: String? = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String) {
        let groupID = appGroupID.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        let location = StorageLocation.resolve()
        self.directory = location.url
        self.isShared = location.isShared
        self.keychain = TokenKeychain(accessGroup: groupID)
        migrateLegacySettings(appGroupID: groupID)
    }

    /// For tests: an isolated store in `directory`.
    init(directory: URL, keychain: TokenKeychain) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.isShared = false
        self.keychain = keychain
    }

    // MARK: Settings file

    /// The small settings file. Calendars and avatars live in their own files.
    private struct Settings: Codable {
        var username: String?
        var theme: ContributionTheme?
        var account: GitHubProfile?
        /// How many widgets carry each typed username (see `adoptUsername`).
        var widgetUsernameInputs: [String: Int] = [:]
    }

    private var settingsURL: URL { directory.appending(path: "settings.json") }
    private var lockURL: URL { directory.appending(path: ".settings.lock") }
    private var calendarsURL: URL { directory.appending(path: "calendars", directoryHint: .isDirectory) }
    private var avatarsURL: URL { directory.appending(path: "avatars", directoryHint: .isDirectory) }

    private func readSettings() -> Settings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return settings
    }

    /// Read-modify-write under a file lock, so the app and several widget
    /// processes can't overwrite each other's changes.
    @discardableResult
    private func updateSettings<T>(_ change: (inout Settings) -> T) -> T {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        if descriptor >= 0 { flock(descriptor, LOCK_EX) }
        defer {
            if descriptor >= 0 {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }
        var settings = readSettings()
        let result = change(&settings)
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
        return result
    }

    // MARK: Settings

    /// The one GitHub username every widget and the app show.
    var username: String? {
        get { readSettings().username }
        nonmutating set {
            updateSettings { $0.username = newValue.flatMap(GitHubService.normalizedLogin) }
        }
    }

    /// The theme for every widget, unless a widget picks its own in Edit Widget.
    var theme: ContributionTheme {
        get { readSettings().theme ?? .github }
        nonmutating set { updateSettings { $0.theme = newValue } }
    }

    var token: String? { keychain.read() }

    func setToken(_ token: String?) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            keychain.delete()
        } else {
            try keychain.save(trimmed)
        }
    }

    /// The GitHub account the saved token belongs to, or `nil` when not signed in.
    var account: GitHubProfile? {
        get { readSettings().account }
        nonmutating set { updateSettings { $0.account = newValue } }
    }

    // MARK: One username for every widget

    /// Applies a username someone just typed into a widget's Edit Widget panel,
    /// so every widget (and the app) shows that person from now on.
    ///
    /// Each widget keeps its own typed value and WidgetKit can't tell us which widget
    /// is which, so we remember how many widgets carry each value. A value whose count
    /// went up was just entered and becomes the username; values we've already seen
    /// are left alone, so an old entry in another widget never switches it back.
    ///
    /// - Parameter inputs: the username field of every configured widget (empty ones left out).
    /// - Returns: `true` if the shared username changed.
    @discardableResult
    func adoptUsername(fromWidgetInputs inputs: [String]) -> Bool {
        var current: [String: Int] = [:]
        for login in inputs.compactMap(GitHubService.normalizedLogin) {
            current[login.lowercased(), default: 0] += 1
        }
        return updateSettings { settings in
            let previous = settings.widgetUsernameInputs
            settings.widgetUsernameInputs = current

            let justEntered = current.filter { $0.value > previous[$0.key, default: 0] }.keys
            guard !justEntered.isEmpty else { return false }
            // Several at once (e.g. the first run with many widgets): keep the current
            // username if it's one of them, otherwise pick one predictably.
            if let username = settings.username, justEntered.contains(username.lowercased()) { return false }
            guard let chosen = justEntered.sorted().first else { return false }
            settings.username = chosen
            return true
        }
    }

    /// Forgets the account, token, username and cached data.
    func signOut() {
        keychain.delete()
        updateSettings {
            $0.account = nil
            $0.username = nil
        }
        clearCache()
    }

    // MARK: Cache

    /// The last good calendar for the saved username.
    var cachedCalendar: ContributionCalendar? {
        username.flatMap(cachedCalendar(for:))
    }

    /// The last good calendar for `login`. Kept per user, so switching back and
    /// forth between people doesn't throw data away.
    func cachedCalendar(for login: String) -> ContributionCalendar? {
        guard let data = try? Data(contentsOf: calendarFile(login)) else { return nil }
        return try? JSONDecoder().decode(ContributionCalendar.self, from: data)
    }

    func cache(_ calendar: ContributionCalendar) {
        guard let data = try? JSONEncoder().encode(calendar) else { return }
        try? FileManager.default.createDirectory(at: calendarsURL, withIntermediateDirectories: true)
        try? data.write(to: calendarFile(calendar.profile.login), options: .atomic)
    }

    /// Removes every cached calendar and avatar.
    func clearCache() {
        try? FileManager.default.removeItem(at: calendarsURL)
        try? FileManager.default.removeItem(at: avatarsURL)
    }

    private func calendarFile(_ login: String) -> URL {
        calendarsURL.appending(path: "\(login.lowercased()).json")
    }

    // MARK: Avatars

    /// The avatar's image data, if it was downloaded within the last week.
    func cachedAvatar(for login: String, maxAge: TimeInterval = 7 * 24 * 3600) -> Data? {
        let file = avatarFile(login)
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
              -modified.timeIntervalSinceNow < maxAge
        else { return nil }
        return try? Data(contentsOf: file)
    }

    func cacheAvatar(_ data: Data, for login: String) {
        try? FileManager.default.createDirectory(at: avatarsURL, withIntermediateDirectories: true)
        try? data.write(to: avatarFile(login), options: .atomic)
    }

    private func avatarFile(_ login: String) -> URL {
        avatarsURL.appending(path: "\(login.lowercased()).img")
    }

    // MARK: Migration

    /// Earlier versions kept the username in UserDefaults (the App Group suite,
    /// which unsigned widgets can't open). Copy it over once.
    private func migrateLegacySettings(appGroupID: String?) {
        guard readSettings().username == nil else { return }
        let suites = [appGroupID.flatMap(UserDefaults.init(suiteName:)), UserDefaults.standard].compactMap { $0 }
        guard let legacy = suites.lazy.compactMap({ $0.string(forKey: "username") }).first else { return }
        username = legacy
    }

    // MARK: Loading

    enum LoadResult: Sendable {
        /// Freshly fetched from GitHub (and now cached).
        case fresh(ContributionCalendar)
        /// The fetch failed; this is the last good copy for the same user.
        case cached(ContributionCalendar, GitHubError)
        case failed(GitHubError)

        var calendar: ContributionCalendar? {
            switch self {
            case .fresh(let calendar), .cached(let calendar, _): calendar
            case .failed: nil
            }
        }

        var error: GitHubError? {
            switch self {
            case .fresh: nil
            case .cached(_, let error), .failed(let error): error
            }
        }
    }

    /// Fetches a calendar (the saved user's unless `username` is given), caching it
    /// on success and falling back to the cache on failure, so the widget never goes
    /// blank when offline.
    ///
    /// - Parameter reuseIfNewerThan: skip the network when the cached copy is at
    ///   least this fresh (seconds), e.g. right after the refresh button fetched it.
    func loadCalendar(
        username: String? = nil,
        reuseIfNewerThan maxAge: TimeInterval = 0,
        using service: GitHubService = GitHubService()
    ) async -> LoadResult {
        guard let login = (username ?? self.username).flatMap(GitHubService.normalizedLogin) else {
            return .failed(.invalidUsername)
        }
        if maxAge > 0, let cached = cachedCalendar(for: login), -cached.fetchedAt.timeIntervalSinceNow < maxAge {
            return .fresh(cached)
        }
        do {
            let calendar = try await service.fetchCalendar(username: login, token: token)
            cache(calendar)
            return .fresh(calendar)
        } catch {
            let gitHubError = error as? GitHubError ?? .network(error.localizedDescription)
            if let cached = cachedCalendar(for: login) {
                return .cached(cached, gitHubError)
            }
            return .failed(gitHubError)
        }
    }
}

// MARK: - Keychain

/// Stores the GitHub token in the Keychain, shared through the App Group when possible.
struct TokenKeychain: Sendable {
    var service = "com.sharvesh300.GitHubActivity.github-token"
    var account = "default"
    /// On macOS an App Group ID doubles as a Keychain access group.
    var accessGroup: String?

    private func baseQuery(shared: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if shared, let accessGroup {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    func read() -> String? {
        for shared in [true, false] {
            var query = baseQuery(shared: shared)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data,
               let token = String(data: data, encoding: .utf8) {
                return token
            }
            if accessGroup == nil { break }
        }
        return nil
    }

    func save(_ token: String) throws {
        delete()
        let data = Data(token.utf8)
        var status = errSecMissingEntitlement
        if accessGroup != nil {
            var query = baseQuery(shared: true)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }
        // Without signing entitlements the shared keychain refuses; keep it app-local instead.
        if status == errSecMissingEntitlement {
            var query = baseQuery(shared: false)
            query[kSecValueData as String] = data
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() {
        SecItemDelete(baseQuery(shared: true) as CFDictionary)
        if accessGroup != nil { SecItemDelete(baseQuery(shared: false) as CFDictionary) }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Couldn't save the token to your Keychain. \(message)"
    }
}

// MARK: - Storage location

enum StorageLocation {
    static let folderName = "GitHub Activity"

    /// `~/Library/Application Support/GitHub Activity` in the real home folder, not
    /// inside a sandbox container. Both targets' entitlements allow this exact path.
    static var sharedFolder: URL? {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appending(path: "Library/Application Support/\(folderName)", directoryHint: .isDirectory)
    }

    /// The shared folder if this process can write to it, otherwise its own container.
    static func resolve() -> (url: URL, isShared: Bool) {
        if let shared = sharedFolder, isWritable(shared) {
            return (shared, true)
        }
        let own = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: folderName, directoryHint: .isDirectory)
        _ = isWritable(own)
        return (own, false)
    }

    /// Creates the folder and proves we can write into it. (Checking the path alone
    /// isn't enough: the sandbox may still refuse access.)
    static func isWritable(_ folder: URL) -> Bool {
        let probe = folder.appending(path: ".write-test-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }
}
