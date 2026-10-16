import Foundation

public struct DispatchResult: Equatable, Sendable {
    public var ok: Bool
    public var detail: String
    /// The program was stopped part-way (the app is quitting), so it may have done some of the work.
    public var interrupted: Bool
    /// Where the user can follow the work, such as a routine's cloud session URL.
    public var link: String?
    public init(ok: Bool, detail: String, interrupted: Bool = false, link: String? = nil) {
        self.ok = ok
        self.detail = detail
        self.interrupted = interrupted
        self.link = link
    }

    static let stopped = DispatchResult(ok: false, detail: "stopped before it finished", interrupted: true)
}

public protocol DoTarget: Sendable {
    var id: String { get }
    var label: String { get }
    /// True when sending twice does no harm, so a send cut off by a quit or crash is sent again on its own. Claude
    /// Code and commands do real work, so one of those cut off waits for the user to press Retry.
    var repeatsSafely: Bool { get }
    func send(_ payload: DoPayload, json: Data, folder: URL) async -> DispatchResult
}

extension DoTarget {
    public var repeatsSafely: Bool { false }
}

enum DoLog {
    /// Appends to do-<target>.log in the meeting folder. Never pass secrets in `text`.
    static func append(_ text: String, folder: URL, target: String) {
        let url = folder.appending(path: "do-\(target).log")
        let line = Data("[\(ISO8601DateFormatter().string(from: Date()))] \(text)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }
}

public struct WebhookTarget: DoTarget {
    public let id = "webhook"
    public let label = "Webhook"
    /// Receivers must already cope with a retry reaching them twice (the README says so), keyed on `session.id`.
    public let repeatsSafely = true
    public var url: URL
    public var token: @Sendable () -> String?
    public var session: URLSession
    public var delays: [Duration]
    public var sleep: @Sendable (Duration) async throws -> Void
    public var timeout: TimeInterval

    /// What a 3xx reply says. A redirect would carry the token to another address, so it is never followed.
    public static let redirected = "The webhook redirected; Earshot doesn't follow redirects with your token"
    /// The same, for a webhook with no token.
    public static let redirectedNoToken = "The webhook redirected; Earshot doesn't follow redirects"

    public init(url: URL, token: @escaping @Sendable () -> String?, session: URLSession = .shared,
                delays: [Duration] = [.seconds(2), .seconds(4), .seconds(8)],
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                timeout: TimeInterval = 180) {
        self.url = url
        self.token = token
        self.session = session
        self.delays = delays
        self.sleep = sleep
        self.timeout = timeout
    }

    public func send(_ payload: DoPayload, json: Data, folder: URL) async -> DispatchResult {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let secret = token() ?? ""
        if !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        request.httpBody = json
        var last = "not sent"
        for attempt in 0...delays.count {
            if attempt > 0 { try? await sleep(delays[attempt - 1]) }
            do {
                let (data, response) = try await session.data(for: request, delegate: NoRedirects())
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(decoding: data.prefix(300), as: UTF8.self)
                DoLog.append("POST \(url.host() ?? "") -> \(status) \(body)", folder: folder, target: id)
                if (200..<300).contains(status) { return DispatchResult(ok: true, detail: "HTTP \(status)") }
                // Refused by NoRedirects, so this is the redirect itself. Sending again would be redirected again.
                if (300..<400).contains(status) {
                    return DispatchResult(ok: false, detail: secret.isEmpty ? Self.redirectedNoToken : Self.redirected)
                }
                last = "HTTP \(status) \(body)"
                // The receiver refused the request itself; sending it again won't change that.
                if (400..<500).contains(status), status != 408, status != 429 { break }
            } catch {
                last = error.localizedDescription
                DoLog.append("POST \(url.host() ?? "") failed: \(last)", folder: folder, target: id)
            }
        }
        return DispatchResult(ok: false, detail: last)
    }
}

/// Refuses every redirect, so a request with a token goes only to the address the user set. The 3xx reply itself
/// comes back as the response.
final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

public struct CommandTarget: DoTarget {
    public let id = "command"
    public let label = "Command"
    public var command: String
    public var runner: any ProcessRunning
    public var timeout: Duration

    public init(command: String, runner: any ProcessRunning = ProcessRunner(), timeout: Duration = .seconds(600)) {
        self.command = command
        self.runner = runner
        self.timeout = timeout
    }

    public func send(_ payload: DoPayload, json: Data, folder: URL) async -> DispatchResult {
        do {
            let out = try await runner.run("/bin/zsh", ["-lc", command], stdin: json, directory: folder,
                                           environment: ["EARSHOT_SESSION_DIR": folder.path], timeout: timeout)
            DoLog.append("$ \(command)\nexit \(out.status)\(out.timedOut ? " (timed out)" : "")\n\(out.stdout)\(out.stderr)",
                         folder: folder, target: id)
            if out.timedOut { return DispatchResult(ok: false, detail: "timed out") }
            let said = (out.stderr.isEmpty ? out.stdout : out.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return out.status == 0 ? DispatchResult(ok: true, detail: "exit 0")
                : DispatchResult(ok: false, detail: "exit \(out.status): \(String(said.suffix(200)))")
        } catch is CancellationError {
            DoLog.append("$ \(command)\nstopped before it finished (Earshot quit)", folder: folder, target: id)
            return .stopped
        } catch {
            return DispatchResult(ok: false, detail: error.localizedDescription)
        }
    }
}

public struct ClaudeCodeTarget: DoTarget {
    public let id = "claude-code"
    public let label = "Claude Code"
    public var claudePath: String
    public var workingFolder: URL
    /// "restricted" (the default), or one of Claude Code's own modes: "acceptEdits", "auto", "bypassPermissions".
    public var permissionMode: String
    public var userName: String
    public var runner: any ProcessRunning
    public var timeout: Duration

    public static let restricted = "restricted"

    public init(claudePath: String, workingFolder: URL, permissionMode: String = Self.restricted, userName: String,
                runner: any ProcessRunning = ProcessRunner(), timeout: Duration = .seconds(1800)) {
        self.claudePath = claudePath
        self.workingFolder = workingFolder
        self.permissionMode = permissionMode
        self.userName = userName
        self.runner = runner
        self.timeout = timeout
    }

    /// Restricted mode (spec 14.2): file tools only, confined to the work folder, no MCP tools, and anything that
    /// would ask is denied. The other modes keep v1's arguments, so the user's own setup (hooks, plugins, MCP,
    /// CLAUDE.md) applies to the run, as the README says.
    var arguments: [String] {
        guard permissionMode == Self.restricted else {
            return ["-p", "--permission-mode", permissionMode, "--output-format", "text"]
        }
        return ["-p", "--restricted", "--permission-mode", "acceptEdits", "--tools", "Read,Edit,Write,Glob,Grep",
                "--permission-prompts", "none", "--strict-mcp-config", "--disallowedTools", "mcp__*",
                "--no-session-persistence", "--output-format", "json"]
    }

    public func send(_ payload: DoPayload, json: Data, folder: URL) async -> DispatchResult {
        do {
            // Every mode gets the allowlist environment, never Earshot's own (spec 3.1).
            let out = try await runner.run(claudePath, arguments,
                                           stdin: Data(DoPrompt.text(payload, userName: userName).utf8),
                                           directory: workingFolder,
                                           environment: ClaudeEnvironment.child(claudePath: claudePath),
                                           inheritEnvironment: false, timeout: timeout)
            let result = permissionMode == Self.restricted ? Self.restrictedResult(out) : Self.textResult(out)
            DoLog.append("claude in \(workingFolder.path), exit \(out.status)\(out.timedOut ? " (timed out)" : "")\n\(out.stdout)\(out.stderr)"
                         + (result.denied.isEmpty ? "" : "\ndenied: \(result.denied.joined(separator: ", "))"),
                         folder: folder, target: id)
            return result.dispatch
        } catch is CancellationError {
            DoLog.append("claude in \(workingFolder.path) stopped before it finished (Earshot quit)", folder: folder, target: id)
            return .stopped
        } catch {
            return DispatchResult(ok: false, detail: error.localizedDescription)
        }
    }

    struct Outcome {
        var dispatch: DispatchResult
        var denied: [String] = []
    }

    static func textResult(_ out: ProcessOutput) -> Outcome {
        if out.timedOut { return Outcome(dispatch: DispatchResult(ok: false, detail: "timed out")) }
        let report = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(dispatch: out.status == 0 ? DispatchResult(ok: true, detail: String(report.suffix(200)))
                       : DispatchResult(ok: false, detail: "exit \(out.status): \(String(out.stderr.suffix(200)))"))
    }

    /// Reads the JSON envelope. An error, a subtype other than success, or any permission denial means the work
    /// failed or was only partly done, and the detail names what was denied.
    static func restrictedResult(_ out: ProcessOutput) -> Outcome {
        if out.timedOut { return Outcome(dispatch: DispatchResult(ok: false, detail: "timed out")) }
        guard let envelope = (try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8))) as? [String: Any] else {
            let said = (out.stderr.isEmpty ? out.stdout : out.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return Outcome(dispatch: DispatchResult(ok: false, detail: plainLine(said, status: out.status)
                                                    ?? "exit \(out.status): \(String(said.suffix(200)))"))
        }
        let report = ((envelope["result"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let denied = deniedPaths(envelope["permission_denials"])
        if !denied.isEmpty {
            return Outcome(dispatch: DispatchResult(ok: false, detail: String("Partly done. Denied: \(denied.joined(separator: ", "))".prefix(300))),
                           denied: denied)
        }
        let subtype = envelope["subtype"] as? String ?? ""
        let isError = out.status != 0 || envelope["is_error"] as? Bool == true
        if isError || subtype != "success" {
            let why = report.isEmpty ? (subtype.isEmpty ? "exit \(out.status)" : subtype) : report
            let plain = isError ? plainLine(why, status: out.status) : nil
            return Outcome(dispatch: DispatchResult(ok: false, detail: plain ?? String(why.suffix(200))))
        }
        return Outcome(dispatch: DispatchResult(ok: true, detail: String(report.suffix(200))))
    }

    /// The plain line notes use for the same problem (spec 3.1 and 16): sign-in, usage limit or an old Claude Code.
    /// Anything else returns nil and keeps what Claude Code said, which the log also holds in full.
    static func plainLine(_ said: String, status: Int32) -> String? {
        let error = ClaudeFailure.error(said, status: status, model: "")
        switch error {
        case .notSignedIn, .usageLimit, .claudeTooOld: return error.errorDescription
        default: return nil
        }
    }

    /// The file each denied tool call was for, or the tool's name when it had no file.
    static func deniedPaths(_ value: Any?) -> [String] {
        guard let denials = value as? [[String: Any]] else { return [] }
        return denials.map { denial in
            let input = denial["tool_input"] as? [String: Any] ?? [:]
            let path = ["file_path", "path", "notebook_path"].lazy.compactMap { input[$0] as? String }.first
            return path ?? (denial["tool_name"] as? String ?? "a tool")
        }
    }
}

/// A target that is switched on but can't run (Claude Code not found, no work folder). Sending to it fails with
/// the reason, so it is never dropped without a word, and Retry tries again once Settings are fixed.
public struct UnavailableTarget: DoTarget {
    public let id: String
    public let label: String
    public let reason: String

    public init(id: String, label: String, reason: String) {
        self.id = id
        self.label = label
        self.reason = reason
    }

    public func send(_ payload: DoPayload, json: Data, folder: URL) async -> DispatchResult {
        DoLog.append("not sent: \(reason)", folder: folder, target: id)
        return DispatchResult(ok: false, detail: reason)
    }
}
