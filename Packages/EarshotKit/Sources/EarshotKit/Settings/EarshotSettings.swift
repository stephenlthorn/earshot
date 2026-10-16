import Foundation

public enum NotesProvider: String, Codable, CaseIterable, Sendable {
    case claudeAPI = "claude_api"
    case claudeCode = "claude_code"
    /// A local OpenAI-compatible server (`LocalModelClient`).
    case local = "local"

    public var label: String {
        switch self {
        case .claudeAPI: "Claude API key"
        case .claudeCode: "Claude Code (your Claude plan)"
        case .local: "Local model (Ollama, LM Studio, llama.cpp)"
        }
    }
}

/// Everything in Settings except secrets, which are in KeychainStore.
public struct EarshotSettings: Codable, Equatable, Sendable {
    public static let defaultsKey = "settings"

    // General
    public var saveFolder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Earshot").path
    public var defaultMode = Mode.notes
    public var userName = ""
    public var consentReminder = true
    public var echoCancellation = false
    public var launchAtLogin = false
    // Transcription
    public var localeIdentifier = Locale.current.identifier
    // Notes
    public var provider = NotesProvider.claudeCode
    public var model = "claude-opus-5-5"
    public var effort = "medium"
    public var claudePath = ""
    public var claudeCodeModel = ""
    /// The local model server's OpenAI-compatible address, for the local provider.
    public var localURL = LocalModelClient.defaultURL
    /// The local model for every role, for the local provider.
    public var localModel = ""
    public var style = NotesStyle.general
    public var extraInstructions = ""
    // Do
    public var sendWithoutAsking = false
    public var claudeCodeTargetOn = false
    public var claudeCodeFolder = ""
    /// "restricted" (the default), "acceptEdits", "auto" or "bypassPermissions".
    public var permissionMode = "restricted"
    public var webhookOn = false
    public var webhookURL = ""
    public var commandOn = false
    public var command = ""
    // Storage
    public var keepAudio = true
    // Live assistant
    public var liveAssistant = false
    /// Seconds between live passes.
    public var liveInterval = 90
    public var liveModel = "claude-sonnet-5-5"
    /// The model for the brief and ask.
    public var quickModel = "claude-sonnet-5-5"
    /// The Do target id that Start uses, or "" for none.
    public var liveTarget = ""
    public var allowRoutineLiveStart = false
    public var showLivePanel = true
    public var hidePanelFromCapture = true
    public var voiceFlags = true
    public var flagHotkey = true
    // Calendar
    public var useCalendar = false
    /// Company domains typed by the user, separated by commas or spaces.
    public var myDomains = ""
    /// Used only when a Do target is on; otherwise external meetings get Notes.
    public var externalMode = Mode.notesAndDo
    public var internalMode = Mode.notes
    /// Words in an event title that make an external meeting a sales call, separated by commas.
    public var salesKeywords = EarshotSettings.defaultSalesKeywords
    public static let defaultSalesKeywords = "demo, discovery, intro, proposal, pricing, sales, pitch, quote, consult"
    public var briefEnabled = true
    // Noticing calls
    public var noticeCalls = false
    public var autoRecordCalls = false
    public var autoStopCalls = true
    // Screen
    public var readScreen = false
    public var screenWholeDisplay = false
    public var keepScreenshots = false
    // Learning
    public var learnFromEdits = true
    // Routine target
    public var routineOn = false
    public var routineURL = ""
    // Consent
    public var consentLine = Self.defaultConsentLine
    // Upgrades
    public var onboardedVersion = 0

    public static let defaultConsentLine = "Quick heads-up: I'm recording this call so an AI assistant can transcribe it and take notes. I'll share the notes afterwards."

    public init() {}

    /// The only load, so every caller, the App's plain `EarshotSettings.load()` included, gets the upgrade from v1
    /// (spec 3.1). A v1 user who never changed a setting has no saved blob; if the Keychain holds an API key, they
    /// keep the API provider. A first load is saved either way, so adding a key later never switches the provider on
    /// its own. Once settings are saved, the Keychain is not read. Tests pass fake secrets.
    public static func load(from defaults: UserDefaults = .standard,
                            secrets: any SecretReading = KeychainStore()) -> EarshotSettings {
        guard let data = defaults.data(forKey: defaultsKey) else {
            var settings = EarshotSettings()
            if !(secrets.read(.anthropicKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                settings.provider = .claudeAPI
            }
            settings.save(to: defaults)
            return settings
        }
        return merged(data)
    }

    /// Saved keys win; any key a newer version added keeps its default, so an update never resets Settings.
    /// A saved value that no longer decodes (an enum case from another version, a wrong type) is dropped on its
    /// own and that setting goes back to its default; the rest of what was saved is kept.
    private static func merged(_ data: Data) -> EarshotSettings {
        guard let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(EarshotSettings())) as? [String: Any] else {
            return EarshotSettings()
        }
        let accepted = saved.reduce(base) { accepted, entry in
            guard base[entry.key] != nil else { return accepted }
            let trial = accepted.merging([entry.key: entry.value]) { $1 }
            return decode(trial) == nil ? accepted : trial
        }
        return decode(accepted) ?? EarshotSettings()
    }

    private static func decode(_ object: [String: Any]) -> EarshotSettings? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(EarshotSettings.self, from: data)
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// With the lessons and the index in Application Support (spec 6 and 11.1).
    public var pipelineConfig: PipelineConfig { pipelineConfig(at: .standard) }

    /// With the lessons and the index at `locations`: Application Support, or an e2e run's own folder.
    public func pipelineConfig(at locations: DataLocations) -> PipelineConfig {
        PipelineConfig(userName: userName, style: style, extraInstructions: extraInstructions,
                       locale: Locale(identifier: localeIdentifier), keepAudio: keepAudio,
                       lessons: LessonsStore(url: locations.lessons), learnFromEdits: learnFromEdits,
                       index: LibraryIndex(url: locations.index), myDomains: myDomains, salesKeywords: salesKeywords)
    }

    /// The one client every Claude call goes through, for the chosen provider.
    public func claudeClient(secrets: any SecretReading,
                             locate: (String?) -> String? = { ClaudeLocator.find(override: $0) }) throws -> any ClaudeClient {
        switch provider {
        case .claudeAPI:
            return ClaudeAPIClient(apiKey: { secrets.read(.anthropicKey) })
        case .claudeCode:
            guard let path = locate(claudePath) else { throw NotesError.claudeNotFound }
            return ClaudeCodeClient(claudePath: path)
        case .local:
            return try localModelClient()
        }
    }

    /// Why the local model can't be used yet (the address, then the model), or nil.
    public var localSetupProblem: String? {
        LocalModelClient.addressProblem(localURL)
            ?? (localModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? LocalModelClient.pickModel : nil)
    }

    /// The local model client, or `NotesError.local` with what to fix in Settings.
    public func localModelClient(session: URLSession = .shared) throws -> LocalModelClient {
        if let problem = localSetupProblem { throw NotesError.local(problem) }
        guard let url = URL(string: localURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NotesError.local(LocalModelClient.wrongScheme)
        }
        return LocalModelClient(baseURL: url, session: session, gate: LocalModelClient.serverGate)
    }

    /// Notes and fix use the notes model (with Claude Code, its own model when one is set, as in v1); live uses the
    /// live model; the brief and ask use the quick model (spec 3.3). A local model does every role.
    public func model(for role: ClaudeRole) -> String {
        if provider == .local { return localModel.trimmingCharacters(in: .whitespacesAndNewlines) }
        return switch role {
        case .notes, .fix: provider == .claudeCode && !claudeCodeModel.isEmpty ? claudeCodeModel : model
        case .live: liveModel
        case .brief, .ask: quickModel
        }
    }

    public func effort(for role: ClaudeRole) -> String {
        switch role {
        case .notes, .fix: effort
        case .live, .brief: "low"
        case .ask: "medium"
        }
    }

    /// True when any Do target is switched on, whether or not it can run yet.
    public var anyTargetOn: Bool { claudeCodeTargetOn || webhookOn || commandOn || routineOn }

    public func notesWriter(secrets: any SecretReading,
                            locate: (String?) -> String? = { ClaudeLocator.find(override: $0) }) throws -> any NotesWriter {
        ClaudeNotesWriter(client: try claudeClient(secrets: secrets, locate: locate),
                          model: model(for: .notes), effort: effort(for: .notes))
    }

    /// Why notes can't be written right now, or nil. Checked before a Notes recording starts.
    public func notesSetupProblem(secrets: any SecretReading,
                                  locate: (String?) -> String? = { ClaudeLocator.find(override: $0) }) -> String? {
        switch provider {
        case .claudeAPI:
            (secrets.read(.anthropicKey) ?? "").isEmpty ? NotesError.missingKey.errorDescription : nil
        case .claudeCode:
            locate(claudePath) == nil ? NotesError.claudeNotFound.errorDescription : nil
        case .local:
            localSetupProblem
        }
    }

    public static let noWorkFolder = "Choose a work folder for Claude Code in Settings, Do."

    /// The Do targets that are switched on. A Claude Code, webhook or routine target that is on but can't run is still
    /// returned, as one that fails with the reason, so the meeting shows the failure and Retry works once Settings
    /// are fixed. A routine whose token is rejected deletes it through `deleteSecret`; by default that is `secrets`
    /// itself when it is a KeychainStore, and nothing otherwise.
    public func targets(secrets: any SecretReading,
                        locate: (String?) -> String? = { ClaudeLocator.find(override: $0) },
                        isFolder: (String) -> Bool = Self.isFolder,
                        deleteSecret: (@Sendable (KeychainStore.Item) throws -> Void)? = nil) -> [any DoTarget] {
        var out: [any DoTarget] = []
        if claudeCodeTargetOn { out.append(claudeCodeTarget(locate: locate, isFolder: isFolder)) }
        if webhookOn { out.append(webhookTarget(secrets: secrets)) }
        if commandOn, !command.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(CommandTarget(command: command))
        }
        if routineOn { out.append(routineTarget(secrets: secrets, deleteSecret: deleteSecret)) }
        return out
    }

    /// The webhook target, or one that fails with what to fix in Settings when `WebhookURLPolicy` refuses the URL.
    func webhookTarget(secrets: any SecretReading) -> any DoTarget {
        let text = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), WebhookURLPolicy.allows(url) else {
            return UnavailableTarget(id: "webhook", label: "Webhook",
                                     reason: WebhookURLPolicy.problem(text) ?? WebhookURLPolicy.wrongURL)
        }
        return WebhookTarget(url: url, token: { secrets.read(.webhookToken) })
    }

    /// The routine target, or one that fails with what to fix in Settings.
    func routineTarget(secrets: any SecretReading,
                       deleteSecret: (@Sendable (KeychainStore.Item) throws -> Void)?) -> any DoTarget {
        let (id, label) = ("routine", "Claude Code routine")
        // The token is read here only to say what is missing; the target reads it again when it sends.
        if let problem = RoutineTarget.setupProblem(url: routineURL, token: secrets.read(.routineToken)) {
            return UnavailableTarget(id: id, label: label, reason: problem)
        }
        guard let url = URL(string: routineURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return UnavailableTarget(id: id, label: label, reason: RoutineTarget.wrongURL)
        }
        let delete = Self.routineDeleter(secrets: secrets, override: deleteSecret)
        var routine = RoutineTarget(url: url, token: { secrets.read(.routineToken) },
                                    onUnauthorized: { try delete(.routineToken) })
        routine.userName = userName.isEmpty ? "the user" : userName
        return routine
    }

    /// How a rejected routine token is removed: through `override` when given, else through `secrets` when it is a
    /// KeychainStore, and not at all for other secrets (fakes, or the CLI's environment).
    static func routineDeleter(secrets: any SecretReading,
                               override: (@Sendable (KeychainStore.Item) throws -> Void)?)
        -> @Sendable (KeychainStore.Item) throws -> Void {
        if let override { return override }
        guard let store = secrets as? KeychainStore else { return { _ in } }
        return { try store.delete($0) }
    }

    func claudeCodeTarget(locate: (String?) -> String?, isFolder: (String) -> Bool) -> any DoTarget {
        let (id, label) = ("claude-code", "Claude Code")
        guard let path = locate(claudePath) else {
            return UnavailableTarget(id: id, label: label, reason: NotesError.claudeNotFound.errorDescription ?? "")
        }
        let folder = (claudeCodeFolder.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !folder.isEmpty, isFolder(folder) else { return UnavailableTarget(id: id, label: label, reason: Self.noWorkFolder) }
        return ClaudeCodeTarget(claudePath: path, workingFolder: URL(fileURLWithPath: folder, isDirectory: true),
                                permissionMode: permissionMode, userName: userName.isEmpty ? "the user" : userName)
    }

    /// The targets that will actually run, for the confirm window and the start-of-recording check.
    public func doTargetLabels(secrets: any SecretReading = KeychainStore(),
                               locate: (String?) -> String? = { ClaudeLocator.find(override: $0) },
                               isFolder: (String) -> Bool = Self.isFolder) -> [String] {
        targets(secrets: secrets, locate: locate, isFolder: isFolder).filter { !($0 is UnavailableTarget) }.map(\.label)
    }

    /// Why a target that is switched on can't run, for Settings, Do and the panel.
    public func doTargetProblems(secrets: any SecretReading = KeychainStore(),
                                 locate: (String?) -> String? = { ClaudeLocator.find(override: $0) },
                                 isFolder: (String) -> Bool = Self.isFolder) -> [String] {
        unavailableTargets(secrets: secrets, locate: locate, isFolder: isFolder).map(\.reason)
    }

    /// The targets that are switched on but can't run, with their ids, so each Settings section shows only its own
    /// target's reason.
    public func unavailableTargets(secrets: any SecretReading = KeychainStore(),
                                   locate: (String?) -> String? = { ClaudeLocator.find(override: $0) },
                                   isFolder: (String) -> Bool = Self.isFolder) -> [UnavailableTarget] {
        targets(secrets: secrets, locate: locate, isFolder: isFolder).compactMap { $0 as? UnavailableTarget }
    }

    public static func isFolder(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

public enum DiskSpace {
    public enum Level: Equatable, Sendable { case ok, low, critical }
    public static let lowBytes: Int64 = 2_000_000_000
    public static let criticalBytes: Int64 = 500_000_000

    public static func level(freeBytes: Int64) -> Level {
        freeBytes < criticalBytes ? .critical : freeBytes < lowBytes ? .low : .ok
    }

    public static func free(at url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    /// Free space on the drive a save folder is on. A folder that isn't made yet will be made on its nearest
    /// existing parent's drive, so that is the one measured; `free(at:)` on a missing path reads nothing.
    public static func free(near folder: URL) -> Int64? { free(at: probe(for: folder)) }

    /// `folder` if it exists, else its nearest existing parent, else "/".
    public static func probe(for folder: URL,
                             exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        var url = folder.standardizedFileURL
        while url.path != "/", !exists(url.path) { url = url.deletingLastPathComponent() }
        return url
    }
}
