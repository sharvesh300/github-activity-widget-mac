import SwiftUI

@main
struct GitHubActivityApp: App {
    var body: some Scene {
        Window("GitHub Activity", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}
