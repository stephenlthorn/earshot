import Foundation

/// Structured calls through the user's own Claude Code, signed in with their Claude plan (spec 3.2).
public struct ClaudeCodeClient: ClaudeClient {
    public var claudePath: String
    public var runner: any ProcessRunning
    public var gate: ClaudeGate
    /// The limit across Earshot's processes (the app, `earshot` and the plugin hook), taken after the gate; nil for
    /// none.
    public var slots: ClaudeSlots?
    /// Set only for the API-key provider; it becomes ANTHROPIC_API_KEY in the child's environment.
    public var apiKey: String?

    public init(claudePath: String, runner: any ProcessRunning = ProcessRunner(), gate: ClaudeGate = .shared,
                slots: ClaudeSlots? = .shared, apiKey: String? = nil) {
        self.claudePath = claudePath
        self.runner = runner
        self.gate = gate
        self.slots = slots
        self.apiKey = apiKey
    }

    /// Exactly the list verified on 2026-10-15 with a subscription login. Safe mode and `--restricted` keep the
    /// user's hooks, plugins, MCP servers, settings files and CLAUDE.md away from the transcript, and no tool can
    /// run. There is no fallback for a rejected flag: that means Claude Code is too old.
    static func arguments(for request: ClaudeRequest, systemPromptFile: String) -> [String] {
        var out = ["-p", "--output-format", "json", "--json-schema", request.schema,
                   "--system-prompt-file", systemPromptFile, "--tools", "", "--strict-mcp-config",
                   "--safe-mode", "--restricted", "--permission-mode", "dontAsk", "--permission-prompts", "none",
                   "--no-session-persistence"]
        if !request.model.isEmpty { out += ["--model", request.model] }
        if !request.effort.isEmpty { out += ["--effort", request.effort] }
        return out
    }

    /// A live pass is skipped when no slot is free, in this process or across processes; every other call waits.
    public func structured(_ request: ClaudeRequest) async throws -> Data {
        let skip = request.role == .live
        let result = try await gate.run(request.role, skipIfBusy: skip) { () async throws -> Data? in
            guard let slots = self.slots else { return try await self.call(request) }
            return try await slots.run(skipIfBusy: skip) { try await self.call(request) }
        }
        guard let data = result ?? nil else { throw ClaudeBusy() }
        return data
    }

    /// One run from an empty folder of its own, which is removed afterwards. The prompt goes on stdin.
    func call(_ request: ClaudeRequest) async throws -> Data {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "earshot-claude-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let promptFile = folder.appending(path: "system.txt")
        try Data(request.system.utf8).write(to: promptFile)
        let out = try await runner.run(claudePath, Self.arguments(for: request, systemPromptFile: promptFile.path),
                                       stdin: Data(request.user.utf8), directory: folder,
                                       environment: ClaudeEnvironment.child(claudePath: claudePath, apiKey: apiKey),
                                       inheritEnvironment: false, timeout: request.timeout)
        return try Self.parse(out, model: request.model)
    }

    static func parse(_ out: ProcessOutput, model: String) throws -> Data {
        if out.timedOut { throw NotesError.claudeFailed(status: -1, message: "timed out") }
        let envelope = (try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8))) as? [String: Any]
        guard out.status == 0 else {
            // A failure inside the run is printed as the result on stdout; one before it, on stderr.
            let said = (envelope?["result"] as? String) ?? (out.stderr.isEmpty ? out.stdout : out.stderr + "\n" + out.stdout)
            throw ClaudeFailure.error(said, status: out.status, model: model)
        }
        guard let envelope else { throw NotesError.badOutput("Claude Code printed no JSON") }
        if envelope["is_error"] as? Bool == true {
            throw ClaudeFailure.error(String(describing: envelope["result"] ?? "error"), status: 1, model: model)
        }
        if let object = envelope["structured_output"], !(object is NSNull),
           let data = try? JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed) {
            return data
        }
        if let text = envelope["result"] as? String,
           (try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any] {
            return Data(text.utf8)
        }
        throw NotesError.badOutput("Claude Code's answer did not match the expected format")
    }
}
