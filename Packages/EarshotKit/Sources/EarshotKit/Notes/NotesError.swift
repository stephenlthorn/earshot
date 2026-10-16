import Foundation

/// What went wrong writing notes, a brief, an answer or a fix. The answer errors (`refused`, `truncated`,
/// `badOutput`) come from every provider, so they say "the model", not Claude.
public enum NotesError: Error, Equatable, LocalizedError {
    case missingKey, badKey, refused, truncated, claudeNotFound
    case http(status: Int, message: String)
    case badOutput(String)
    case claudeFailed(status: Int32, message: String)
    /// Claude Code isn't signed in, or its login expired. The value is what Claude Code said, for the log.
    case notSignedIn(String)
    /// The Claude plan's usage limit is reached. The value is what Claude said, for the log.
    case usageLimit(String)
    /// Claude Code rejected a flag Earshot needs. The value is what Claude Code said, for the log.
    case claudeTooOld(String)
    /// The plan or key can't use this model. The value is the model.
    case modelUnavailable(String)
    /// A local model problem. The value is the whole sentence the user sees.
    case local(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: "No Claude API key is set. Add one in Settings, Claude."
        case .badKey: "Anthropic rejected the API key. Check it in Settings, Claude."
        case .refused: "The model declined to answer."
        case .truncated: "The model's answer was cut off before it was finished."
        case .claudeNotFound: "Claude Code wasn't found. Install it, or set its path in Settings, Claude."
        case let .http(status, message): "The Claude API returned \(status): \(message)"
        case let .badOutput(detail): "The model's answer came back in the wrong shape: \(detail)"
        case let .claudeFailed(status, message): "Claude Code failed (\(status)): \(message)"
        case .notSignedIn: "Claude Code is not signed in: run `claude` in Terminal and log in."
        case .usageLimit: "Your Claude usage limit is reached. Press Retry later."
        case .claudeTooOld: "Claude Code is too old; update it."
        case let .modelUnavailable(model): "Your plan can't use \(model); pick another in Settings."
        case let .local(sentence): sentence
        }
    }
}
