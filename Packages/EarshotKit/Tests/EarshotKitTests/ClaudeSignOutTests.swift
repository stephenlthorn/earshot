import Foundation
import Testing
@testable import EarshotKit

/// What Claude Code printed on 2026-10-15 when its login could no longer be refreshed.
private let oauthExpired = "Failed to authenticate: OAuth session expired and could not be refreshed"
/// The API's own answer to an expired token, as Claude Code passes it on.
private let apiAuthError = #"API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"OAuth token has expired. Please obtain a new token or refresh your existing token."}}"#

/// Claude Code's real sign-out messages (spec 3.1) become "not signed in", in a run and in the status check.
struct ClaudeSignOutTests {
    @Test func theExpiredOAuthSessionIsNotSignedIn() {
        for said in [oauthExpired, apiAuthError, "OAuth token expired", "Error: oauth session has EXPIRED",
                     "authentication_error: invalid bearer token"] {
            #expect(ClaudeFailure.error(said, status: 1, model: "claude-opus-5-5") == .notSignedIn(said), "\(said)")
        }
        // "OAuth" or "expired" alone is not a sign-out.
        for said in ["OAuth callback server failed to start", "The cache entry expired"] {
            #expect(ClaudeFailure.error(said, status: 1, model: "m") == .claudeFailed(status: 1, message: said), "\(said)")
        }
    }

    @Test func aRunThatFailsWithTheExpiredSessionThrowsNotSignedIn() async {
        let inResult = claudeEnvelope(["type": "result", "subtype": "success", "is_error": true, "result": oauthExpired])
        for output in [claudeOutput(inResult, status: 1), claudeOutput(inResult, status: 0),
                       claudeOutput("", status: 1, stderr: oauthExpired + "\n")] {
            await #expect(throws: NotesError.notSignedIn(oauthExpired)) {
                try await codeClient(FakeRunner(output)).structured(notesRequest())
            }
        }
        await #expect(throws: NotesError.notSignedIn(apiAuthError)) {
            try await codeClient(FakeRunner(claudeOutput(apiAuthError, status: 1))).structured(notesRequest())
        }
    }

    @Test func theStatusCheckSaysNotSignedInForTheExpiredSession() async {
        let version = claudeOutput("2.1.296 (Claude Code)\n")
        let line = "Claude Code is not signed in: run `claude` in Terminal and log in"
        let outputs = [
            // Signed in on paper, but the login can't be refreshed.
            claudeOutput(authJSON(), stderr: oauthExpired + "\n"),
            claudeOutput(authJSON(), status: 1, stderr: apiAuthError),
            claudeOutput(oauthExpired + "\n", status: 1),
        ]
        for output in outputs {
            let s = await status(version, output).0
            #expect(s.state == .notSignedIn && s.summary == line, "\(output.stdout)\(output.stderr)")
        }
        // Text on stderr that isn't a sign-out leaves a signed-in status alone.
        let warning = await status(version, claudeOutput(authJSON(), stderr: "Warning: update available\n")).0
        #expect(warning.state == .ready)
    }
}

/// The Settings tab for Claude is "Claude" now, not "Notes".
struct NotesErrorWordingTests {
    @Test func everyMessageNamesTheClaudeTab() {
        #expect(NotesError.missingKey.errorDescription == "No Claude API key is set. Add one in Settings, Claude.")
        #expect(NotesError.badKey.errorDescription == "Anthropic rejected the API key. Check it in Settings, Claude.")
        #expect(NotesError.claudeNotFound.errorDescription
                == "Claude Code wasn't found. Install it, or set its path in Settings, Claude.")
        let all: [NotesError] = [.missingKey, .badKey, .refused, .truncated, .claudeNotFound, .http(status: 500, message: "x"),
                                 .badOutput("x"), .claudeFailed(status: 1, message: "x"), .notSignedIn("x"),
                                 .usageLimit("x"), .claudeTooOld("x"), .modelUnavailable("m")]
        #expect(all.allSatisfy { !($0.errorDescription ?? "").contains("Settings, Notes") })
        #expect(all.allSatisfy { !($0.errorDescription ?? "").contains("\u{2014}") })
    }
}
