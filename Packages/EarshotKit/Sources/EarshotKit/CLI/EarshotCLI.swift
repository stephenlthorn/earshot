import Foundation

/// The `earshot` command-line tool (spec 11.2). `main.swift` only calls `main(_:io:)`; everything it touches
/// (output, environment, settings, folders, clock, transcriber, Claude) comes in through `IO`, so tests run it whole.
public enum EarshotCLI {
    public static let version = "0.3.0"
    /// Where the app keeps its settings (UserDefaults domain, key `settings`).
    public static let appDomain = "com.stephenthorn.earshot"

    public static let usage = """
        earshot: read and process your Earshot meetings.

        Usage:
          earshot list [--since 7d] [--limit N] [--json]
          earshot show <meeting> [--transcript] [--json]     (<meeting>: an id, a folder name or latest)
          earshot search <query> [--limit 10] [--json]
          earshot items [--owner me|<name>] [--since 14d] [--json]
          earshot reminders
          earshot process <audio file> [--title T] [--json]
          earshot process <audio file> --send --target <id> --yes [--title T] [--json]
          earshot doctor [--json]
          earshot mcp
          earshot version
          earshot help

        Every command takes --folder <path> for the meetings folder. Without it, earshot uses
        EARSHOT_MEETINGS_DIR, then the folder set in Earshot, then ~/Documents/Earshot.
        process writes notes with the AI set in Earshot: Claude Code, an API key (read only from
        ANTHROPIC_API_KEY) or a local model server (Ollama, LM Studio, llama.cpp).
        process sends only with --send --target <id> --yes, and only to a target set up in Earshot:
        webhook, routine (a Claude Code routine) or claude-code (restricted mode). Tokens come from
        EARSHOT_WEBHOOK_TOKEN and EARSHOT_ROUTINE_TOKEN, never from the Keychain.

        """

    /// Exit codes: 0 done, 1 failed, 2 a usage error or a refusal.
    public static func main(_ arguments: [String], io: IO) async -> Int32 {
        let words = Array(arguments.dropFirst())
        guard let command = words.first else {
            io.out(usage)
            return 0
        }
        let rest = words.dropFirst()
        do {
            switch command {
            case "help", "--help", "-h":
                io.out(usage)
                return 0
            case "version", "--version":
                io.out("earshot \(version)\n")
                return 0
            case "list": return try list(Arguments.parse(rest, options: ["since", "limit"], flags: ["json"]), io: io)
            case "show": return try show(Arguments.parse(rest, flags: ["transcript", "json"]), io: io)
            case "search": return try search(Arguments.parse(rest, options: ["limit"], flags: ["json"]), io: io)
            case "items": return try items(Arguments.parse(rest, options: ["owner", "since"], flags: ["json"]), io: io)
            case "reminders": return reminders(rest, io: io)
            case "process":
                return try await process(Arguments.parse(rest, options: ["title", "target"], flags: ["json", "send", "yes"]), io: io)
            case "doctor": return try await doctor(Arguments.parse(rest, flags: ["json"]), io: io)
            case "mcp": return try serve(Arguments.parse(rest, flags: ["stdio"]), io: io)
            default: throw UsageError("Unknown command \"\(command)\".")
            }
        } catch let error as UsageError {
            io.err("earshot: \(error.message)\n")
            if error.showUsage { io.err("Run earshot help for usage.\n") }
            return 2
        } catch {
            io.err("earshot: \(describe(error))\n")
            return 1
        }
    }

    /// A mistake in the command line, or a request earshot refuses. Exit code 2.
    struct UsageError: Error, Equatable {
        let message: String
        var showUsage = true
        init(_ message: String, showUsage: Bool = true) {
            self.message = message
            self.showUsage = showUsage
        }
    }

    /// Positional words, `--name value` (or `--name=value`) options and `--flag` switches. `--folder` is accepted
    /// by every command; `--` ends the options.
    struct Arguments: Equatable {
        var positionals: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []

        static func parse(_ words: ArraySlice<String>, options: Set<String> = [], flags: Set<String> = []) throws -> Arguments {
            let options = options.union(["folder"])
            var out = Arguments()
            var index = words.startIndex
            var optionsEnded = false
            while index < words.endIndex {
                let word = words[index]
                index += 1
                guard !optionsEnded, word.hasPrefix("--"), word.count > 2 else {
                    if word == "--" { optionsEnded = true } else { out.positionals.append(word) }
                    continue
                }
                var name = String(word.dropFirst(2)), value: String?
                if let equals = name.firstIndex(of: "=") {
                    value = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
                if flags.contains(name), value == nil {
                    out.flags.insert(name)
                } else if options.contains(name) {
                    if value == nil {
                        guard index < words.endIndex else { throw UsageError("--\(name) needs a value.") }
                        value = words[index]
                        index += 1
                    }
                    out.options[name] = value
                } else {
                    throw UsageError("Unknown option --\(name).")
                }
            }
            return out
        }

        func has(_ flag: String) -> Bool { flags.contains(flag) }
    }

    /// What a command works with: the app's settings (or the defaults), the meetings folder, the index and lessons.
    struct Context {
        let io: IO
        let settings: EarshotSettings
        let folder: URL
        let indexURL: URL
        /// lessons.json: EARSHOT_LESSONS_FILE, else the one under the home folder's Application Support.
        let lessonsURL: URL

        init(_ arguments: Arguments, io: IO) {
            self.io = io
            let saved = io.savedSettings(EarshotCLI.settingsDomain(io.environment, home: io.home))
            settings = saved ?? EarshotSettings()
            folder = EarshotCLI.meetingsFolder(flag: arguments.options["folder"], environment: io.environment,
                                               saved: saved, home: io.home)
            indexURL = io.environment["EARSHOT_INDEX_DIR"].flatMap { EarshotCLI.expand($0, home: io.home) }
                .map { URL(filePath: $0, directoryHint: .isDirectory) } ?? io.indexURL
            lessonsURL = io.environment["EARSHOT_LESSONS_FILE"].flatMap { EarshotCLI.expand($0, home: io.home) }
                .map { URL(filePath: $0, directoryHint: .notDirectory) } ?? LessonsStore.defaultURL(home: io.home)
        }

        var store: SessionStore { SessionStore(root: folder, timeZone: io.timeZone) }
        var index: LibraryIndex { LibraryIndex(url: indexURL) }
        var library: MeetingLibrary { MeetingLibrary(index: index, store: store) }
        var app: String { EarshotCLI.hostApp(io.environment) }
    }

    /// The meetings folder: `--folder`, then EARSHOT_MEETINGS_DIR, then the app's saved folder, then
    /// ~/Documents/Earshot (spec 11.2).
    static func meetingsFolder(flag: String?, environment: [String: String], saved: EarshotSettings?, home: URL) -> URL {
        let candidates = [flag, environment["EARSHOT_MEETINGS_DIR"], saved?.saveFolder]
        let path = candidates.lazy.compactMap { $0.flatMap { expand($0, home: home) } }.first
            ?? home.appending(path: "Documents/Earshot").path
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// The defaults domain Earshot's settings are read from: EARSHOT_SETTINGS_DOMAIN when set (a path names a domain
    /// kept in that file, so a test run can point at one that is empty), else the app's own.
    static func settingsDomain(_ environment: [String: String], home: URL) -> String {
        environment["EARSHOT_SETTINGS_DOMAIN"].flatMap { expand($0, home: home) } ?? appDomain
    }

    /// A trimmed path with "~" expanded against `home`, or nil when blank.
    static func expand(_ path: String, home: URL) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "~" { return home.path }
        if trimmed.hasPrefix("~/") { return home.appending(path: String(trimmed.dropFirst(2))).path }
        return trimmed
    }

    /// The app macOS asks for Documents access: the terminal or Claude app that ran earshot.
    static func hostApp(_ environment: [String: String]) -> String {
        let bundles = ["com.anthropic.claudefordesktop": "Claude", "com.apple.Terminal": "Terminal",
                       "com.googlecode.iterm2": "iTerm", "com.microsoft.VSCode": "Visual Studio Code",
                       "dev.warp.Warp-Stable": "Warp", "com.mitchellh.ghostty": "Ghostty"]
        let terminals = ["Apple_Terminal": "Terminal", "iTerm.app": "iTerm", "vscode": "Visual Studio Code",
                         "WarpTerminal": "Warp", "ghostty": "Ghostty"]
        return environment["__CFBundleIdentifier"].flatMap { bundles[$0] }
            ?? environment["TERM_PROGRAM"].flatMap { terminals[$0] } ?? "the app you're using"
    }

    /// One plain line for an error.
    static func describe(_ error: any Error) -> String {
        String(((error as? LocalizedError)?.errorDescription ?? error.localizedDescription).prefix(300))
    }

    static func json(_ value: some Encodable) throws -> String {
        String(decoding: try JSONFiles.encoder().encode(value), as: UTF8.self) + "\n"
    }
}
