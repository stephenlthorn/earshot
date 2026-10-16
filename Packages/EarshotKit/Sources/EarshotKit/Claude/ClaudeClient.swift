import Foundation

/// Who is asking. It picks the model and effort in Settings and the place in the queue for a `claude` child.
public enum ClaudeRole: String, Codable, Sendable, CaseIterable {
    case notes, live, brief, ask, fix

    /// Lower goes first: notes, fix, ask, brief, live (spec 3.2).
    var rank: Int {
        switch self {
        case .notes: 0
        case .fix: 1
        case .ask: 2
        case .brief: 3
        case .live: 4
        }
    }
}

/// One structured completion: the answer is a JSON object that matches `schema`.
public struct ClaudeRequest: Equatable, Sendable {
    public var role: ClaudeRole
    public var system: String
    public var user: String
    /// A JSON Schema, as JSON text.
    public var schema: String
    public var model: String
    public var effort: String
    /// Used by the API. Claude Code has no flag for it.
    public var maxTokens: Int
    public var timeout: Duration

    public init(role: ClaudeRole, system: String, user: String, schema: String, model: String,
                effort: String, maxTokens: Int = 16_000, timeout: Duration = .seconds(600)) {
        self.role = role
        self.system = system
        self.user = user
        self.schema = schema
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.timeout = timeout
    }
}

/// The only way a feature talks to Claude (spec 3.2). Errors are `NotesError`, `ClaudeBusy` or
/// `CancellationError`.
public protocol ClaudeClient: Sendable {
    /// The JSON object Claude returned, as data.
    func structured(_ request: ClaudeRequest) async throws -> Data
}

extension ClaudeClient {
    public func decode<T: Decodable>(_ type: T.Type, _ request: ClaudeRequest) async throws -> T {
        let data = try await structured(request)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NotesError.badOutput("it did not match the expected format")
        }
    }
}

/// A live pass found no free `claude` slot, so it was skipped instead of queued (spec 3.2).
public struct ClaudeBusy: Error, Equatable, LocalizedError {
    public init() {}
    public var errorDescription: String? { "Claude is busy with other work, so this pass was skipped." }
}

/// Turns what Claude or Claude Code said about a failure into the error the user sees.
enum ClaudeFailure {
    static func error(_ said: String, status: Int32, model: String) -> NotesError {
        let text = said.lowercased()
        let detail = String(said.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))
        if text.contains("unknown option") { return .claudeTooOld(detail) }
        if ["usage limit", "rate limit", "limit reached"].contains(where: text.contains) { return .usageLimit(detail) }
        if saysSignedOut(text) { return .notSignedIn(detail) }
        if isModelProblem(text) { return .modelUnavailable(model) }
        return .claudeFailed(status: status, message: detail)
    }

    /// True when Claude Code says its login is missing, expired or rejected: "Login expired", "please run /login",
    /// "Failed to authenticate: OAuth session expired and could not be refreshed", or the API's
    /// `authentication_error`. Takes lowercased text.
    static func saysSignedOut(_ lowercased: String) -> Bool {
        let phrases = ["not logged in", "login expired", "invalid api key", "failed to authenticate", "authentication_error"]
        return phrases.contains(where: lowercased.contains) || saysRunLogin(lowercased)
            || (lowercased.contains("oauth") && lowercased.contains("expired"))
    }

    /// The `/login` command on its own ("please run /login", "`/login`"), never a path such as /Users/loginov.
    static func saysRunLogin(_ lowercased: String) -> Bool {
        lowercased.range(of: #"(?<![\w/.~-])/login(?![\w/-])"#, options: .regularExpression) != nil
    }

    static func isModelProblem(_ lowercased: String) -> Bool {
        lowercased.contains("model") && ["not available", "not found", "access"].contains(where: lowercased.contains)
    }
}
