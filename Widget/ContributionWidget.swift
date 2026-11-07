import SwiftUI
import WidgetKit

// Placeholder wiring so the extension builds and loads real data.
// The designed small / medium / large / extra-large layouts replace the view in the widget phase.

struct ContributionEntry: TimelineEntry {
    let date: Date
    let result: ContributionStore.LoadResult?
}

struct ContributionProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContributionEntry {
        ContributionEntry(date: .now, result: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (ContributionEntry) -> Void) {
        let cached = ContributionStore.shared.cachedCalendar.map { ContributionStore.LoadResult.fresh($0) }
        completion(ContributionEntry(date: .now, result: cached))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ContributionEntry>) -> Void) {
        Task {
            let result = await ContributionStore.shared.loadCalendar()
            let entry = ContributionEntry(date: .now, result: result)
            let nextRefresh = Date.now.addingTimeInterval(30 * 60)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }
}

struct ContributionWidgetView: View {
    let entry: ContributionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let calendar = entry.result?.calendar {
                Text(calendar.totalContributions.formatted())
                    .font(.title.weight(.semibold))
                Text("contributions in the last year")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(entry.result?.error?.localizedDescription ?? "Open GitHub Activity to add your username.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct ContributionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContributionWidget", provider: ContributionProvider()) { entry in
            ContributionWidgetView(entry: entry)
        }
        .configurationDisplayName("GitHub Activity")
        .description("Your GitHub contribution graph.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main
struct GitHubActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContributionWidget()
    }
}
