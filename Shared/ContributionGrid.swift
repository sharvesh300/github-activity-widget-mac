import SwiftUI
import WidgetKit

// MARK: - Layout maths

/// How many week columns fit in a space, and how big each cell is.
///
/// Cells are sized from the height first (7 rows always fill it), then the
/// grid shows as many of the most recent weeks as fit across. If every week
/// fits with room to spare, cells shrink to the width instead.
struct GridMetrics: Equatable {
    static let rows = 7

    var columns: Int
    var cellSize: CGFloat
    var gap: CGFloat

    init(available: CGSize, weekCount: Int, gapRatio: CGFloat = 0.22, maxCellSize: CGFloat = .infinity) {
        guard weekCount > 0, available.width > 0, available.height > 0 else {
            self.columns = 0
            self.cellSize = 0
            self.gap = 0
            return
        }
        let rows = CGFloat(Self.rows)
        let cellForHeight = min(maxCellSize, available.height / (rows + (rows - 1) * gapRatio))
        // Solve width = n·cell + (n-1)·gap for n; the epsilon keeps exact fits from rounding down.
        let fitting = Int(((available.width / cellForHeight + gapRatio) / (1 + gapRatio)) + 1e-6)
        let columns = max(1, min(weekCount, fitting))
        let cellForWidth = available.width / (CGFloat(columns) + CGFloat(columns - 1) * gapRatio)

        self.columns = columns
        self.cellSize = min(cellForHeight, cellForWidth)
        self.gap = cellSize * gapRatio
    }

    var pitch: CGFloat { cellSize + gap }

    var gridSize: CGSize {
        guard columns > 0 else { return .zero }
        return CGSize(
            width: CGFloat(columns) * cellSize + CGFloat(columns - 1) * gap,
            height: CGFloat(Self.rows) * cellSize + CGFloat(Self.rows - 1) * gap
        )
    }

    /// The cell's rectangle relative to the grid's top-left corner.
    func cellRect(column: Int, row: Int) -> CGRect {
        CGRect(x: CGFloat(column) * pitch, y: CGFloat(row) * pitch, width: cellSize, height: cellSize)
    }
}

/// Where to put month names above the week columns, GitHub-style:
/// a label sits over the first column that starts in a new month.
enum MonthLabels {
    struct Label: Equatable {
        let column: Int
        let month: Int
    }

    /// - Parameter minimumSpacing: columns a label needs before the next one,
    ///   so short months at the edges don't overlap their neighbours.
    static func labels(for weeks: [[ContributionDay?]], minimumSpacing: Int) -> [Label] {
        var candidates: [Label] = []
        var previousMonth: Int?
        for (column, week) in weeks.enumerated() {
            guard let month = week.lazy.compactMap({ $0 }).first?.date.month else { continue }
            if month != previousMonth {
                candidates.append(Label(column: column, month: month))
                previousMonth = month
            }
        }

        // Walk backwards so the newest months win when two labels crowd each other.
        // The last label only needs room for its own text before the grid ends.
        var labels: [Label] = []
        for candidate in candidates.reversed() {
            let nextColumn = labels.last?.column ?? weeks.count + 1
            if nextColumn - candidate.column >= minimumSpacing {
                labels.append(candidate)
            }
        }
        return labels.reversed()
    }

    /// Gregorian (GitHub's grid is always Sunday-first) but named in the user's language.
    /// A calendar without a locale returns placeholder names like "M07".
    static var localizedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        return calendar
    }

    static func title(forMonth month: Int) -> String {
        let symbols = localizedCalendar.shortStandaloneMonthSymbols
        return symbols.indices.contains(month - 1) ? symbols[month - 1] : ""
    }
}

// MARK: - Grid view

/// GitHub's contribution heatmap, drawn in one `Canvas` so even a full year
/// (371 cells) stays cheap to render in a widget.
struct ContributionGrid: View {
    let weeks: [[ContributionDay?]]
    var theme: ContributionTheme = .github
    var showsMonthLabels = false
    var showsWeekdayLabels = false
    var highlightsToday = true
    var maxCellSize: CGFloat = .infinity
    var gapRatio: CGFloat = 0.22
    var labelSize: CGFloat = 10
    var alignment: Alignment = .center

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var topInset: CGFloat { showsMonthLabels ? (labelSize * 1.5).rounded(.up) : 0 }
    private var leadingInset: CGFloat { showsWeekdayLabels ? (labelSize * 2.6).rounded(.up) : 0 }

    var body: some View {
        GeometryReader { proxy in
            let metrics = GridMetrics(
                available: CGSize(width: proxy.size.width - leadingInset, height: proxy.size.height - topInset),
                weekCount: weeks.count,
                gapRatio: gapRatio,
                maxCellSize: maxCellSize
            )
            let visibleWeeks = Array(weeks.suffix(metrics.columns))
            // Room around the grid so today's outline isn't clipped at the edges.
            let bleed = Self.ringWidth(for: metrics).rounded(.up)

            Canvas { context, _ in
                context.translateBy(x: bleed, y: bleed)
                draw(visibleWeeks, metrics: metrics, in: &context)
            }
            .frame(
                width: metrics.gridSize.width + leadingInset + bleed * 2,
                height: metrics.gridSize.height + topInset + bleed * 2
            )
            .padding(-bleed)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: alignment)
            .accessibilityElement()
            .accessibilityLabel(Self.accessibilitySummary(for: visibleWeeks))
        }
    }

    // MARK: Drawing

    private func draw(_ weeks: [[ContributionDay?]], metrics: GridMetrics, in context: inout GraphicsContext) {
        let origin = CGPoint(x: leadingInset, y: topInset)
        let cornerRadius = metrics.cellSize * 0.24
        let today = weeks.last?.compactMap { $0 }.last

        if showsMonthLabels {
            let labelWidth = labelSize * 2.2
            let spacing = max(2, Int((labelWidth / metrics.pitch).rounded(.up)) + 1)
            for label in MonthLabels.labels(for: weeks, minimumSpacing: spacing) {
                context.draw(
                    labelText(MonthLabels.title(forMonth: label.month)),
                    at: CGPoint(x: origin.x + CGFloat(label.column) * metrics.pitch, y: 0),
                    anchor: .topLeading
                )
            }
        }

        if showsWeekdayLabels {
            let symbols = MonthLabels.localizedCalendar.shortStandaloneWeekdaySymbols
            for row in [1, 3, 5] {
                context.draw(
                    labelText(symbols[row]),
                    at: CGPoint(x: 0, y: origin.y + CGFloat(row) * metrics.pitch + metrics.cellSize / 2),
                    anchor: .leading
                )
            }
        }

        for (column, week) in weeks.enumerated() {
            for (row, day) in week.enumerated() {
                guard let day else { continue }
                let rect = metrics.cellRect(column: column, row: row).offsetBy(dx: origin.x, dy: origin.y)
                let shape = Path(roundedRect: rect, cornerRadius: cornerRadius)
                context.fill(shape, with: .color(theme.color(for: day.level, in: colorScheme, renderingMode: renderingMode)))

                if highlightsToday, day == today {
                    let ringWidth = Self.ringWidth(for: metrics)
                    let ring = Path(
                        roundedRect: rect.insetBy(dx: -ringWidth / 2, dy: -ringWidth / 2),
                        cornerRadius: cornerRadius + ringWidth / 2
                    )
                    context.stroke(ring, with: .color(.primary.opacity(0.6)), lineWidth: ringWidth)
                }
            }
        }
    }

    private static func ringWidth(for metrics: GridMetrics) -> CGFloat {
        max(1, metrics.cellSize * 0.12)
    }

    private func labelText(_ string: String) -> Text {
        Text(string)
            .font(.system(size: labelSize))
            .foregroundStyle(.secondary)
    }

    nonisolated static func accessibilitySummary(for weeks: [[ContributionDay?]]) -> String {
        let days = weeks.flatMap { $0.compactMap { $0 } }
        let total = days.reduce(0) { $0 + $1.count }
        let active = days.count { $0.count > 0 }
        return "Contribution graph: \(total.formatted()) contributions on \(active) of the last \(days.count) days"
    }
}

// MARK: - Legend

/// The "Less ▢▢▢▢▢ More" key.
struct ContributionLegend: View {
    var theme: ContributionTheme = .github
    var cellSize: CGFloat = 10
    var labelSize: CGFloat = 10

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(spacing: cellSize * 0.3) {
            Text("Less")
                .padding(.trailing, cellSize * 0.2)
            ForEach(ContributionLevel.allCases, id: \.self) { level in
                RoundedRectangle(cornerRadius: cellSize * 0.24)
                    .fill(theme.color(for: level, in: colorScheme, renderingMode: renderingMode))
                    .frame(width: cellSize, height: cellSize)
            }
            Text("More")
                .padding(.leading, cellSize * 0.2)
        }
        .font(.system(size: labelSize))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

private struct GridPreviewCard<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .padding(16)
            .frame(width: width, height: height)
            .background(WidgetSurface.background(in: colorScheme), in: .rect(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(WidgetSurface.border(in: colorScheme), lineWidth: 0.5))
    }
}

private struct GridPreviewGallery: View {
    let calendar = ContributionCalendar.sample

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(ContributionTheme.allCases) { theme in
                    HStack(alignment: .top, spacing: 16) {
                        GridPreviewCard(width: 170, height: 170) {
                            ContributionGrid(weeks: calendar.weeks, theme: theme, alignment: .bottomTrailing)
                        }
                        GridPreviewCard(width: 364, height: 170) {
                            ContributionGrid(weeks: calendar.weeks, theme: theme, showsMonthLabels: true, alignment: .bottomTrailing)
                        }
                        GridPreviewCard(width: 766, height: 170) {
                            VStack(alignment: .trailing, spacing: 8) {
                                ContributionGrid(weeks: calendar.weeks, theme: theme, showsMonthLabels: true, showsWeekdayLabels: true, alignment: .topLeading)
                                ContributionLegend(theme: theme)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

#Preview("Themes · dark", traits: .fixedLayout(width: 1400, height: 900)) {
    GridPreviewGallery()
        .preferredColorScheme(.dark)
}

#Preview("Themes · light", traits: .fixedLayout(width: 1400, height: 900)) {
    GridPreviewGallery()
        .preferredColorScheme(.light)
}
