import Foundation

extension EarshotCLI {
    /// Everything the tool reads from or does to the outside world. `standard` is the real one; tests replace parts.
    public struct IO: Sendable {
        public var out: @Sendable (String) -> Void
        public var err: @Sendable (String) -> Void
        /// One line of standard input without its newline, or nil at the end (for `mcp`).
        public var readLine: @Sendable () -> String?
        public var environment: [String: String]
        /// The settings saved in a defaults domain (the app's own unless EARSHOT_SETTINGS_DOMAIN names another), or nil
        /// when none were saved there. Never writes them.
        public var savedSettings: @Sendable (_ domain: String) -> EarshotSettings?
        public var home: URL
        public var indexURL: URL
        /// This program's path, for the translocation check.
        public var executablePath: String
        public var now: @Sendable () -> Date
        public var timeZone: TimeZone
        public var pid: Int32
        public var transcriber: any Transcribing
        public var compressor: any AudioCompressing
        /// Runs `claude` for notes, the status check and the Claude Code target.
        public var runner: any ProcessRunning
        /// For the webhook target and the API-key provider.
        public var urlSession: URLSession
        /// The user's `claude` for a Settings override (which may be blank), or nil.
        public var locateClaude: @Sendable (String?) async -> String?
        /// Makes sure the speech model for a locale is on this Mac, downloading it if needed.
        public var prepareSpeech: @Sendable (Locale) async throws -> Void
        /// Called once before `mcp` starts reading: the real one ignores SIGPIPE and exits cleanly on SIGINT and
        /// SIGTERM.
        public var prepareToServe: @Sendable () -> Void
        /// Traps Ctrl-C and SIGTERM while `process` runs, and returns the call that removes the trap. The first
        /// signal calls `stop`; in the real one a second calls `cleanUp` and quits (exit 130), and a third quits.
        public var trapInterrupts: @Sendable (_ stop: @escaping @Sendable () -> Void,
                                              _ cleanUp: @escaping @Sendable () -> Void) -> @Sendable () -> Void
            = EarshotCLI.trapSignals
        /// The Messages API endpoint for the API-key provider.
        public var anthropicEndpoint = ClaudeAPIClient.defaultEndpoint

        public static var standard: IO {
            IO(out: { write($0, to: .standardOutput) },
               err: { write($0, to: .standardError) },
               readLine: { Swift.readLine(strippingNewline: true) },
               environment: ProcessInfo.processInfo.environment,
               savedSettings: { EarshotCLI.savedAppSettings(domain: $0) },
               home: FileManager.default.homeDirectoryForCurrentUser,
               indexURL: LibraryIndex.defaultURL,
               executablePath: Bundle.main.executablePath ?? CommandLine.arguments.first ?? "",
               now: { Date() },
               timeZone: .current,
               pid: ProcessInfo.processInfo.processIdentifier,
               transcriber: AppleSpeechTranscriber(),
               compressor: AudioCompressor(),
               runner: ProcessRunner(),
               urlSession: .shared,
               locateClaude: { override in
                   if let found = ClaudeLocator.find(override: override) { return found }
                   return await ClaudeLocator.findViaShell()
               },
               prepareSpeech: { try await AppleSpeechTranscriber.prepare(locale: $0) },
               prepareToServe: {
                   signal(SIGPIPE, SIG_IGN)
                   signal(SIGINT) { _ in _exit(0) }
                   signal(SIGTERM) { _ in _exit(0) }
               })
        }

        /// One write per message, so an MCP reply line is never split.
        static func write(_ text: String, to handle: FileHandle) {
            try? handle.write(contentsOf: Data(text.utf8))
        }
    }

    /// What one more SIGINT or SIGTERM does while `process` runs, counting from 1.
    enum InterruptAction: Equatable {
        /// Stop the run; `process` then makes the meeting safe and exits as usual.
        case stop
        /// Make the meeting safe now, without waiting for the run, and quit.
        case cleanUpAndQuit
        /// Quit at once, even if the clean-up is stuck.
        case quit
    }

    static func interruptAction(press: Int) -> InterruptAction {
        switch press {
        case ...1: .stop
        case 2: .cleanUpAndQuit
        default: .quit
        }
    }

    /// The real `trapInterrupts`: the first SIGINT or SIGTERM calls `stop`, the second runs `cleanUp` and quits with
    /// 130, and any later one quits at once. The returned call puts the default handling back.
    static func trapSignals(_ stop: @escaping @Sendable () -> Void,
                            _ cleanUp: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let signals = [SIGINT, SIGTERM]
        let presses = Locked(0)
        let sources = Locked(signals.map { number -> any DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                var press = 0
                presses.update { $0 += 1; press = $0 }
                switch interruptAction(press: press) {
                case .stop: stop()
                case .cleanUpAndQuit:
                    cleanUp()
                    _exit(130)
                case .quit: _exit(130)
                }
            }
            source.resume()
            return source
        })
        return {
            sources.get.forEach { $0.cancel() }
            signals.forEach { signal($0, SIG_DFL) }
        }
    }

    /// The settings Earshot saved, read without saving anything. Nil when the app never saved settings.
    static func savedAppSettings(domain: String = appDomain) -> EarshotSettings? {
        // A helper inside the app shares its bundle id, and UserDefaults won't open its own id as a suite.
        let defaults = Bundle.main.bundleIdentifier == domain ? UserDefaults.standard : UserDefaults(suiteName: domain)
        guard let defaults, defaults.data(forKey: EarshotSettings.defaultsKey) != nil else { return nil }
        // With a saved blob, `load` only decodes it: it never writes and never reads the secrets.
        return EarshotSettings.load(from: defaults, secrets: EnvironmentSecrets(environment: [:]))
    }

    /// Secrets for the command-line tool come from the environment only, never the Keychain (spec 11.2).
    struct EnvironmentSecrets: SecretReading {
        static let names: [KeychainStore.Item: String] = [
            .anthropicKey: "ANTHROPIC_API_KEY", .webhookToken: "EARSHOT_WEBHOOK_TOKEN", .routineToken: "EARSHOT_ROUTINE_TOKEN",
        ]

        let environment: [String: String]

        func read(_ item: KeychainStore.Item) -> String? {
            guard let name = Self.names[item],
                  let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
    }
}
