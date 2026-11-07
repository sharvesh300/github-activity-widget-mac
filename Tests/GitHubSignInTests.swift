import Foundation
import Testing
@testable import GitHubActivity

/// Plays GitHub's side of the device flow from a script of JSON replies.
private actor FakeGitHub {
    private var replies: [String]
    private(set) var requests: [URLRequest] = []
    private(set) var sleeps: [Duration] = []

    init(_ replies: [String]) { self.replies = replies }

    func reply(to request: URLRequest) -> Data {
        requests.append(request)
        return Data(replies.removeFirst().utf8)
    }

    func recordSleep(_ duration: Duration) { sleeps.append(duration) }
}

private func makeFlow(_ github: FakeGitHub, now: Date = Date(timeIntervalSince1970: 0)) -> DeviceFlowSignIn {
    DeviceFlowSignIn(
        clientID: "Ov23testclient",
        send: { request in (await github.reply(to: request), URLResponse()) },
        sleep: { await github.recordSleep($0) },
        now: { now }
    )
}

private let code = DeviceFlowSignIn.Code(
    userCode: "WDJB-MJHT",
    deviceCode: "dev-123",
    verificationURL: URL(string: "https://github.com/login/device")!,
    expiresAt: Date(timeIntervalSince1970: 900),
    interval: 5
)

private func body(_ request: URLRequest?) -> String {
    request?.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
}

struct DeviceFlowTests {
    @Test func requestsACodeWithTheClientID() async throws {
        let github = FakeGitHub([#"""
        {"device_code":"dev-123","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
        """#])

        let received = try await makeFlow(github).requestCode()

        #expect(received == code)
        let request = await github.requests.first
        #expect(request?.url?.absoluteString == "https://github.com/login/device/code")
        #expect(request?.httpMethod == "POST")
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(body(request) == "client_id=Ov23testclient")
    }

    @Test(arguments: [
        #"{"error":"Not Found"}"#,  // what github.com returns for an unregistered Client ID
        #"{"error":"incorrect_client_credentials"}"#,
    ])
    func unknownClientIDIsExplained(reply: String) async {
        let github = FakeGitHub([reply])
        await #expect(throws: DeviceFlowSignIn.Failure.unknownClientID) {
            try await makeFlow(github).requestCode()
        }
    }

    @Test func pollsUntilApprovedAndBacksOffWhenAsked() async throws {
        let github = FakeGitHub([
            #"{"error":"authorization_pending"}"#,
            #"{"error":"slow_down","interval":10}"#,
            #"{"access_token":"gho_token","token_type":"bearer","scope":""}"#,
        ])

        let token = try await makeFlow(github).waitForToken(code)

        #expect(token == "gho_token")
        #expect(await github.sleeps == [.seconds(5), .seconds(5), .seconds(10)])
        let requests = await github.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.url?.absoluteString == "https://github.com/login/oauth/access_token" })
        let firstBody = body(requests.first)
        #expect(firstBody.contains("device_code=dev-123"))
        #expect(firstBody.contains("grant_type=urn:ietf:params:oauth:grant-type:device_code"))
        #expect(!firstBody.contains("client_secret"))
    }

    @Test(arguments: [
        ("access_denied", DeviceFlowSignIn.Failure.denied),
        ("expired_token", .expired),
        ("device_flow_disabled", .deviceFlowDisabled),
    ])
    func stopsOnTerminalErrors(error: String, expected: DeviceFlowSignIn.Failure) async {
        let github = FakeGitHub([#"{"error":"\#(error)"}"#])
        await #expect(throws: expected) {
            try await makeFlow(github).waitForToken(code)
        }
    }

    @Test func givesUpOnceTheCodeHasExpired() async {
        let github = FakeGitHub([])
        await #expect(throws: DeviceFlowSignIn.Failure.expired) {
            try await makeFlow(github, now: Date(timeIntervalSince1970: 1000)).waitForToken(code)
        }
        #expect(await github.requests.isEmpty)
    }

    @Test func unreadableRepliesAreReported() async {
        let github = FakeGitHub(["<html>rate limited</html>"])
        await #expect(throws: DeviceFlowSignIn.Failure.self) {
            try await makeFlow(github).requestCode()
        }
    }
}

struct ViewerTests {
    @Test func parsesTheSignedInAccount() throws {
        let data = Data(#"{"data":{"viewer":{"login":"sharvesh300","name":"Sharvesh Sivagnanam","avatarUrl":"https://avatars.githubusercontent.com/u/86187069?v=4"}}}"#.utf8)
        let profile = try GitHubService.parseViewer(data)
        #expect(profile.login == "sharvesh300")
        #expect(profile.name == "Sharvesh Sivagnanam")
        #expect(profile.avatarURL != nil)
    }

    @Test func rejectsAMissingViewer() {
        #expect(throws: GitHubError.unexpectedResponse) {
            try GitHubService.parseViewer(Data(#"{"message":"Bad credentials"}"#.utf8))
        }
    }
}

@MainActor
struct AccountModelTests {
    private func makeStore() -> ContributionStore {
        let suite = "GitHubActivityTests.\(UUID().uuidString)"
        return ContributionStore(defaults: UserDefaults(suiteName: suite)!, keychain: TokenKeychain(service: suite))
    }

    @Test func startsSignedOut() {
        #expect(AccountModel(store: makeStore(), clientID: "Ov23x").state == .signedOut)
    }

    @Test func remembersAPublicProfile() {
        let store = makeStore()
        store.username = "sharvesh300"
        #expect(AccountModel(store: store, clientID: nil).state == .publicProfile("sharvesh300"))
    }

    @Test func explainsMissingClientID() {
        let model = AccountModel(store: makeStore(), clientID: nil)
        #expect(model.canSignIn == false)
        model.signIn()
        #expect(model.state == .signedOut)
        #expect(model.errorMessage?.contains("GITHUB_CLIENT_ID") == true)
    }

    @Test func emptyUsernameAsksForOneInsteadOfCallingItInvalid() async {
        let model = AccountModel(store: makeStore(), clientID: nil)
        await model.usePublicProfile("   ")
        #expect(model.errorMessage == "Enter a GitHub username.")
        #expect(model.state == .signedOut)
    }

    @Test func storeSignOutForgetsEverything() throws {
        let store = makeStore()
        store.username = "sharvesh300"
        store.account = GitHubProfile(login: "sharvesh300", name: "Sharvesh")
        store.cache(ContributionCalendar.sample)
        #expect(store.account?.name == "Sharvesh")

        store.signOut()

        #expect(store.account == nil)
        #expect(store.username == nil)
        #expect(store.cachedCalendar == nil)
    }
}
