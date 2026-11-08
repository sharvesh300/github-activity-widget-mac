import Foundation
import Testing
@testable import GitHubActivity

/// A store in its own temporary folder. Pass the same folder twice to act like
/// two processes (the app and a widget) sharing one settings folder.
func makeTestStore(in directory: URL = FileManager.default.temporaryDirectory
    .appending(path: "GitHubActivityTests-\(UUID().uuidString)", directoryHint: .isDirectory)) -> ContributionStore {
    ContributionStore(directory: directory, keychain: TokenKeychain(service: "GitHubActivityTests.\(UUID().uuidString)"))
}

private func makeStore() -> ContributionStore {
    makeTestStore()
}

/// Settings live in files, so a new widget (a new process) sees what was saved before.
struct LocalStorageTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "GitHubActivityTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func usernameIsRememberedByTheNextWidget() {
        makeTestStore(in: folder).adoptUsername(fromWidgetInputs: ["sharvesh300"])
        // A widget added later starts a fresh store on the same folder.
        #expect(makeTestStore(in: folder).username == "sharvesh300")
    }

    @Test func appAndWidgetsSeeTheSameSettings() {
        let app = makeTestStore(in: folder)
        let widget = makeTestStore(in: folder)
        app.username = "sharvesh300"
        app.theme = .ocean
        #expect(widget.username == "sharvesh300")
        #expect(widget.theme == .ocean)
    }

    @Test func themeDefaultsToGitHubAndIsRemembered() {
        #expect(makeTestStore(in: folder).theme == .github)
        makeTestStore(in: folder).theme = .amber
        #expect(makeTestStore(in: folder).theme == .amber)
    }

    @Test func savingOneSettingKeepsTheOthers() {
        let store = makeTestStore(in: folder)
        store.username = "sharvesh300"
        store.theme = .mono
        store.adoptUsername(fromWidgetInputs: [])
        #expect(store.username == "sharvesh300")
        #expect(store.theme == .mono)
    }

    @Test func cachedDataIsSharedToo() throws {
        let app = makeTestStore(in: folder)
        app.cache(.sample)
        app.cacheAvatar(Data([1, 2, 3]), for: "sharvesh300")
        let widget = makeTestStore(in: folder)
        #expect(widget.cachedCalendar(for: "sharvesh300")?.days.count == ContributionCalendar.sample.days.count)
        #expect(widget.cachedAvatar(for: "sharvesh300") == Data([1, 2, 3]))

        widget.clearCache()
        #expect(app.cachedCalendar(for: "sharvesh300") == nil)
    }

    @Test func unwritableFoldersAreDetected() {
        #expect(StorageLocation.isWritable(folder))
        #expect(!StorageLocation.isWritable(URL(fileURLWithPath: "/System/GitHubActivityTests")))
    }

    @Test func sharedFolderIsInTheRealHomeNotTheSandbox() throws {
        let path = try #require(StorageLocation.sharedFolder).path
        #expect(path.hasSuffix("/Library/Application Support/GitHub Activity"))
        #expect(!path.contains("/Library/Containers/"))
    }
}

/// One username for every widget: typing it into any widget's Edit Widget panel
/// sets it everywhere, and it stays until a different one is entered.
struct SharedUsernameTests {
    @Test func aUsernameTypedIntoAWidgetBecomesEveryones() {
        let store = makeStore()
        #expect(store.adoptUsername(fromWidgetInputs: ["sharvesh300"]))
        #expect(store.username == "sharvesh300")
    }

    @Test func itStaysWhileNothingNewIsTyped() {
        let store = makeStore()
        store.adoptUsername(fromWidgetInputs: ["sharvesh300"])
        // Other widgets reloading with the same configuration change nothing.
        #expect(!store.adoptUsername(fromWidgetInputs: ["sharvesh300"]))
        #expect(!store.adoptUsername(fromWidgetInputs: ["sharvesh300"]))
        #expect(store.username == "sharvesh300")
    }

    @Test func theNewestEntryWinsOverAnOldOneInAnotherWidget() {
        let store = makeStore()
        store.adoptUsername(fromWidgetInputs: ["alice"])                     // widget A
        #expect(store.adoptUsername(fromWidgetInputs: ["alice", "bob"]))      // widget B typed "bob"
        #expect(store.username == "bob")
        // Widget A still says "alice", but that's old news: it must not switch back.
        #expect(!store.adoptUsername(fromWidgetInputs: ["alice", "bob"]))
        #expect(store.username == "bob")
    }

    @Test func retypingANameAnotherWidgetAlreadyHasStillCounts() {
        let store = makeStore()
        store.adoptUsername(fromWidgetInputs: ["alice"])
        store.adoptUsername(fromWidgetInputs: ["alice", "bob"])
        // Widget B changes from "bob" to "alice", which widget A already shows.
        #expect(store.adoptUsername(fromWidgetInputs: ["alice", "alice"]))
        #expect(store.username == "alice")
    }

    @Test func theAppCanChangeItAndOldWidgetEntriesDontUndoIt() {
        let store = makeStore()
        store.adoptUsername(fromWidgetInputs: ["alice"])
        store.username = "sharvesh300"                                      // changed in the app
        #expect(!store.adoptUsername(fromWidgetInputs: ["alice"]))
        #expect(store.username == "sharvesh300")
    }

    @Test func clearingAWidgetsFieldKeepsTheUsername() {
        let store = makeStore()
        store.adoptUsername(fromWidgetInputs: ["sharvesh300"])
        #expect(!store.adoptUsername(fromWidgetInputs: []))
        #expect(store.username == "sharvesh300")
    }

    @Test func caseAndFormattingDontCountAsANewName() {
        let store = makeStore()
        store.adoptUsername(fromWidgetInputs: ["sharvesh300"])
        #expect(!store.adoptUsername(fromWidgetInputs: ["@Sharvesh300"]))
        #expect(store.username == "sharvesh300")
    }

    @Test func invalidEntriesAreIgnored() {
        let store = makeStore()
        #expect(!store.adoptUsername(fromWidgetInputs: ["not a username!", ""]))
        #expect(store.username == nil)
    }
}

@MainActor
struct SettingsModelTests {
    /// Every request fails quickly: the proxy points at a closed local port.
    private static let unreachable = GitHubService(session: URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 9]
        configuration.timeoutIntervalForRequest = 5
        return configuration
    }()), retryDelays: [])

    private func makeModel(_ store: ContributionStore = makeStore()) -> AccountModel {
        AccountModel(store: store, service: Self.unreachable)
    }

    @Test func startsWithoutAUsername() {
        let model = makeModel()
        #expect(model.username == nil)
        #expect(model.calendar == nil)
    }

    @Test func choosingAThemeSavesItForEveryWidget() {
        let store = makeStore()
        let model = makeModel(store)
        #expect(model.theme == .github)
        model.setTheme(.ocean)
        #expect(model.theme == .ocean)
        #expect(store.theme == .ocean)
        #expect(makeModel(store).theme == .ocean)
    }

    @Test func remembersTheSavedUsername() {
        let store = makeStore()
        store.username = "sharvesh300"
        #expect(makeModel(store).username == "sharvesh300")
    }

    @Test func savingAUsernameSharesItWithWidgets() {
        let store = makeStore()
        let model = makeModel(store)
        #expect(model.setUsername("https://github.com/sharvesh300"))
        #expect(model.username == "sharvesh300")
        #expect(store.username == "sharvesh300")
        #expect(model.errorMessage == nil)
    }

    @Test func emptyUsernameAsksForOneInsteadOfCallingItInvalid() {
        let model = makeModel()
        #expect(!model.setUsername("   "))
        #expect(model.errorMessage == "Enter a GitHub username.")
        #expect(model.username == nil)
    }

    @Test func invalidUsernameIsExplained() {
        let model = makeModel()
        #expect(!model.setUsername("not valid!"))
        #expect(model.errorMessage == GitHubError.invalidUsername.localizedDescription)
    }

    @Test func picksUpAUsernameAWidgetSetWhileTheAppWasClosed() async {
        let store = makeStore()
        let model = makeModel(store)
        store.adoptUsername(fromWidgetInputs: ["sharvesh300"])
        await model.refreshIfStale()
        #expect(model.username == "sharvesh300")
    }

    @Test func aLoadThatFinishesAfterChangingUsernameIsIgnored() async {
        let model = makeModel()
        model.setUsername("octocat")
        let loading = Task { await model.refresh() }
        while !model.isRefreshing { await Task.yield() }

        model.setUsername("sharvesh300")    // changed while octocat was loading
        await loading.value                 // octocat's failed load lands now

        #expect(model.username == "sharvesh300")
        #expect(model.errorMessage == nil)
        #expect(model.isRefreshing == false)
    }
}
