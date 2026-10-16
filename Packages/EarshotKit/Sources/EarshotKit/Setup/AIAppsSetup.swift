import Foundation

/// Settings, AI apps (spec 11.4): connecting Claude Code, Claude Desktop and the shell to the bundled `earshot` helper.
public struct AIAppsSetup: Sendable {
    public static let serverName = "earshot"
    public static let moveFirst = "Move Earshot to Applications first"
    public static let helperMissing = "This copy of Earshot has no earshot helper inside it. Install a release build."
    public static let alreadyAdded = "Earshot is already added to Claude Code."
    public static let translocationMarker = "/AppTranslocation/"
    /// The Claude Code lines that install the plugins from this repo's marketplace (spec 11.5). The reminders plugin
    /// is opt-in.
    public static let pluginLines = ["/plugin marketplace add stephenlthorn/earshot", "/plugin install earshot@earshot",
                                     "/plugin install earshot-reminders@earshot"]

    /// The app bundle, `Bundle.main.bundleURL` in the app.
    public let appURL: URL

    public init(appURL: URL) {
        self.appURL = appURL
    }

    /// `Earshot.app/Contents/Helpers/earshot` (spec 11.2).
    public var helperPath: String { appURL.appending(path: "Contents/Helpers/earshot").path(percentEncoded: false) }

    /// macOS runs a downloaded app from a random read-only path until it is moved, so a path saved now would break.
    public var isTranslocated: Bool { appURL.path(percentEncoded: false).contains(Self.translocationMarker) }

    /// Why the AI apps buttons are off, or nil.
    public func problem(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        if isTranslocated { return Self.moveFirst }
        return isExecutable(helperPath) ? nil : Self.helperMissing
    }

    /// `claude mcp add --scope user earshot -- <helper> mcp`.
    public var mcpAddArguments: [String] { ["mcp", "add", "--scope", "user", Self.serverName, "--", helperPath, "mcp"] }

    /// The `mcpServers` entry for `claude_desktop_config.json`.
    public var claudeDesktopJSON: String {
        let object: [String: Any] = ["mcpServers": [Self.serverName: ["command": helperPath, "args": ["mcp"]]]]
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The Terminal line that puts `earshot` on the PATH.
    public var installCommandLine: String {
        "mkdir -p ~/.local/bin && ln -sf \(Self.shellQuoted(helperPath)) ~/.local/bin/earshot"
    }

    /// Runs `claude mcp add` with the child environment (spec 3.1) and returns one line to show.
    public func addToClaudeCode(claudePath: String, runner: any ProcessRunning = ProcessRunner()) async -> String {
        let output: ProcessOutput
        do {
            output = try await runner.run(claudePath, mcpAddArguments, stdin: nil, directory: nil,
                                          environment: ClaudeEnvironment.child(claudePath: claudePath),
                                          inheritEnvironment: false, timeout: .seconds(30))
        } catch {
            return "Couldn't run Claude Code: \(error.localizedDescription)"
        }
        let said = [output.stdout, output.stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        if said.lowercased().contains("already exists") { return Self.alreadyAdded }
        if output.timedOut { return "Claude Code did not answer in time." }
        guard output.status == 0 else {
            return said.isEmpty ? "Claude Code stopped with exit \(output.status)." : "Claude Code said: \(said.prefix(300))"
        }
        return said.isEmpty ? "Added Earshot to Claude Code." : String(said.prefix(300))
    }

    /// `text` in single quotes, safe to paste into zsh or bash.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
