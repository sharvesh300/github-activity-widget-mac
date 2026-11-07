import CoreGraphics
import Testing
@testable import GitHubActivity

struct GridMetricsTests {
    @Test func exactFitShowsEveryWeekAtFullSize() {
        // 53 cells of 10pt with 2.2pt gaps, 7 rows high.
        let metrics = GridMetrics(available: CGSize(width: 644.4, height: 83.2), weekCount: 53, gapRatio: 0.22)
        #expect(metrics.columns == 53)
        #expect(abs(metrics.cellSize - 10) < 0.001)
        #expect(abs(metrics.gap - 2.2) < 0.001)
    }

    @Test(arguments: [
        CGSize(width: 138, height: 138),  // small widget content
        CGSize(width: 332, height: 110),  // medium, under a header
        CGSize(width: 332, height: 220),  // large
        CGSize(width: 734, height: 260),  // extra large
        CGSize(width: 40, height: 300),   // narrow and tall
    ])
    func showsTheMostWeeksThatFit(size: CGSize) {
        let metrics = GridMetrics(available: size, weekCount: 53)
        let grid = metrics.gridSize

        #expect((1...53).contains(metrics.columns))
        #expect(grid.width <= size.width + 0.001)
        #expect(grid.height <= size.height + 0.001)
        if metrics.columns < 53 {
            // One more column at the same cell size would overflow.
            #expect(grid.width + metrics.pitch > size.width)
        }
    }

    @Test func fewWeeksDoNotStretchPastTheHeight() {
        let metrics = GridMetrics(available: CGSize(width: 800, height: 85), weekCount: 4, gapRatio: 0.25)
        #expect(metrics.columns == 4)
        #expect(abs(metrics.cellSize - 10) < 0.001)
    }

    @Test func respectsMaximumCellSize() {
        let metrics = GridMetrics(available: CGSize(width: 800, height: 800), weekCount: 53, maxCellSize: 12)
        #expect(metrics.cellSize == 12)
        #expect(metrics.columns == 53)
    }

    @Test func emptyInputsGiveAnEmptyGrid() {
        #expect(GridMetrics(available: CGSize(width: 100, height: 100), weekCount: 0).gridSize == .zero)
        #expect(GridMetrics(available: .zero, weekCount: 53).columns == 0)
    }

    @Test func cellRectsStepByPitch() {
        let metrics = GridMetrics(available: CGSize(width: 644.4, height: 83.2), weekCount: 53, gapRatio: 0.22)
        let rect = metrics.cellRect(column: 2, row: 3)
        #expect(abs(rect.minX - 24.4) < 0.001)
        #expect(abs(rect.minY - 36.6) < 0.001)
        #expect(abs(rect.width - 10) < 0.001)
    }
}

struct MonthLabelTests {
    private let weeks = ContributionCalendar.sample.weeks

    @Test func labelsEachMonthWhereItsFirstWeekStarts() {
        let labels = MonthLabels.labels(for: weeks, minimumSpacing: 3)

        // The sample runs Sun 2025-11-02 → Sat 2026-11-07. The trailing "Nov" column
        // is too close to the end for its label, so the newest label is Oct.
        #expect(labels.map(\.month) == [11, 12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        #expect(labels.first?.column == 0)
        #expect(labels[1].column == 5)        // 2025-12-07
        #expect(labels.last?.column == 48)    // 2026-10-04
    }

    @Test func crowdedLabelsKeepTheNewerMonth() {
        // Nov (column 0) and Dec (column 5) are 5 apart, so a spacing of 6 drops Nov.
        let labels = MonthLabels.labels(for: weeks, minimumSpacing: 6)
        #expect(labels.first?.month == 12)
        #expect(zip(labels, labels.dropFirst()).allSatisfy { $1.column - $0.column >= 6 })
    }

    @Test func titlesAreShortMonthNames() {
        #expect(MonthLabels.title(forMonth: 1).isEmpty == false)
        #expect(MonthLabels.title(forMonth: 7) != "M07")
        #expect(MonthLabels.title(forMonth: 13).isEmpty)
    }
}

struct SampleDataTests {
    @Test func sampleLooksLikeAGitHubYear() {
        let sample = ContributionCalendar.sample
        #expect(sample.days.count == 371)
        #expect(sample.weeks.count == 53)
        #expect(sample.days.first?.date.weekday == 0)
        #expect(sample.today?.date.description == "2026-11-07")
        #expect(sample.totalContributions == sample.days.reduce(0) { $0 + $1.count })
        #expect(Set(sample.days.map(\.level)).count == 5)
    }

    @Test func dayNumberRoundTrips() {
        for number in stride(from: -800_000, through: 800_000, by: 997) {
            #expect(CalendarDay(dayNumber: number).dayNumber == number)
        }
        #expect(CalendarDay(dayNumber: 0).description == "1970-01-01")
        #expect(CalendarDay(dayNumber: CalendarDay(iso: "2024-02-29")!.dayNumber).description == "2024-02-29")
    }

    @Test func accessibilitySummaryCountsVisibleDays() {
        let summary = ContributionGrid.accessibilitySummary(for: ContributionCalendar.sample.recentWeeks(1))
        #expect(summary.contains("of the last 7 days"))
    }
}
