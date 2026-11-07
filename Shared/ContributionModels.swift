import Foundation

// MARK: - CalendarDay

/// A plain calendar date (for example 2026-11-07) with no time or time zone.
///
/// GitHub reports contribution days as plain dates. Keeping them that way avoids
/// off-by-one-day bugs when the Mac's time zone differs from the one GitHub used.
struct CalendarDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses an ISO date such as `2026-11-07`.
    init?(iso: String) {
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar.
    /// (Howard Hinnant's `days_from_civil`; no Foundation calendar or time zone involved.)
    var dayNumber: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthFromMarch = (month + 9) % 12
        let dayOfYear = (153 * monthFromMarch + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// 0 = Sunday … 6 = Saturday, matching the rows of GitHub's graph.
    var weekday: Int {
        // 1970-01-01 was a Thursday (4).
        ((dayNumber % 7) + 7 + 4) % 7
    }

    static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension CalendarDay: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let value = CalendarDay(iso: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(string)")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Contributions

/// GitHub's five intensity buckets (the "Less … More" legend).
enum ContributionLevel: Int, Codable, Sendable, CaseIterable, Comparable {
    case none = 0, first, second, third, fourth

    /// Maps GraphQL's `ContributionLevel` enum (`NONE`, `FIRST_QUARTILE`, …).
    init(graphQLValue: String) {
        switch graphQLValue {
        case "FIRST_QUARTILE": self = .first
        case "SECOND_QUARTILE": self = .second
        case "THIRD_QUARTILE": self = .third
        case "FOURTH_QUARTILE": self = .fourth
        default: self = .none
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct ContributionDay: Hashable, Codable, Sendable {
    let date: CalendarDay
    let count: Int
    let level: ContributionLevel
}

struct GitHubProfile: Hashable, Codable, Sendable {
    let login: String
    var name: String?
    var avatarURL: URL?

    var profileURL: URL { URL(string: "https://github.com/\(login)")! }
}

/// One year of contributions for a user, oldest day first.
struct ContributionCalendar: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable {
        /// GitHub's GraphQL API (needs a token, exact and can include private work).
        case graphQL
        /// The public contributions page (no token, public activity only).
        case publicProfile
    }

    var profile: GitHubProfile
    var totalContributions: Int
    /// Every day in the range, sorted oldest → newest.
    var days: [ContributionDay]
    var fetchedAt: Date
    var source: Source

    init(profile: GitHubProfile, totalContributions: Int, days: [ContributionDay], fetchedAt: Date, source: Source) {
        self.profile = profile
        self.totalContributions = totalContributions
        self.days = days.sorted { $0.date < $1.date }
        self.fetchedAt = fetchedAt
        self.source = source
    }

    /// The most recent day GitHub reported, which is "today" in GitHub's view.
    var today: ContributionDay? { days.last }

    /// Week columns (Sunday → Saturday), oldest first, exactly like GitHub's graph.
    /// Days outside the range (before the first day or after today) are `nil`.
    var weeks: [[ContributionDay?]] {
        var columns: [[ContributionDay?]] = []
        var currentWeekStart: Int?
        for day in days {
            let weekStart = day.date.dayNumber - day.date.weekday
            if weekStart != currentWeekStart {
                columns.append(Array(repeating: nil, count: 7))
                currentWeekStart = weekStart
            }
            columns[columns.count - 1][day.date.weekday] = day
        }
        return columns
    }

    /// The most recent `count` week columns, for the smaller widget sizes.
    func recentWeeks(_ count: Int) -> [[ContributionDay?]] {
        Array(weeks.suffix(count))
    }

    var stats: ContributionStats { ContributionStats(days: days) }
}

// MARK: - Stats

struct ContributionStats: Equatable, Sendable {
    /// Consecutive days with at least one contribution, ending today.
    /// A quiet "today" doesn't break the streak yet; it counts from yesterday.
    let currentStreak: Int
    let longestStreak: Int
    /// Days with at least one contribution.
    let activeDays: Int
    /// Contributions since the start of the current week (Sunday).
    let thisWeek: Int
    let bestDay: ContributionDay?

    init(days: [ContributionDay]) {
        let days = days.sorted { $0.date < $1.date }

        var longest = 0
        var run = 0
        var previous: CalendarDay?
        for day in days {
            let isNextDay = previous.map { day.date.dayNumber == $0.dayNumber + 1 } ?? true
            run = day.count > 0 ? (isNextDay ? run + 1 : 1) : 0
            longest = max(longest, run)
            previous = day.date
        }
        longestStreak = longest

        var current = 0
        var index = days.count - 1
        if index >= 0, days[index].count == 0 { index -= 1 }
        while index >= 0, days[index].count > 0 {
            if current > 0, days[index].date.dayNumber != days[index + 1].date.dayNumber - 1 { break }
            current += 1
            index -= 1
        }
        currentStreak = current

        activeDays = days.count { $0.count > 0 }

        if let today = days.last?.date {
            let weekStart = today.dayNumber - today.weekday
            thisWeek = days.filter { $0.date.dayNumber >= weekStart }.reduce(0) { $0 + $1.count }
        } else {
            thisWeek = 0
        }

        bestDay = days.max { $0.count < $1.count }.flatMap { $0.count > 0 ? $0 : nil }
    }
}
