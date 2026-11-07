import Foundation

/// "Sign in with GitHub" using the OAuth device flow, the same flow the `gh` CLI uses.
///
/// The app shows a short code, the user enters it at github.com/login/device, and
/// the app polls until GitHub hands back a token. Only the OAuth App's public
/// Client ID is needed, with no client secret, so this is safe to ship in open
/// source. See https://docs.github.com/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow
struct DeviceFlowSignIn: Sendable {
    struct Code: Equatable, Sendable {
        /// What the user types on GitHub, e.g. `WDJB-MJHT`.
        let userCode: String
        let deviceCode: String
        let verificationURL: URL
        let expiresAt: Date
        /// Seconds GitHub asks us to wait between polls.
        let interval: Int
    }

    enum Failure: LocalizedError, Equatable {
        case notConfigured
        case unknownClientID
        case denied
        case expired
        case deviceFlowDisabled
        case network(String)
        case unexpected(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Sign-in isn't set up in this build. Add your OAuth App's Client ID to GITHUB_CLIENT_ID."
            case .unknownClientID: "GitHub doesn't recognise this build's Client ID. Check GITHUB_CLIENT_ID matches your OAuth App."
            case .denied: "Sign-in was cancelled on GitHub."
            case .expired: "The code expired before it was entered. Try again."
            case .deviceFlowDisabled: "Device Flow is turned off for this OAuth App. Enable it in the app's settings on GitHub."
            case .network(let message): "Couldn't reach GitHub. \(message)"
            case .unexpected(let message): "GitHub couldn't complete sign-in. \(message)"
            }
        }
    }

    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias Sleep = @Sendable (Duration) async throws -> Void

    let clientID: String
    /// Leave empty to only read public data (all the contribution graph needs).
    var scopes: [String] = []
    var send: Send = { try await URLSession.shared.data(for: $0) }
    var sleep: Sleep = { try await Task.sleep(for: $0) }
    var now: @Sendable () -> Date = { .now }

    /// The Client ID baked into this build, or `nil` if none was set.
    static var configuredClientID: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "GitHubClientID") as? String
        guard let value, !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    // MARK: Steps

    /// Step 1: ask GitHub for a code to show the user.
    func requestCode() async throws -> Code {
        var fields = ["client_id": clientID]
        if !scopes.isEmpty { fields["scope"] = scopes.joined(separator: " ") }
        let json = try await post("https://github.com/login/device/code", fields)

        if let error = json["error"] as? String { throw Self.failure(for: error, json) }
        guard let userCode = json["user_code"] as? String,
              let deviceCode = json["device_code"] as? String,
              let uri = json["verification_uri"] as? String, let verificationURL = URL(string: uri),
              let expiresIn = json["expires_in"] as? Int
        else { throw Failure.unexpected("The sign-in code response was incomplete.") }

        return Code(
            userCode: userCode,
            deviceCode: deviceCode,
            verificationURL: verificationURL,
            expiresAt: now().addingTimeInterval(TimeInterval(expiresIn)),
            interval: json["interval"] as? Int ?? 5
        )
    }

    /// Step 2: poll until the user approves (returns the token) or the flow fails.
    func waitForToken(_ code: Code) async throws -> String {
        var interval = max(1, code.interval)
        while true {
            try await sleep(.seconds(interval))
            guard now() < code.expiresAt else { throw Failure.expired }

            let json = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = json["access_token"] as? String, !token.isEmpty {
                return token
            }
            switch json["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                // GitHub sends the new interval; it's always at least 5s longer.
                interval = json["interval"] as? Int ?? interval + 5
            case let error?:
                throw Self.failure(for: error, json)
            case nil:
                throw Failure.unexpected("GitHub didn't return a token.")
            }
        }
    }

    // MARK: Helpers

    private static func failure(for error: String, _ json: [String: Any]) -> Failure {
        switch error {
        case "access_denied": .denied
        case "expired_token", "token_expired": .expired
        case "device_flow_disabled": .deviceFlowDisabled
        // An unregistered Client ID gets {"error":"Not Found"} from the device code endpoint.
        case "Not Found", "incorrect_client_credentials", "unauthorized_client": .unknownClientID
        default: .unexpected(json["error_description"] as? String ?? error)
        }
    }

    private func post(_ url: String, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("GitHubActivityWidget/1.0", forHTTPHeaderField: "User-Agent")
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let data: Data
        do {
            (data, _) = try await send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unexpected("GitHub sent a response the app couldn't read.")
        }
        return json
    }
}
