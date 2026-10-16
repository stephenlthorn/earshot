import Foundation

/// `earshot doctor` and `earshot mcp`.
extension EarshotCLI {
    /// One `doctor` check.
    struct Check: Codable, Equatable {
        enum Status: String, Codable { case ok, warn, fail }
        var name: String
        var status: Status
        var detail: String
    }

    static let translocated = "/AppTranslocation/"
    static let moveToApplications = "Move Earshot to Applications first."

    static func doctor(_ arguments: Arguments, io: IO) async throws -> Int32 {
        let context = Context(arguments, io: io)
        var checks = [await claudeCheck(context)]
        io.err("earshot: Checking the speech model for \(context.settings.localeIdentifier); this may download it.\n")
        checks.append(await speechCheck(context))
        checks += [folderCheck(context), indexCheck(context), mcpCheck(context), pluginCheck(context), appCheck(io)]
        let failed = checks.filter { $0.status == .fail }.count
        if arguments.has("json") {
            io.out(try json(checks))
        } else {
            let lines = checks.map { "\($0.status.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0))\($0.name): \($0.detail)" }
            let verdict = failed == 0 ? "No problems found." : "\(failed) check\(failed == 1 ? "" : "s") failed."
            io.out((lines + ["", verdict]).joined(separator: "\n") + "\n")
        }
        return failed == 0 ? 0 : 1
    }

    static func claudeCheck(_ context: Context) async -> Check {
        let settings = context.settings, io = context.io
        switch settings.provider {
        case .claudeAPI:
            let found = EnvironmentSecrets(environment: io.environment).read(.anthropicKey) != nil
            return Check(name: "Claude", status: found ? .ok : .fail,
                         detail: found ? "Using the API key in ANTHROPIC_API_KEY."
                         : "Earshot is set to use an API key, and earshot reads it only from ANTHROPIC_API_KEY.")
        case .claudeCode:
            let path = await io.locateClaude(settings.claudePath)
            let status = await ClaudeCodeStatus.check(path: path, runner: io.runner)
            let where_ = status.path.map { " (\($0))" } ?? ""
            return Check(name: "Claude", status: status.state == .ready ? .ok : .fail, detail: status.summary + where_)
        case .local:
            // One free `GET <base>/models`; no model is called.
            let status = await LocalModelStatus.check(address: settings.localURL, model: settings.localModel,
                                                      session: io.urlSession)
            return Check(name: "Local model", status: status.state == .ready ? .ok : .fail, detail: status.summary)
        }
    }

    static func speechCheck(_ context: Context) async -> Check {
        let locale = Locale(identifier: context.settings.localeIdentifier)
        do {
            try await context.io.prepareSpeech(locale)
            return Check(name: "Speech model", status: .ok, detail: "Ready for \(locale.identifier).")
        } catch {
            return Check(name: "Speech model", status: .fail, detail: describe(error))
        }
    }

    /// A real read of the folder and of its newest meeting, so a Documents permission problem shows up here.
    static func folderCheck(_ context: Context) -> Check {
        let path = context.folder.path
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path).filter { !$0.hasPrefix(".") }.sorted()
        } catch where LibraryError.isPermission(error) {
            return Check(name: "Meetings folder", status: .fail, detail: LibraryError.folderNotReadable(path).message(app: context.app))
        } catch where !FileManager.default.fileExists(atPath: path) {
            return Check(name: "Meetings folder", status: .warn, detail: "\(path) doesn't exist yet. Earshot makes it for the first meeting.")
        } catch {
            // There, but not a folder that can be listed: a file, a volume that went away, a disk error.
            return Check(name: "Meetings folder", status: .fail, detail: "\(path) can't be used: \(describe(error))")
        }
        if let newest = names.last {
            do {
                _ = try Data(contentsOf: context.folder.appending(path: newest).appending(path: MeetingFile.session))
            } catch where LibraryError.isPermission(error) {
                return Check(name: "Meetings folder", status: .fail, detail: LibraryError.folderNotReadable(path).message(app: context.app))
            } catch {
                // Not a meeting folder, or one being written: the listing already proved the folder is readable.
            }
        }
        return Check(name: "Meetings folder", status: .ok, detail: "\(path) is readable (\(names.count) item\(names.count == 1 ? "" : "s")).")
    }

    static func indexCheck(_ context: Context) -> Check {
        let path = context.indexURL.path
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch where LibraryError.isPermission(error) {
            return Check(name: "Index", status: .fail, detail: "\(path) can't be read: \(describe(error))")
        } catch {
            return Check(name: "Index", status: .warn, detail: "No index at \(path) yet. Open Earshot once so it can build it.")
        }
        let count = context.index.entries().count
        return Check(name: "Index", status: .ok, detail: "\(count) meeting\(count == 1 ? "" : "s") in \(path).")
    }

    /// Runs the server in this process, once per protocol era: discover then the tool list (modern), and
    /// initialize then the tool list (legacy).
    static func mcpCheck(_ context: Context) -> Check {
        var modern = mcpServer(context), legacy = mcpServer(context)
        let meta = "{\"\(MCPServer.versionKey)\":\"\(MCPServer.modernVersion)\",\"\(MCPServer.capabilitiesKey)\":{}}"
        let discovered = result(modern.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{\"_meta\":\(meta)}}"))
        let modernTools = toolCount(modern.handle("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{\"_meta\":\(meta)}}"))
        let legacyVersion = MCPServer.legacyVersions.first ?? ""
        let initialized = result(legacy.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"\(legacyVersion)\",\"capabilities\":{},\"clientInfo\":{\"name\":\"earshot-doctor\",\"version\":\"\(version)\"}}}"))
        let legacyTools = toolCount(legacy.handle("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"))
        guard discovered?["supportedVersions"] != nil, modernTools == MCPServer.tools.count,
              initialized?["protocolVersion"] as? String == legacyVersion, legacyTools == MCPServer.tools.count else {
            return Check(name: "MCP server", status: .fail, detail: "The server didn't answer as expected.")
        }
        return Check(name: "MCP server", status: .ok, detail: "Answers both protocol eras with \(modernTools) tools.")
    }

    private static func result(_ reply: String?) -> [String: Any]? {
        reply.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["result"] as? [String: Any]
    }

    private static func toolCount(_ reply: String?) -> Int { (result(reply)?["tools"] as? [Any])?.count ?? 0 }

    /// Claude Code's config folder: the user's own CLAUDE_CONFIG_DIR when it is set and not blank, else ~/.claude.
    static func claudeConfigFolder(_ io: IO) -> URL {
        let own = io.environment[ClaudeEnvironment.configDirectory]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return own.isEmpty ? io.home.appending(path: ".claude", directoryHint: .isDirectory)
                           : URL(filePath: own, directoryHint: .isDirectory)
    }

    /// Whether Claude Code has the plugin, and whether its launcher can find the app.
    static func pluginCheck(_ context: Context) -> Check {
        let home = context.io.home
        let file = claudeConfigFolder(context.io).appending(path: "plugins/installed_plugins.json")
        let plugins = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["plugins"] as? [String: Any]
        let installed = (plugins?.keys ?? [:].keys).filter { $0.hasPrefix("earshot@") || $0.hasPrefix("earshot-reminders@") }.sorted()
        guard !installed.isEmpty else {
            return Check(name: "Claude Code plugin", status: .warn,
                         detail: "Not installed. In Claude Code: /plugin marketplace add stephenlthorn/earshot, then /plugin install earshot@earshot.")
        }
        let apps = ["/Applications/Earshot.app", home.appending(path: "Applications/Earshot.app").path]
        guard apps.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/Contents/Helpers/earshot") }) else {
            return Check(name: "Claude Code plugin", status: .warn,
                         detail: "\(installed.joined(separator: ", ")) installed, but its launcher can't find Earshot.app in /Applications or ~/Applications.")
        }
        return Check(name: "Claude Code plugin", status: .ok, detail: "\(installed.joined(separator: ", ")) installed.")
    }

    static func appCheck(_ io: IO) -> Check {
        io.executablePath.contains(translocated)
            ? Check(name: "App location", status: .fail, detail: moveToApplications)
            : Check(name: "App location", status: .ok, detail: io.executablePath)
    }

    static func mcpServer(_ context: Context) -> MCPServer {
        let io = context.io
        return MCPServer(library: context.library, userName: context.settings.userName, version: version, app: context.app,
                         timeZone: io.timeZone, now: io.now, log: { io.err($0 + "\n") })
    }

    /// `earshot mcp`: serves stdin until it closes.
    static func serve(_ arguments: Arguments, io: IO) throws -> Int32 {
        io.prepareToServe()
        var server = mcpServer(Context(arguments, io: io))
        server.serve(readLine: io.readLine, write: { io.out($0 + "\n") })
        return 0
    }
}
