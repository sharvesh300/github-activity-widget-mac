import SwiftUI

/// The app's only window: choose the GitHub username every widget shows,
/// and preview that user's activity.
struct SettingsView: View {
    @State private var model = AccountModel()
    @State private var draft = ""
    @State private var isEditing = false

    var body: some View {
        Form {
            if let username = model.username, !isEditing {
                profileSection(username)
                activitySection
                themeSection
            } else {
                usernameSection
            }

            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 660, idealHeight: 660, maxHeight: 900)
        .animation(.snappy, value: model.username)
        .animation(.snappy, value: isEditing)
        .task { await model.refreshIfStale() }
    }

    // MARK: Choosing a username

    private var usernameSection: some View {
        Section {
            if model.username == nil {
                VStack(spacing: 12) {
                    ContributionGrid(weeks: ContributionCalendar.sample.recentWeeks(22), highlightsToday: false)
                        .frame(height: 70)
                        .accessibilityHidden(true)
                    Text("Your GitHub activity, on your desktop")
                        .font(.title3.weight(.semibold))
                    Text("Enter a GitHub username. Every GitHub Activity widget will show it.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            // An instruction, not an example: a sample name in grey looked like a filled-in value.
            TextField("GitHub username", text: $draft, prompt: Text("Enter a username"))
                .onSubmit(save)

            HStack {
                if isEditing {
                    Button("Cancel") {
                        isEditing = false
                    }
                    .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            if isEditing { Text("Change username") }
        } footer: {
            Text("Shows public contributions. You can also set it from any widget: right-click it and choose Edit Widget.")
        }
    }

    private func save() {
        guard model.setUsername(draft) else { return }
        isEditing = false
        Task { await model.refresh() }
    }

    // MARK: Showing a username

    private func profileSection(_ username: String) -> some View {
        let profile = model.calendar?.profile ?? GitHubProfile(login: username)
        return Section {
            HStack(spacing: 12) {
                Avatar(profile: profile, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    let name = profile.name.flatMap { $0.isEmpty ? nil : $0 }
                    Text(name ?? "@\(profile.login)")
                        .font(.headline)
                    // Public profiles have no display name; don't repeat the login twice.
                    Text(name == nil ? "Shown on all your widgets" : "@\(profile.login) · Shown on all your widgets")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Change") {
                    // Start from the current name so it can be edited, not retyped.
                    draft = username
                    isEditing = true
                }
            }
        }
    }

    private var activitySection: some View {
        Section {
            if let calendar = model.calendar {
                let stats = calendar.stats
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(calendar.totalContributions.formatted())
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("contributions in the last year")
                        .foregroundStyle(.secondary)
                }
                ContributionGrid(weeks: calendar.weeks, theme: model.theme, showsMonthLabels: true, alignment: .topLeading)
                    .frame(height: 96)
                HStack {
                    StatView(value: stats.currentStreak, unit: "day", label: "Current streak")
                    StatView(value: stats.longestStreak, unit: "day", label: "Longest streak")
                    StatView(value: stats.activeDays, unit: "day", label: "Active")
                }
            } else if model.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Loading contributions…")
                        Text("GitHub can take up to a minute the first time.")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("No contributions loaded yet.").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Activity")
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing)
                .help("Refresh now")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let calendar = model.calendar {
                    Text("Updated \(calendar.fetchedAt.formatted(.relative(presentation: .named))).")
                }
                Text("To add the widget, right-click your desktop and choose Edit Widgets.")
            }
        }
    }
}

// MARK: - Theme

extension SettingsView {
    fileprivate var themeSection: some View {
        Section {
            Picker("Theme", selection: Binding(get: { model.theme }, set: { model.setTheme($0) })) {
                ForEach(ContributionTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Preview")
                    .foregroundStyle(.secondary)
                Spacer()
                ContributionLegend(theme: model.theme, cellSize: 12, labelSize: 11)
            }
        } header: {
            Text("Widget theme")
        } footer: {
            Text("Used by every GitHub Activity widget. Saved on this Mac until you change it.")
        }
    }
}

// MARK: - Pieces

private struct Avatar: View {
    let profile: GitHubProfile
    let size: CGFloat

    var body: some View {
        AsyncImage(url: profile.avatarImageURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Circle()
                .fill(.quaternary)
                .overlay(
                    Text(profile.login.prefix(1).uppercased())
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private struct StatView: View {
    let value: Int
    let unit: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value) \(value == 1 ? unit : unit + "s")")
                .font(.headline)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    SettingsView()
}
