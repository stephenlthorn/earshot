import Foundation
import Testing
@testable import EarshotKit

func authJSON(loggedIn: Bool = true, method: String = "claude.ai", plan: String? = "max") -> String {
    var object: [String: Any] = ["loggedIn": loggedIn, "authMethod": method, "apiProvider": "firstParty"]
    if let plan { object["subscriptionType"] = plan }
    return claudeEnvelope(object)
}

/// The status from `claude --version` printing `version`, then `claude auth status` printing `auth`.
func status(_ version: ProcessOutput, _ auth: ProcessOutput? = nil) async -> (ClaudeCodeStatus, FakeRunner) {
    let runner = auth.map { FakeRunner(version, $0) } ?? FakeRunner(version)
    return (await ClaudeCodeStatus.check(path: "/opt/homebrew/bin/claude", runner: runner), runner)
}

struct ClaudeStatusTests {
    let version = claudeOutput("2.1.296 (Claude Code)\n")

    @Test func signedInWithThePlan() async throws {
        let (s, runner) = await status(version, claudeOutput(authJSON()))
        #expect(s.state == .ready && s.version == "2.1.296" && s.subscription == "max")
        #expect(s.path == "/opt/homebrew/bin/claude")
        #expect(s.summary == "Signed in to Claude (Max) through Claude Code")
        #expect(runner.calls.map(\.arguments) == [["--version"], ["auth", "status"]])
        // The check sees what a real call would see: the same allowlist environment.
        #expect(runner.calls.allSatisfy { !$0.inheritEnvironment && $0.environment["ANTHROPIC_API_KEY"] == nil })
        #expect(runner.calls.allSatisfy { $0.executable == "/opt/homebrew/bin/claude" })
        #expect(runner.calls.allSatisfy { $0.timeout == .seconds(10) }, "the check is local and quick")
        let pro = await status(version, claudeOutput(authJSON(plan: "pro"))).0
        #expect(pro.summary == "Signed in to Claude (Pro) through Claude Code")
        let unknownPlan = await status(version, claudeOutput(authJSON(plan: nil))).0
        #expect(unknownPlan.state == .ready && unknownPlan.summary == "Signed in to Claude through Claude Code")
    }

    @Test func notFound() async {
        let none = await ClaudeCodeStatus.check(path: nil, runner: FakeRunner())
        #expect(none.state == .notFound && none.summary == "Claude Code not found")
        let gone = await ClaudeCodeStatus.check(path: "/bin/claude", runner: ThrowingRunner(error: CocoaError(.fileNoSuchFile)))
        #expect(gone.state == .notFound && gone.summary == "Claude Code not found")
    }

    /// Found but it can't start, as when an npm install's node isn't on the PATH: the line says so and names why,
    /// instead of telling the user to install what they have.
    @Test func foundButCannotStart() async {
        let node = await status(claudeOutput("", status: 127, stderr: "env: node: No such file or directory\n")).0
        #expect(node.state == .notFound && node.path == "/opt/homebrew/bin/claude")
        #expect(node.problem == "env: node: No such file or directory")
        #expect(node.summary == "Claude Code can't start: env: node: No such file or directory")
        let broken = await status(claudeOutput("", status: 126, stderr: "permission denied")).0
        #expect(broken.state == .notFound && broken.summary == "Claude Code can't start: permission denied")
        let silent = await status(claudeOutput("", status: 134)).0
        #expect(silent.summary == "Claude Code can't start: exit 134")
        let slow = await status(ProcessOutput(status: -1, stdout: "", stderr: "", timedOut: true)).0
        #expect(slow.summary == "Claude Code can't start: it did not answer in time")
        let long = await status(claudeOutput("", status: 1, stderr: "first line\n" + String(repeating: "x", count: 500))).0
        #expect(long.problem == "first line")
    }

    @Test func theSummaryFollowsTheState() {
        var s = ClaudeCodeStatus(state: .notFound, path: nil, version: nil, subscription: nil)
        s.state = .ready
        s.subscription = "pro"
        #expect(s.summary == "Signed in to Claude (Pro) through Claude Code")
        #expect(s == ClaudeCodeStatus(state: .ready, path: nil, version: nil, subscription: "pro"))
    }

    /// A signed-in status names the user's folders. A home folder that starts with "login" is not a "/login" hint.
    @Test func theJSONDecidesWhenThereIsJSON() async {
        let object: [String: Any] = ["loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "max",
                                     "projectsDirectory": "/Users/loginov/.claude/projects",
                                     "configDirectory": "/Users/loginov/.claude"]
        let s = await status(version, claudeOutput(claudeEnvelope(object))).0
        #expect(s.state == .ready && s.subscription == "max")
    }

    @Test func tooOld() async {
        let (s, runner) = await status(claudeOutput("2.1.258 (Claude Code)\n"))
        #expect(s.state == .tooOld("2.1.258") && s.summary == "Claude Code 2.1.258 is too old; update it")
        #expect(runner.calls.count == 1, "auth status is not asked of a Claude Code that is too old")
        #expect(await status(claudeOutput("1.0.99 (Claude Code)"), claudeOutput(authJSON())).0.state == .tooOld("1.0.99"))
        #expect(await status(claudeOutput("2.1.259 (Claude Code)"), claudeOutput(authJSON())).0.state == .ready)
        #expect(await status(claudeOutput("2.10.0 (Claude Code)"), claudeOutput(authJSON())).0.state == .ready)
    }

    @Test func notSignedIn() async {
        let line = "Claude Code is not signed in: run `claude` in Terminal and log in"
        let outputs = [
            claudeOutput(authJSON(loggedIn: false, method: "none", plan: nil), status: 1),
            claudeOutput("", status: 1, stderr: "Login expired · Please run /login"),
            claudeOutput("Login expired. Please run /login\n"),
            claudeOutput(claudeEnvelope(["loggedIn": true])),
            claudeOutput("garbage"),
        ]
        for output in outputs {
            let s = await status(version, output).0
            #expect(s.state == .notSignedIn && s.summary == line, "\(output.stdout)\(output.stderr)")
        }
    }

    @Test func anotherSignInMethodIsNotTheSubscription() async {
        let cases = [("api_key", "an API key"), ("api_key_helper", "an API key helper"), ("oauth_token", "a token"),
                     ("third_party", "another provider")]
        for (method, words) in cases {
            let s = await status(version, claudeOutput(authJSON(method: method, plan: nil))).0
            #expect(s.state == .otherAuth(method))
            #expect(s.summary == "Claude Code is set to use \(words), not your subscription")
        }
    }

    @Test func versionsCompareByNumber() {
        #expect(ClaudeCodeStatus.isOlder("2.1.99", than: "2.1.259"))
        #expect(!ClaudeCodeStatus.isOlder("2.1.259", than: "2.1.259"))
        #expect(!ClaudeCodeStatus.isOlder("3.0", than: "2.1.259"))
        #expect(ClaudeCodeStatus.version(in: "2.1.296 (Claude Code)") == "2.1.296")
        #expect(ClaudeCodeStatus.version(in: "no version here") == nil)
    }
}
