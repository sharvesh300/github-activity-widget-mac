import AppIntents
import AppKit
import SwiftUI
import WidgetKit

/// The widget's root view: picks a layout for the size and paints the background.
struct ContributionWidgetView: View {
    let entry: ContributionEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WidgetLayout(entry: entry, family: family)
            .containerBackground(for: .widget) {
                WidgetSurface.background(in: colorScheme)
            }
    }
}

/// The content for one size, without WidgetKit's container, so it can also be
/// rendered in previews and snapshot checks.
struct WidgetLayout: View {
    let entry: ContributionEntry
    let family: WidgetFamily

    var body: some View {
        switch entry.content {
        case .loaded(let calendar, let error):
            let context = LayoutContext(calendar: calendar, error: error, entry: entry)
            Group {
                switch family {
                case .systemSmall: SmallLayout(context: context)
                case .systemMedium: MediumLayout(context: context)
                case .systemLarge: LargeLayout(context: context)
                default: ExtraLargeLayout(context: context)
                }
            }
            .widgetURL(calendar.profile.profileURL)

        case .needsUsername:
            MessageView(
                symbol: "person.crop.circle.badge.plus",
                title: "Add your GitHub username",
                message: family == .systemSmall
                    ? "Right-click and choose Edit Widget."
                    : "Right-click this widget and choose Edit Widget. Every GitHub Activity widget will use it.",
                showsRefresh: false
            )

        case .failed(let error):
            MessageView(
                symbol: "exclamationmark.triangle",
                title: "Can't load contributions",
                message: error.localizedDescription,
                showsRefresh: true
            )
        }
    }
}

/// Everything a layout needs, worked out once.
struct LayoutContext {
    let calendar: ContributionCalendar
    let stats: ContributionStats
    let error: GitHubError?
    let avatar: Data?
    let theme: ContributionTheme

    init(calendar: ContributionCalendar, error: GitHubError?, entry: ContributionEntry) {
        self.calendar = calendar
        self.stats = calendar.stats
        self.error = error
        self.avatar = entry.avatar
        self.theme = entry.theme
    }

    var profile: GitHubProfile { calendar.profile }
}

// MARK: - Small

/// Streak first: the number you check every day, with the last couple of months below.
private struct SmallLayout: View {
    let context: LayoutContext
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                StreakFlame(isActive: context.stats.currentStreak > 0, theme: context.theme)
                    .font(.system(size: 15, weight: .semibold))
                Text(context.stats.currentStreak, format: .number)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("day streak")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if context.error != nil { OfflineBadge() }
            }
            Text("\(context.calendar.totalContributions.formatted()) contributions")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 10)
            ContributionGrid(weeks: context.calendar.weeks, theme: context.theme, alignment: .bottomLeading)
        }
    }
}

// MARK: - Medium

/// Totals on the left, the last few months of the graph on the right.
private struct MediumLayout: View {
    let context: LayoutContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(context: context, showsName: false)
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(context.calendar.totalContributions, format: .number)
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text("contributions")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    InlineStat(symbol: .flame(context.stats.currentStreak > 0), value: context.stats.currentStreak, label: "day streak", theme: context.theme)
                    InlineStat(symbol: .system("calendar"), value: context.stats.thisWeek, label: "this week", theme: context.theme)
                }
                .frame(width: 92, alignment: .leading)

                ContributionGrid(
                    weeks: context.calendar.weeks,
                    theme: context.theme,
                    showsMonthLabels: true,
                    labelSize: 9,
                    alignment: .bottomTrailing
                )
            }
        }
    }
}

// MARK: - Large

/// Profile, total, about five months of the graph with labels, and the key stats.
private struct LargeLayout: View {
    let context: LayoutContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(context: context, showsName: true)
            TotalHeadline(total: context.calendar.totalContributions, size: 32)
            ContributionGrid(
                weeks: context.calendar.weeks,
                theme: context.theme,
                showsMonthLabels: true,
                showsWeekdayLabels: true,
                maxCellSize: 14,
                labelSize: 9,
                alignment: .topLeading
            )
            .frame(maxHeight: 130)
            Spacer(minLength: 0)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    StatBlock(value: days(context.stats.currentStreak), label: "Current streak")
                    StatBlock(value: days(context.stats.longestStreak), label: "Longest streak")
                }
                GridRow {
                    StatBlock(value: context.stats.activeDays.formatted(), label: "Active days")
                    StatBlock(value: bestDay(context.stats.bestDay), label: "Best day")
                }
            }
            WidgetFooter(context: context)
        }
    }
}

// MARK: - Extra large

/// The full year, like the graph on a GitHub profile, with every stat.
private struct ExtraLargeLayout: View {
    let context: LayoutContext

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WidgetHeader(context: context, showsName: true)
            TotalHeadline(total: context.calendar.totalContributions, size: 32)
            ContributionGrid(
                weeks: context.calendar.weeks,
                theme: context.theme,
                showsMonthLabels: true,
                showsWeekdayLabels: true,
                minimumWeeks: 53,
                labelSize: 10,
                alignment: .leading
            )
            HStack(alignment: .top, spacing: 12) {
                StatBlock(value: days(context.stats.currentStreak), label: "Current streak")
                StatBlock(value: days(context.stats.longestStreak), label: "Longest streak")
                StatBlock(value: context.stats.activeDays.formatted(), label: "Active days")
                StatBlock(value: context.stats.thisWeek.formatted(), label: "This week")
                StatBlock(value: bestDay(context.stats.bestDay), label: "Best day")
            }
            WidgetFooter(context: context)
        }
    }
}

// MARK: - Pieces

private struct WidgetHeader: View {
    let context: LayoutContext
    let showsName: Bool

    var body: some View {
        HStack(spacing: 8) {
            AvatarImage(data: context.avatar, login: context.profile.login, size: showsName ? 28 : 18)
            if showsName {
                VStack(alignment: .leading, spacing: 0) {
                    // Public profiles have no display name; don't repeat the login twice.
                    if let name = displayName {
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                        Text("@\(context.profile.login)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("@\(context.profile.login)")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .lineLimit(1)
            } else {
                Text("@\(context.profile.login)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if context.error != nil, !showsName { OfflineBadge() }
            RefreshButton()
        }
    }

    private var displayName: String? {
        guard let name = context.profile.name, !name.isEmpty else { return nil }
        return name
    }
}

private struct WidgetFooter: View {
    let context: LayoutContext

    var body: some View {
        HStack(alignment: .center) {
            Group {
                if context.error != nil {
                    Label {
                        Text("Offline · updated \(Text(context.calendar.fetchedAt, style: .relative)) ago")
                    } icon: {
                        Image(systemName: "wifi.slash")
                    }
                } else {
                    Text("Updated \(Text(context.calendar.fetchedAt, style: .time))")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Spacer(minLength: 8)
            ContributionLegend(theme: context.theme, cellSize: 9, labelSize: 10)
        }
    }
}

private struct TotalHeadline: View {
    let total: Int
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(total, format: .number)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("contributions in the last year")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct StatBlock: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InlineStat: View {
    enum Symbol {
        case flame(Bool)
        case system(String)
    }

    let symbol: Symbol
    let value: Int
    let label: String
    let theme: ContributionTheme

    var body: some View {
        HStack(spacing: 4) {
            Group {
                switch symbol {
                case .flame(let isActive): StreakFlame(isActive: isActive, theme: theme)
                case .system(let name): Image(systemName: name).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .frame(width: 12)
            Text(value, format: .number)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }
}

private struct StreakFlame: View {
    let isActive: Bool
    let theme: ContributionTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: "flame.fill")
            .foregroundStyle(isActive ? AnyShapeStyle(theme.accent(in: colorScheme)) : AnyShapeStyle(.tertiary))
            .widgetAccentable()
            .accessibilityHidden(true)
    }
}

private struct OfflineBadge: View {
    var body: some View {
        Image(systemName: "wifi.slash")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Offline, showing saved data")
    }
}

private struct RefreshButton: View {
    var body: some View {
        Button(intent: RefreshContributionsIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh")
    }
}

private struct AvatarImage: View {
    let data: Data?
    let login: String
    let size: CGFloat

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(.quaternary)
                    .overlay(
                        Text(login.prefix(1).uppercased())
                            .font(.system(size: size * 0.45, weight: .semibold))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .widgetAccentable(false)
        .accessibilityHidden(true)
    }
}

private struct MessageView: View {
    let symbol: String
    let title: String
    let message: String
    let showsRefresh: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            if showsRefresh {
                Button(intent: RefreshContributionsIntent()) {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Formatting

private func days(_ count: Int) -> String {
    count == 1 ? "1 day" : "\(count.formatted()) days"
}

private func bestDay(_ day: ContributionDay?) -> String {
    guard let day else { return "–" }
    return "\(day.count.formatted()) · \(MonthLabels.title(forMonth: day.date.month)) \(day.date.day)"
}
