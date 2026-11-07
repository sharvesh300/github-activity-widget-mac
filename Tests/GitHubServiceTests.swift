import Foundation
import Testing
@testable import GitHubActivity

// MARK: - Fixtures (trimmed copies of real GitHub responses)

private let graphQLFixture = Data("""
{
  "data": {
    "user": {
      "login": "sharvesh300",
      "name": "Sharvesh Sivagnanam",
      "avatarUrl": "https://avatars.githubusercontent.com/u/86187069?s=128&v=4",
      "contributionsCollection": {
        "contributionCalendar": {
          "totalContributions": 14,
          "weeks": [
            { "contributionDays": [
              { "date": "2026-10-28", "contributionCount": 0, "contributionLevel": "NONE" },
              { "date": "2026-10-29", "contributionCount": 3, "contributionLevel": "FIRST_QUARTILE" },
              { "date": "2026-10-30", "contributionCount": 4, "contributionLevel": "SECOND_QUARTILE" },
              { "date": "2026-10-31", "contributionCount": 1, "contributionLevel": "FIRST_QUARTILE" }
            ] },
            { "contributionDays": [
              { "date": "2026-11-01", "contributionCount": 2, "contributionLevel": "FIRST_QUARTILE" },
              { "date": "2026-11-02", "contributionCount": 0, "contributionLevel": "NONE" },
              { "date": "2026-11-03", "contributionCount": 0, "contributionLevel": "NONE" },
              { "date": "2026-11-04", "contributionCount": 1, "contributionLevel": "FIRST_QUARTILE" },
              { "date": "2026-11-05", "contributionCount": 1, "contributionLevel": "FIRST_QUARTILE" },
              { "date": "2026-11-06", "contributionCount": 2, "contributionLevel": "FOURTH_QUARTILE" },
              { "date": "2026-11-07", "contributionCount": 0, "contributionLevel": "NONE" }
            ] }
          ]
        }
      }
    }
  }
}
""".utf8)

/// Same markup shape as github.com/users/<login>/contributions: the table is row-major
/// (all Sundays, then all Mondays…) and counts live in separate <tool-tip> elements.
private let contributionsPageFixture = """
<h2 tabindex="-1" id="js-contribution-activity-description" class="f4 text-normal mb-2">
  1,302
  contributions
    in the last year
</h2>
<table role="grid" class="ContributionCalendar-grid js-calendar-graph-table"><tbody>
<tr><td tabindex="0" data-ix="0" aria-selected="false" style="width: 10px" data-date="2026-11-01" id="contribution-day-component-0-0" data-level="1" role="gridcell" class="ContributionCalendar-day"></td>
<td tabindex="0" data-ix="1" aria-selected="false" style="width: 10px" data-date="2026-11-08" id="contribution-day-component-0-1" data-level="0" role="gridcell" class="ContributionCalendar-day"></td></tr>
<tr><td tabindex="0" data-ix="0" aria-selected="false" style="width: 10px" data-date="2026-11-02" id="contribution-day-component-1-0" data-level="4" role="gridcell" class="ContributionCalendar-day"></td></tr>
<tr><td tabindex="0" data-ix="0" aria-selected="false" style="width: 10px" data-date="2026-11-03" id="contribution-day-component-2-0" data-level="0" role="gridcell" class="ContributionCalendar-day"></td></tr>
</tbody></table>
<tool-tip style="pointer-events: none;" id="tooltip-1" for="contribution-day-component-0-0" popover="manual" data-direction="n" data-type="label" class="sr-only position-absolute">2 contributions on November 1st.</tool-tip>
<tool-tip style="pointer-events: none;" id="tooltip-2" for="contribution-day-component-1-0" popover="manual" data-direction="n" data-type="label" class="sr-only position-absolute">1,024 contributions on November 2nd.</tool-tip>
<tool-tip style="pointer-events: none;" id="tooltip-3" for="contribution-day-component-2-0" popover="manual" data-direction="n" data-type="label" class="sr-only position-absolute">No contributions on November 3rd.</tool-tip>
<tool-tip style="pointer-events: none;" id="tooltip-4" for="contribution-day-component-0-1" popover="manual" data-direction="n" data-type="label" class="sr-only position-absolute">No contributions on November 8th.</tool-tip>
"""

private func day(_ iso: String, _ count: Int) -> ContributionDay {
    ContributionDay(date: CalendarDay(iso: iso)!, count: count, level: count == 0 ? .none : .first)
}

// MARK: - CalendarDay

struct CalendarDayTests {
    @Test func parsesAndFormatsISODates() throws {
        let date = try #require(CalendarDay(iso: "2026-11-07"))
        #expect(date == CalendarDay(year: 2026, month: 11, day: 7))
        #expect(date.description == "2026-11-07")
        #expect(CalendarDay(iso: "2026-13-01") == nil)
        #expect(CalendarDay(iso: "not-a-date") == nil)
    }

    @Test(arguments: [
        ("1970-01-01", 4), // Thursday
        ("2025-11-02", 0), // Sunday: first column of the screenshot's graph
        ("2026-11-07", 6), // Saturday
        ("2024-02-29", 4), // leap day, Thursday
    ])
    func weekday(iso: String, expected: Int) {
        #expect(CalendarDay(iso: iso)!.weekday == expected)
    }

    @Test func dayNumbersAreConsecutiveAcrossMonthAndYearEnds() {
        #expect(CalendarDay(iso: "2026-01-01")!.dayNumber - CalendarDay(iso: "2025-12-31")!.dayNumber == 1)
        #expect(CalendarDay(iso: "2024-03-01")!.dayNumber - CalendarDay(iso: "2024-02-28")!.dayNumber == 2)
    }

    @Test func encodesAsPlainString() throws {
        let data = try JSONEncoder().encode([CalendarDay(year: 2026, month: 1, day: 5)])
        #expect(String(decoding: data, as: UTF8.self) == #"["2026-01-05"]"#)
        #expect(try JSONDecoder().decode([CalendarDay].self, from: data).first?.day == 5)
    }
}

// MARK: - Username

struct UsernameTests {
    @Test(arguments: [
        "sharvesh300",
        "  sharvesh300\n",
        "@sharvesh300",
        "github.com/sharvesh300",
        "https://github.com/sharvesh300",
        "https://www.github.com/sharvesh300/",
        "https://github.com/sharvesh300?tab=repositories",
    ])
    func acceptsCommonForms(input: String) {
        #expect(GitHubService.normalizedLogin(input)?.hasPrefix("sharvesh300") == true)
    }

    @Test(arguments: ["", "   ", "-leading", "trailing-", "has space", "émoji", String(repeating: "a", count: 40)])
    func rejectsInvalid(input: String) {
        #expect(GitHubService.normalizedLogin(input) == nil)
    }
}

// MARK: - Parsing

struct ParsingTests {
    @Test func parsesGraphQLResponse() throws {
        let calendar = try GitHubService.parseGraphQL(graphQLFixture, login: "sharvesh300", fetchedAt: .distantPast)

        #expect(calendar.source == .graphQL)
        #expect(calendar.totalContributions == 14)
        #expect(calendar.profile.name == "Sharvesh Sivagnanam")
        #expect(calendar.profile.avatarURL?.host() == "avatars.githubusercontent.com")
        #expect(calendar.days.count == 11)
        #expect(calendar.days.first?.date.description == "2026-10-28")
        #expect(calendar.today?.date.description == "2026-11-07")
        #expect(calendar.days.first { $0.date.description == "2026-11-06" }?.level == .fourth)
    }

    @Test func graphQLNotFoundBecomesUserNotFound() {
        let data = Data(#"{"data":{"user":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a User"}]}"#.utf8)
        #expect(throws: GitHubError.userNotFound("nobody")) {
            try GitHubService.parseGraphQL(data, login: "nobody", fetchedAt: .now)
        }
    }

    @Test func garbageIsAnUnexpectedResponse() {
        #expect(throws: GitHubError.unexpectedResponse) {
            try GitHubService.parseGraphQL(Data("<html>".utf8), login: "x", fetchedAt: .now)
        }
        #expect(throws: GitHubError.unexpectedResponse) {
            try GitHubService.parseContributionsPage("<html></html>", login: "x", fetchedAt: .now)
        }
    }

    @Test func parsesPublicContributionsPage() throws {
        let calendar = try GitHubService.parseContributionsPage(contributionsPageFixture, login: "sharvesh300", fetchedAt: .now)

        #expect(calendar.source == .publicProfile)
        #expect(calendar.totalContributions == 1302)
        // Row-major HTML comes back in date order.
        #expect(calendar.days.map(\.date.description) == ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-08"])
        #expect(calendar.days.map(\.count) == [2, 1024, 0, 0])
        #expect(calendar.days.map(\.level) == [.first, .fourth, .none, .none])
    }

    @Test(arguments: [
        (200, nil),
        (401, GitHubError.invalidToken),
        (404, GitHubError.userNotFound("x")),
        (429, GitHubError.rateLimited),
        (500, GitHubError.network("GitHub returned HTTP 500.")),
    ] as [(Int, GitHubError?)])
    func mapsHTTPStatus(status: Int, expected: GitHubError?) {
        #expect(GitHubService.error(forStatus: status, login: "x") == expected)
    }

    @Test func distinguishesRateLimitFromForbidden() {
        #expect(GitHubService.error(forStatus: 403, login: "x", remainingRateLimit: "0") == .rateLimited)
        #expect(GitHubService.error(forStatus: 403, login: "x", remainingRateLimit: "4999") == .invalidToken)
    }
}

// MARK: - Calendar shape and stats

struct CalendarTests {
    @Test func weeksArePaddedSundayToSaturdayColumns() throws {
        let calendar = try GitHubService.parseGraphQL(graphQLFixture, login: "sharvesh300", fetchedAt: .now)
        let weeks = calendar.weeks

        #expect(weeks.count == 2)
        #expect(weeks.allSatisfy { $0.count == 7 })
        // 2026-10-28 is a Wednesday, so the first column starts with three empty cells.
        #expect(weeks[0].prefix(3).allSatisfy { $0 == nil })
        #expect(weeks[0][3]?.date.description == "2026-10-28")
        #expect(weeks[1][0]?.date.description == "2026-11-01")
        #expect(weeks[1][6]?.date.description == "2026-11-07")
        #expect(calendar.recentWeeks(1).count == 1)
    }

    @Test func statsFromFixture() throws {
        let stats = try GitHubService.parseGraphQL(graphQLFixture, login: "sharvesh300", fetchedAt: .now).stats

        // Today (11-07) is quiet, so the streak counts back from yesterday: 11-04…11-06.
        #expect(stats.currentStreak == 3)
        // 10-29…11-01 is the longest run.
        #expect(stats.longestStreak == 4)
        #expect(stats.activeDays == 7)
        #expect(stats.thisWeek == 6)
        #expect(stats.bestDay?.date.description == "2026-10-30")
    }

    @Test func streakIncludesTodayWhenActive() {
        let stats = ContributionStats(days: [day("2026-11-05", 0), day("2026-11-06", 1), day("2026-11-07", 2)])
        #expect(stats.currentStreak == 2)
    }

    @Test func streakEndsAfterTwoQuietDays() {
        let stats = ContributionStats(days: [day("2026-11-05", 4), day("2026-11-06", 0), day("2026-11-07", 0)])
        #expect(stats.currentStreak == 0)
        #expect(stats.longestStreak == 1)
    }

    @Test func gapsInDataBreakStreaks() {
        let stats = ContributionStats(days: [day("2026-11-01", 1), day("2026-11-02", 1), day("2026-11-06", 1), day("2026-11-07", 1)])
        #expect(stats.currentStreak == 2)
        #expect(stats.longestStreak == 2)
    }

    @Test func emptyCalendarHasZeroStats() {
        let stats = ContributionStats(days: [])
        #expect(stats == ContributionStats(days: []))
        #expect(stats.currentStreak == 0 && stats.longestStreak == 0 && stats.bestDay == nil)
    }
}

// MARK: - Store

struct StoreTests {
    private func makeStore() -> ContributionStore {
        let suite = "GitHubActivityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ContributionStore(defaults: defaults, keychain: TokenKeychain(service: suite))
    }

    @Test func normalizesAndClearsUsername() {
        let store = makeStore()
        store.username = "https://github.com/sharvesh300"
        #expect(store.username == "sharvesh300")
        store.username = "not valid!"
        #expect(store.username == nil)
    }

    @Test func cacheRoundTrips() throws {
        let store = makeStore()
        store.username = "sharvesh300"
        let calendar = try GitHubService.parseGraphQL(graphQLFixture, login: "sharvesh300", fetchedAt: Date(timeIntervalSince1970: 1_000))
        #expect(store.cachedCalendar == nil)

        store.cache(calendar)
        #expect(store.cachedCalendar == calendar)
        #expect(store.cachedCalendar(for: "SHARVESH300") == calendar)

        store.clearCache()
        #expect(store.cachedCalendar == nil)
    }

    @Test func cachesEachUserSeparately() throws {
        let store = makeStore()
        store.username = "sharvesh300"
        let mine = try GitHubService.parseGraphQL(graphQLFixture, login: "sharvesh300", fetchedAt: .now)
        var theirs = mine
        theirs.profile = GitHubProfile(login: "octocat")

        store.cache(mine)
        store.cache(theirs)

        #expect(store.cachedCalendar?.profile.login == "sharvesh300")
        #expect(store.cachedCalendar(for: "octocat")?.profile.login == "octocat")
    }

    @Test func reusesAFreshCacheWithoutTheNetwork() async throws {
        let store = makeStore()
        let calendar = try GitHubService.parseGraphQL(graphQLFixture, login: "sharvesh300", fetchedAt: .now)
        store.cache(calendar)

        // A session that fails every request proves the cache answered.
        let offline = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 9]
            return configuration
        }())
        let result = await store.loadCalendar(username: "sharvesh300", reuseIfNewerThan: 60, using: GitHubService(session: offline))

        guard case .fresh(let reused) = result else {
            Issue.record("Expected the cached calendar, got \(result)")
            return
        }
        #expect(reused == calendar)
    }

    @Test func avatarsExpire() {
        let store = makeStore()
        store.cacheAvatar(Data([1, 2, 3]), for: "Sharvesh300")
        #expect(store.cachedAvatar(for: "sharvesh300") == Data([1, 2, 3]))
        #expect(store.cachedAvatar(for: "sharvesh300", maxAge: -1) == nil)
    }

    @Test func loadWithoutUsernameFails() async {
        let result = await makeStore().loadCalendar()
        #expect(result.error == .invalidUsername)
        #expect(result.calendar == nil)
    }
}
