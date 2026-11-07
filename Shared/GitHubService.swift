import Foundation

enum GitHubError: LocalizedError, Equatable, Sendable {
    case invalidUsername
    case userNotFound(String)
    case invalidToken
    case rateLimited
    case network(String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidUsername: "That doesn't look like a GitHub username."
        case .userNotFound(let login): "No GitHub user named @\(login)."
        case .invalidToken: "Your GitHub sign-in is no longer valid. Open GitHub Activity to sign in again."
        case .rateLimited: "GitHub is rate-limiting requests. It'll retry shortly."
        case .network(let message): "Couldn't reach GitHub. \(message)"
        case .unexpectedResponse: "GitHub sent something unexpected. Try again later."
        }
    }
}

/// Fetches a user's contribution calendar.
///
/// With a token it uses the GraphQL API (exact counts, levels and optional private
/// contributions). Without one it reads the public contributions page, the same
/// HTML github.com renders on a profile.
struct GitHubService: Sendable {
    var session: URLSession = .shared

    func fetchCalendar(username: String, token: String?) async throws -> ContributionCalendar {
        guard let login = Self.normalizedLogin(username) else { throw GitHubError.invalidUsername }
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return try await fetchViaGraphQL(login: login, token: token)
        }
        return try await fetchViaPublicProfile(login: login)
    }

    // MARK: Username

    /// Accepts `sharvesh300`, `@sharvesh300` or a profile URL and returns the bare login,
    /// or `nil` if it can't be a GitHub username.
    static func normalizedLogin(_ input: String) -> String? {
        var login = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "github.com/", "@"] where login.lowercased().hasPrefix(prefix) {
            login.removeFirst(prefix.count)
        }
        login = String(login.split(whereSeparator: { "/?#".contains($0) }).first ?? "")

        // 1–39 alphanumerics or hyphens, not starting or ending with a hyphen.
        guard (1...39).contains(login.count),
              login.allSatisfy({ ($0.isASCII && $0.isLetter) || $0.isNumber || $0 == "-" }),
              !login.hasPrefix("-"), !login.hasSuffix("-")
        else { return nil }
        return login
    }

    // MARK: GraphQL

    static let graphQLQuery = """
    query($login: String!) {
      user(login: $login) {
        login
        name
        avatarUrl(size: 128)
        contributionsCollection {
          contributionCalendar {
            totalContributions
            weeks { contributionDays { date contributionCount contributionLevel } }
          }
        }
      }
    }
    """

    private func fetchViaGraphQL(login: String, token: String) async throws -> ContributionCalendar {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": Self.graphQLQuery,
            "variables": ["login": login],
        ])
        let data = try await perform(request, login: login)
        return try Self.parseGraphQL(data, login: login, fetchedAt: .now)
    }

    static func parseGraphQL(_ data: Data, login: String, fetchedAt: Date) throws -> ContributionCalendar {
        let response: GraphQLResponse
        do {
            response = try JSONDecoder().decode(GraphQLResponse.self, from: data)
        } catch {
            throw GitHubError.unexpectedResponse
        }

        guard let user = response.data?.user else {
            if response.errors?.contains(where: { $0.type == "NOT_FOUND" }) == true || response.errors == nil {
                throw GitHubError.userNotFound(login)
            }
            throw GitHubError.unexpectedResponse
        }

        let calendar = user.contributionsCollection.contributionCalendar
        let days = calendar.weeks.flatMap(\.contributionDays).compactMap { day -> ContributionDay? in
            guard let date = CalendarDay(iso: day.date) else { return nil }
            return ContributionDay(
                date: date,
                count: day.contributionCount,
                level: ContributionLevel(graphQLValue: day.contributionLevel)
            )
        }
        guard !days.isEmpty else { throw GitHubError.unexpectedResponse }

        return ContributionCalendar(
            profile: GitHubProfile(login: user.login, name: user.name, avatarURL: user.avatarUrl),
            totalContributions: calendar.totalContributions,
            days: days,
            fetchedAt: fetchedAt,
            source: .graphQL
        )
    }

    /// The account a token belongs to, used right after sign-in to fill in the username.
    func fetchViewer(token: String) async throws -> GitHubProfile {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": "query { viewer { login name avatarUrl(size: 128) } }",
        ])
        let data = try await perform(request, login: "you")
        return try Self.parseViewer(data)
    }

    static func parseViewer(_ data: Data) throws -> GitHubProfile {
        struct Response: Decodable {
            struct Payload: Decodable { let viewer: Viewer }
            struct Viewer: Decodable {
                let login: String
                let name: String?
                let avatarUrl: URL?
            }
            let data: Payload?
        }
        guard let viewer = (try? JSONDecoder().decode(Response.self, from: data))?.data?.viewer else {
            throw GitHubError.unexpectedResponse
        }
        return GitHubProfile(login: viewer.login, name: viewer.name, avatarURL: viewer.avatarUrl)
    }

    private struct GraphQLResponse: Decodable {
        struct Payload: Decodable { let user: User? }
        struct User: Decodable {
            let login: String
            let name: String?
            let avatarUrl: URL?
            let contributionsCollection: Collection
        }
        struct Collection: Decodable { let contributionCalendar: Calendar }
        struct Calendar: Decodable {
            let totalContributions: Int
            let weeks: [Week]
        }
        struct Week: Decodable { let contributionDays: [Day] }
        struct Day: Decodable {
            let date: String
            let contributionCount: Int
            let contributionLevel: String
        }
        struct GraphQLError: Decodable {
            let type: String?
            let message: String
        }

        let data: Payload?
        let errors: [GraphQLError]?
    }

    // MARK: Public contributions page

    private func fetchViaPublicProfile(login: String) async throws -> ContributionCalendar {
        var request = URLRequest(url: URL(string: "https://github.com/users/\(login)/contributions")!)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let data = try await perform(request, login: login)
        guard let html = String(data: data, encoding: .utf8) else { throw GitHubError.unexpectedResponse }
        return try Self.parseContributionsPage(html, login: login, fetchedAt: .now)
    }

    /// Parses the HTML served at `github.com/users/<login>/contributions`.
    ///
    /// Each day is a `<td data-date=… data-level=… id=…>` and its count lives in a
    /// matching `<tool-tip for=id>` ("5 contributions on …" / "No contributions on …").
    static func parseContributionsPage(_ html: String, login: String, fetchedAt: Date) throws -> ContributionCalendar {
        var countsByCellID: [String: Int] = [:]
        for match in html.matches(of: #/<tool-tip\b[^>]*\bfor="([^"]+)"[^>]*>([^<]*)</tool-tip>/#) {
            let text = match.output.2
            let count = text.firstMatch(of: #/^\s*([\d,]+)\s+contributions?\b/#)
                .flatMap { Int($0.output.1.replacing(",", with: "")) } ?? 0
            countsByCellID[String(match.output.1)] = count
        }

        var days: [ContributionDay] = []
        for match in html.matches(of: #/<td\b[^>]*\bdata-date="[^"]*"[^>]*>/#) {
            let tag = match.output
            guard let dateString = tag.firstMatch(of: #/\bdata-date="([^"]+)"/#)?.output.1,
                  let date = CalendarDay(iso: String(dateString))
            else { continue }
            let level = tag.firstMatch(of: #/\bdata-level="(\d)"/#)
                .flatMap { Int($0.output.1) }
                .flatMap(ContributionLevel.init(rawValue:)) ?? .none
            let cellID = tag.firstMatch(of: #/\bid="([^"]+)"/#).map { String($0.output.1) }
            let count = cellID.flatMap { countsByCellID[$0] } ?? (level == .none ? 0 : 1)
            days.append(ContributionDay(date: date, count: count, level: level))
        }
        guard !days.isEmpty else { throw GitHubError.unexpectedResponse }

        let headlineTotal = html.firstMatch(of: #/([\d,]+)\s+contributions?\s+in the last year/#)
            .flatMap { Int($0.output.1.replacing(",", with: "")) }

        return ContributionCalendar(
            profile: GitHubProfile(login: login),
            totalContributions: headlineTotal ?? days.reduce(0) { $0 + $1.count },
            days: days,
            fetchedAt: fetchedAt,
            source: .publicProfile
        )
    }

    // MARK: Networking

    private func perform(_ request: URLRequest, login: String) async throws -> Data {
        var request = request
        request.setValue("GitHubActivityWidget/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GitHubError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw GitHubError.unexpectedResponse }
        if let error = Self.error(forStatus: http.statusCode, login: login, remainingRateLimit: http.value(forHTTPHeaderField: "x-ratelimit-remaining")) {
            throw error
        }
        return data
    }

    /// Maps an HTTP status to the error the user should see, or `nil` for success.
    static func error(forStatus status: Int, login: String, remainingRateLimit: String? = nil) -> GitHubError? {
        switch status {
        case 200..<300: nil
        case 401: .invalidToken
        case 403 where remainingRateLimit == "0", 429: .rateLimited
        case 403: .invalidToken
        case 404: .userNotFound(login)
        default: .network("GitHub returned HTTP \(status).")
        }
    }
}
