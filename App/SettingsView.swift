import SwiftUI

/// The app's only window: connect a GitHub account (or a public profile) and
/// preview what the widget will show.
struct SettingsView: View {
    @State private var model = AccountModel()
    @State private var publicUsername = ""

    var body: some View {
        Form {
            switch model.state {
            case .signedOut, .requestingCode:
                signInSection
                publicProfileSection
            case .awaitingAuthorization(let code):
                codeSection(code)
            case .signedIn(let profile):
                accountSection(profile, isSignedIn: true)
                activitySection
            case .publicProfile(let login):
                accountSection(model.calendar?.profile ?? GitHubProfile(login: login), isSignedIn: false)
                activitySection
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
        .frame(minHeight: 500, idealHeight: 560, maxHeight: 900)
        .animation(.snappy, value: model.state)
        .task { await model.refreshIfStale() }
    }

    // MARK: Signed out

    private var signInSection: some View {
        Section {
            VStack(spacing: 14) {
                ContributionGrid(weeks: ContributionCalendar.sample.recentWeeks(22), highlightsToday: false)
                    .frame(height: 70)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("Your GitHub activity, on your desktop")
                        .font(.title3.weight(.semibold))
                    Text("Sign in once and the widget keeps your contribution graph up to date.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button(action: model.signIn) {
                    if model.state == .requestingCode {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Sign in with GitHub")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canSignIn || model.state == .requestingCode)

                if !model.canSignIn {
                    Text("Sign-in needs a GitHub OAuth Client ID in this build (GITHUB_CLIENT_ID).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    private var publicProfileSection: some View {
        Section {
            TextField("Username", text: $publicUsername, prompt: Text("octocat"))
                .onSubmit(followPublicProfile)
            Button("Show public activity", action: followPublicProfile)
                .disabled(publicUsername.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Or follow a public profile")
        } footer: {
            Text("No sign-in needed. Shows public contributions only.")
        }
    }

    private func followPublicProfile() {
        Task { await model.usePublicProfile(publicUsername) }
    }

    // MARK: Waiting for GitHub

    private func codeSection(_ code: DeviceFlowSignIn.Code) -> some View {
        Section {
            VStack(spacing: 14) {
                Text("Enter this code on GitHub")
                    .font(.headline)

                Text(code.userCode)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .kerning(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: .rect(cornerRadius: 10))

                Text("It's on your clipboard, and GitHub is open in your browser.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Copy code", systemImage: "doc.on.doc", action: model.copyCode)
                    Button("Open GitHub", systemImage: "safari", action: model.openVerificationPage)
                        .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to authorize…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                Button("Cancel", action: model.cancelSignIn)
                    .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    // MARK: Connected

    private func accountSection(_ profile: GitHubProfile, isSignedIn: Bool) -> some View {
        Section {
            HStack(spacing: 12) {
                Avatar(profile: profile, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name.flatMap { $0.isEmpty ? nil : $0 } ?? "@\(profile.login)")
                        .font(.headline)
                    Text(isSignedIn ? "@\(profile.login) · Signed in with GitHub" : "@\(profile.login) · Public profile")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isSignedIn ? "Sign out" : "Change", action: model.signOut)
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
                ContributionGrid(weeks: calendar.weeks, showsMonthLabels: true, alignment: .topLeading)
                    .frame(height: 96)
                HStack {
                    StatView(value: stats.currentStreak, unit: "day", label: "Current streak")
                    StatView(value: stats.longestStreak, unit: "day", label: "Longest streak")
                    StatView(value: stats.activeDays, unit: "day", label: "Active")
                }
            } else if model.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading your contributions…").foregroundStyle(.secondary)
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
