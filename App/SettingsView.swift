import SwiftUI
import WidgetKit

/// Minimal settings for now: username, optional token, and a connection check.
/// The full design (theme picker, live preview) comes in the settings phase.
struct SettingsView: View {
    private let store = ContributionStore.shared

    @State private var username = ContributionStore.shared.username ?? ""
    @State private var token = ContributionStore.shared.token ?? ""
    @State private var status: String?
    @State private var isLoading = false

    var body: some View {
        Form {
            TextField("GitHub username", text: $username, prompt: Text("sharvesh300"))
            SecureField("Token (optional)", text: $token, prompt: Text("github_pat_…"))
            HStack {
                Button("Save and refresh", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoading)
                if isLoading { ProgressView().controlSize(.small) }
            }
            if let status {
                Text(status).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    private func save() {
        store.username = username
        do {
            try store.setToken(token)
        } catch {
            status = error.localizedDescription
            return
        }
        isLoading = true
        Task {
            let result = await store.loadCalendar()
            isLoading = false
            WidgetCenter.shared.reloadAllTimelines()
            switch result {
            case .fresh(let calendar):
                let stats = calendar.stats
                status = "\(calendar.totalContributions.formatted()) contributions · \(stats.currentStreak)-day streak"
            case .cached(_, let error), .failed(let error):
                status = error.localizedDescription
            }
        }
    }
}

#Preview {
    SettingsView()
}
