import Foundation

/// Finds the user's own `claude`.
public enum ClaudeLocator {
    /// The first executable among the override and the usual install places (spec 3.1). It never searches $PATH:
    /// an app opened from Finder has only the system folders there. `findViaShell` covers the rest.
    public static func find(override: String? = nil,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        let known = [home.appending(path: ".local/bin/claude").path, home.appending(path: ".claude/local/claude").path,
                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                     home.appending(path: ".npm-global/bin/claude").path, home.appending(path: ".bun/bin/claude").path,
                     home.appending(path: ".volta/bin/claude").path]
        return ([override].compactMap { $0 }.filter { !$0.isEmpty } + known).first(where: isExecutable)
    }

    /// What the user's login shell finds: `/bin/zsh -lc 'whence -p claude'`, which ignores aliases. A profile
    /// may print its own lines, so only the last line that is an absolute path counts. The caller caches it.
    public static func findViaShell(runner: any ProcessRunning = ProcessRunner()) async -> String? {
        guard let out = try? await runner.run("/bin/zsh", ["-lc", "whence -p claude"], stdin: nil, directory: nil,
                                              environment: [:], timeout: .seconds(5)),
              out.status == 0, !out.timedOut else { return nil }
        return out.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }
}

/// The environment every `claude` child gets: an allowlist, never Earshot's own environment, so no API key, token,
/// provider switch or nested-session marker reaches it by accident (spec 3.1).
public enum ClaudeEnvironment {
    /// The keys copied from Earshot's environment when they are set. PATH is built, not copied.
    /// CLAUDE_CONFIG_DIR is a location, not a credential: a user who keeps Claude Code's config in another folder
    /// would look signed out without it. Earshot passes on the user's own value and never sets one itself.
    public static let allowlist = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
                                   "__CF_USER_TEXT_ENCODING", configDirectory]

    public static let configDirectory = "CLAUDE_CONFIG_DIR"

    /// The whole environment for a run of the `claude` at `claudePath`. `apiKey` is added as ANTHROPIC_API_KEY,
    /// for structured calls under the API-key provider only.
    public static func child(claudePath: String, apiKey: String? = nil) -> [String: String] {
        child(claudePath: claudePath, apiKey: apiKey, from: ProcessInfo.processInfo.environment)
    }

    static func child(claudePath: String, apiKey: String?, from inherited: [String: String],
                      resolve: (String) -> String? = realPath) -> [String: String] {
        var out = inherited.filter { allowlist.contains($0.key) }
        // A blank value names no folder, so it is left out.
        if out[configDirectory]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            out[configDirectory] = nil
        }
        if out["HOME"] == nil { out["HOME"] = NSHomeDirectory() }
        out["PATH"] = path(claude: claudePath, inherited: inherited["PATH"], resolve: resolve)
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            out["ANTHROPIC_API_KEY"] = key
        }
        return out
    }

    /// An npm install of `claude` starts with `#!/usr/bin/env node`, and an app opened from Finder or by launchd
    /// inherits only the system folders on its PATH, where there is no node. So the PATH starts with the folder
    /// `claude` is in, then the folder its symlink resolves to, then Homebrew's two folders, then the inherited PATH.
    /// nvm, volta and bun installs keep node (or their own shim) next to `claude`, so the first folder covers them.
    public static func path(claude: String, inherited: String?,
                            resolve: (String) -> String? = realPath) -> String {
        let folder = { (path: String) in (path as NSString).deletingLastPathComponent }
        let first = [folder(claude), resolve(claude).map(folder), "/opt/homebrew/bin", "/usr/local/bin"].compactMap { $0 }
        let rest = (inherited ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (first + rest).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// The path with every symlink resolved, or nil if there is nothing there.
    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
