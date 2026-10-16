import Foundation

/// What Settings, onboarding and the live panel say and do for the local model provider (`NotesProvider.local`).
public enum LocalModelSetup {
    /// The local models guide on GitHub.
    public static let guideURL = URL(string: "https://github.com/stephenlthorn/earshot/blob/main/docs/local-models.md")!
    public static let serversCaption = "Works with Ollama, LM Studio, llama.cpp and other OpenAI-compatible servers. "
        + "When the server runs on this Mac, your meetings never leave it."
    public static let doCaption = "The Claude Code Do target still needs Claude Code."
    /// Settings > Live, in place of the live model field.
    public static let liveCaption = "Live to-dos use the local model chosen in Settings, Claude."
    public static let liveIntervalHint = "Local models can be slow; 120 seconds or more between passes works better."
    /// The live panel's pause reason when the local model can't be used (no address or no model).
    public static let notSetUp = "the local model isn't set up, check Settings, Claude"
    /// How long Settings waits after the address or model last changed before it checks the server.
    public static let typingDelay: Duration = .milliseconds(600)

    /// Settings' "Models" section with the local provider: one model does everything.
    public static func modelsLine(_ model: String) -> String {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Notes, live to-dos, the brief, Ask and Fix all use \(name.isEmpty ? "the local model you pick above" : name)."
    }

    /// The model picker's choices: what the server listed, plus the name typed in Settings when the server doesn't
    /// list it, so the picker's selection is always one of its choices.
    public static func modelOptions(listed: [String], current: String) -> [String] {
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !listed.contains(current) else {
            return listed
        }
        return listed + [current]
    }

    /// How long to wait before checking the server: nothing when Settings opens (no status yet, or the status is for
    /// the address and model shown), `typingDelay` while the address or the model is being typed.
    public static func checkDelay(last: LocalModelStatus?, address: String, model: String) -> Duration {
        guard let last else { return .zero }
        let trim = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return last.address == trim(address) && last.model == trim(model) ? .zero : typingDelay
    }

    /// Whether onboarding and What's New check the server when they appear: unless the last status is ready for the
    /// address and model in Settings, so a "Can't reach" from earlier is never left standing.
    public static func checksOnAppear(last: LocalModelStatus?, address: String, model: String) -> Bool {
        guard let last, last.state == .ready else { return true }
        return checkDelay(last: last, address: address, model: model) != .zero
    }
}

/// The notes setup problems that Record, Import and Write notes put in the menu's banner.
public enum NotesSetup {
    /// Every line `EarshotSettings.notesSetupProblem` can return, for every provider.
    public static let problems: Set<String> = Set([
        NotesError.missingKey.errorDescription, NotesError.claudeNotFound.errorDescription,
        LocalModelClient.blankAddress, LocalModelClient.wrongScheme, LocalModelClient.credentials,
        LocalModelClient.plainHTTP, LocalModelClient.pickModel,
    ].compactMap(\.self))

    /// True when one line of the banner is a notes setup problem, so the menu offers "Set up notes" next to it.
    public static func needsSetup(banner: String?) -> Bool {
        guard let banner else { return false }
        return banner.split(separator: "\n").contains { problems.contains(String($0)) }
    }
}
