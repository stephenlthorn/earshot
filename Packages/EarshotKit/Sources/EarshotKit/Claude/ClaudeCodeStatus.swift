import Foundation

/// Whether the user's Claude Code can run Earshot's calls on their plan. Free and local: it runs
/// `claude --version` and `claude auth status` with the child environment, and never calls a model (spec 3.1).
public struct ClaudeCodeStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case ready
        case notFound
        case tooOld(String)
        case notSignedIn
        /// Claude Code is signed in another way (the value is its `authMethod`), so calls wouldn't use the plan.
        case otherAuth(String)
    }

    public var state: State
    public var path: String?
    public var version: String?
    /// The plan, as `auth status` names it ("max", "pro", ...).
    public var subscription: String?
    /// Why a Claude Code that was found could not start (what it printed, or how it ended), or nil.
    public var problem: String?
    /// The line Settings and onboarding show. It always follows the other fields.
    public var summary: String { Self.summary(state, version: version, subscription: subscription, problem: problem) }

    public static let minimumVersion = "2.1.259"

    public init(state: State, path: String?, version: String?, subscription: String?, problem: String? = nil) {
        self.state = state
        self.path = path
        self.version = version
        self.subscription = subscription
        self.problem = problem
    }

    public static func check(path: String?, runner: any ProcessRunning = ProcessRunner()) async -> ClaudeCodeStatus {
        guard let path, !path.isEmpty else { return ClaudeCodeStatus(state: .notFound, path: nil, version: nil, subscription: nil) }
        let environment = ClaudeEnvironment.child(claudePath: path)
        func run(_ arguments: [String]) async -> ProcessOutput? {
            try? await runner.run(path, arguments, stdin: nil, directory: nil, environment: environment,
                                  inheritEnvironment: false, timeout: .seconds(10))
        }
        // A runner that throws could not launch the file at all: that is "not found".
        guard let versionOut = await run(["--version"]) else {
            return ClaudeCodeStatus(state: .notFound, path: path, version: nil, subscription: nil)
        }
        guard versionOut.status == 0, !versionOut.timedOut, let version = Self.version(in: versionOut.stdout) else {
            return ClaudeCodeStatus(state: .notFound, path: path, version: nil, subscription: nil,
                                    problem: Self.problem(versionOut))
        }
        if Self.isOlder(version, than: minimumVersion) {
            return ClaudeCodeStatus(state: .tooOld(version), path: path, version: version, subscription: nil)
        }
        let auth = await run(["auth", "status"])
        let (state, plan) = Self.authState(auth)
        return ClaudeCodeStatus(state: state, path: path, version: version, subscription: plan)
    }

    /// The first line of what a `--version` that failed printed, or how it ended.
    static func problem(_ out: ProcessOutput) -> String {
        if out.timedOut { return "it did not answer in time" }
        let said = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? out.stdout : out.stderr
        let line = said.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        guard let line else { return out.status == 0 ? "it printed no version" : "exit \(out.status)" }
        return String(line.prefix(160))
    }

    /// "2.1.296 (Claude Code)" gives "2.1.296".
    static func version(in text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .first { $0.first?.isNumber == true && $0.contains(".") }
    }

    static func isOlder(_ version: String, than minimum: String) -> Bool {
        let numbers = { (text: String) in text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let (a, b) = (numbers(version), numbers(minimum))
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x < y }
        }
        return false
    }

    /// The JSON decides whenever there is JSON: a signed-in status names the user's folders, and a folder name
    /// must never read as a sign-in hint. Text that is not JSON is never a sign-in. The one exception is stderr
    /// saying the login can't be used ("Failed to authenticate: OAuth session expired and could not be refreshed"):
    /// the stored login is still listed, but no call would work.
    static func authState(_ out: ProcessOutput?) -> (State, String?) {
        guard let out, !out.timedOut, !ClaudeFailure.saysSignedOut(out.stderr.lowercased()),
              let object = (try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8))) as? [String: Any],
              object["loggedIn"] as? Bool == true else { return (.notSignedIn, nil) }
        let plan = (object["subscriptionType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch object["authMethod"] as? String ?? "none" {
        case "claude.ai": return (.ready, plan)
        case "none": return (.notSignedIn, nil)
        case let other: return (.otherAuth(other), plan)
        }
    }

    static func summary(_ state: State, version: String?, subscription: String?, problem: String? = nil) -> String {
        switch state {
        case .ready:
            if let plan = subscription { return "Signed in to Claude (\(planName(plan))) through Claude Code" }
            return "Signed in to Claude through Claude Code"
        case .notFound:
            if let problem { return "Claude Code can't start: \(problem)" }
            return "Claude Code not found"
        case let .tooOld(version):
            return "Claude Code \(version) is too old; update it"
        case .notSignedIn:
            return "Claude Code is not signed in: run `claude` in Terminal and log in"
        case let .otherAuth(method):
            let what = switch method {
            case "api_key": "an API key"
            case "api_key_helper": "an API key helper"
            case "oauth_token": "a token"
            default: "another provider"
            }
            return "Claude Code is set to use \(what), not your subscription"
        }
    }

    /// "max" gives "Max"; "pro" gives "Pro".
    static func planName(_ plan: String) -> String {
        plan.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
