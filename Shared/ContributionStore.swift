import Foundation
import Security

/// Settings and the last good calendar, shared by the app and the widget.
///
/// Everything lives in the App Group, so the widget sees what the app saves. If the
/// App Group isn't available (for example an unsigned debug build) it falls back
/// to the process's own storage, and the widget can still work on its own.
struct ContributionStore: @unchecked Sendable {
    // UserDefaults is thread-safe; it just isn't annotated Sendable in every SDK.
    private let defaults: UserDefaults
    let appGroupID: String?
    let keychain: TokenKeychain

    /// Whether the App Group container is reachable (both targets signed with the same team).
    let isSharedWithWidget: Bool

    private enum Key {
        static let username = "username"
        static let cachedCalendar = "cachedCalendar"
    }

    static let shared = ContributionStore()

    init(appGroupID: String? = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String) {
        let groupID = appGroupID.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        let hasContainer = groupID.map {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
        } ?? false

        self.appGroupID = groupID
        self.isSharedWithWidget = hasContainer
        self.defaults = (hasContainer ? groupID.flatMap(UserDefaults.init(suiteName:)) : nil) ?? .standard
        self.keychain = TokenKeychain(accessGroup: hasContainer ? groupID : nil)
    }

    /// For tests: an isolated store backed by the given defaults.
    init(defaults: UserDefaults, keychain: TokenKeychain) {
        self.defaults = defaults
        self.appGroupID = nil
        self.isSharedWithWidget = false
        self.keychain = keychain
    }

    // MARK: Settings

    var username: String? {
        get { defaults.string(forKey: Key.username) }
        nonmutating set {
            if let value = newValue.flatMap(GitHubService.normalizedLogin) {
                defaults.set(value, forKey: Key.username)
            } else {
                defaults.removeObject(forKey: Key.username)
            }
        }
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

    // MARK: Cache

    var cachedCalendar: ContributionCalendar? {
        guard let data = defaults.data(forKey: Key.cachedCalendar) else { return nil }
        return try? JSONDecoder().decode(ContributionCalendar.self, from: data)
    }

    func cache(_ calendar: ContributionCalendar) {
        guard let data = try? JSONEncoder().encode(calendar) else { return }
        defaults.set(data, forKey: Key.cachedCalendar)
    }

    func clearCache() {
        defaults.removeObject(forKey: Key.cachedCalendar)
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

    /// Fetches the saved user's calendar, caching it on success and falling back
    /// to the cache on failure, so the widget never goes blank when offline.
    func loadCalendar(username: String? = nil, using service: GitHubService = GitHubService()) async -> LoadResult {
        guard let login = (username ?? self.username).flatMap(GitHubService.normalizedLogin) else {
            return .failed(.invalidUsername)
        }
        do {
            let calendar = try await service.fetchCalendar(username: login, token: token)
            cache(calendar)
            return .fresh(calendar)
        } catch {
            let gitHubError = error as? GitHubError ?? .network(error.localizedDescription)
            if let cached = cachedCalendar, cached.profile.login.caseInsensitiveCompare(login) == .orderedSame {
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
