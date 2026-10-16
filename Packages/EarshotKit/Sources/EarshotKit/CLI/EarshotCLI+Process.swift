import Foundation

/// `earshot process`: transcribes an audio file and writes notes into a new meeting folder, holding its `.busy`
/// marker the whole time (spec 14.3). It sends only with `--send --target <id> --yes`, and only to targets that
/// can't run arbitrary commands (spec 11.2).
extension EarshotCLI {
    /// The targets `process --send` may use.
    static let sendableTargets = ["webhook", "routine", "claude-code"]
    /// The routine token comes only from the environment (spec 11.2), so the app's "paste it in Settings" won't do.
    static let missingRoutineToken =
        "earshot reads the routine token only from EARSHOT_ROUTINE_TOKEN. Set it to the routine's API trigger token from claude.ai/code/routines."
    /// A badly formed token: again the variable is the place to fix it, not the app's Settings.
    static let wrongRoutineToken =
        "EARSHOT_ROUTINE_TOKEN should start with sk-ant-oat01-. Set it to the routine's API trigger token from claude.ai/code/routines."
    /// A 401 from the routine: the user updates the variable; earshot never deletes anything.
    static let rejectedRoutineToken =
        "\(RoutineTarget.unauthorized). Set EARSHOT_ROUTINE_TOKEN to the routine's new API trigger token from claude.ai/code/routines."
    /// The failure count at which the app stops resuming a stage on its own (`SessionStore.resumable`).
    static let autoResumeStop = 2
    static let sendInterrupted = "Sending was interrupted. Open Earshot and press Retry to choose what to send."
    static let notFinished = "The meeting didn't finish. Open Earshot and press Retry."

    /// `earshot process --json`.
    struct ProcessReport: Codable, Equatable {
        var id: String
        var title: String
        var folder: String
        var notes: String?
        var finished: Bool
        var sent: [String]
        var warnings: [String]
        var error: String?
    }

    static func process(_ arguments: Arguments, io: IO) async throws -> Int32 {
        guard arguments.positionals.count == 1, let path = arguments.positionals.first else {
            throw UsageError("process needs one audio file.")
        }
        let context = Context(arguments, io: io)
        let targetID = try sendRequest(arguments)
        let audio = URL(filePath: expand(path, home: io.home) ?? path)
        guard FileManager.default.fileExists(atPath: audio.path) else {
            io.err("earshot: There's no audio file at \(audio.path).\n")
            return 1
        }
        // Claude Code may be needed for the notes, for the send, or both, whatever the provider.
        let needsClaude = context.settings.provider == .claudeCode || targetID == "claude-code"
        let claudePath = needsClaude ? await io.locateClaude(context.settings.claudePath) : nil
        let target = try targetID.map { try sendTarget($0, settings: context.settings, claudePath: claudePath, io: io) }
        let writer = try notesWriter(context.settings, claudePath: claudePath, io: io)
        return try await run(audio, title: arguments.options["title"], target: target, writer: writer,
                             json: arguments.has("json"), context: context)
    }

    /// The target id to send to, or nil when nothing is sent. Throws a refusal for any half-given send.
    static func sendRequest(_ arguments: Arguments) throws -> String? {
        let send = arguments.has("send"), yes = arguments.has("yes"), target = arguments.options["target"]
        guard send else {
            if target != nil || yes {
                throw UsageError("--target and --yes work only with --send. Without --send, process never sends anything.")
            }
            return nil
        }
        guard let target, !target.isEmpty else {
            throw UsageError("--send needs --target <id>: webhook, routine or claude-code.")
        }
        guard yes else {
            throw UsageError("--send needs --yes to confirm that the AI's action items are sent without the confirm window.")
        }
        return target
    }

    /// A target's setup problem as the CLI says it: the routine's token messages name EARSHOT_ROUTINE_TOKEN, since
    /// earshot never reads the token the app keeps.
    static func cliReason(_ reason: String) -> String {
        switch reason {
        case RoutineTarget.missingToken: missingRoutineToken
        case RoutineTarget.wrongToken: wrongRoutineToken
        default: reason
        }
    }

    /// The one target `--target` names, built from the app's settings with tokens from the environment, or a refusal.
    static func sendTarget(_ id: String, settings: EarshotSettings, claudePath: String?, io: IO) throws -> any DoTarget {
        guard id != "command" else {
            throw UsageError("earshot process never sends to the Command target, because it runs a shell command. Use webhook, routine or claude-code.", showUsage: false)
        }
        guard sendableTargets.contains(id) else {
            throw UsageError("There's no Do target \"\(id)\". Use webhook, routine or claude-code.", showUsage: false)
        }
        if id == "claude-code", settings.permissionMode != ClaudeCodeTarget.restricted {
            throw UsageError("earshot process sends to Claude Code only in restricted mode, and Earshot is set to \(settings.permissionMode). Choose Restricted in Earshot Settings, Do.", showUsage: false)
        }
        let secrets = EnvironmentSecrets(environment: io.environment)
        let built = settings.targets(secrets: secrets, locate: { _ in claudePath }, isFolder: EarshotSettings.isFolder)
        guard let found = built.first(where: { $0.id == id }) else {
            throw UsageError("The \(id) target is off. Turn it on and set it up in Earshot Settings, Do.", showUsage: false)
        }
        switch found {
        case let unavailable as UnavailableTarget:
            throw UsageError(cliReason(unavailable.reason), showUsage: false)
        case var claude as ClaudeCodeTarget:
            claude.runner = io.runner
            return claude
        case var webhook as WebhookTarget:
            webhook.session = io.urlSession
            return webhook
        case var routine as RoutineTarget:
            routine.session = io.urlSession
            // The token is the environment's: on a 401 the user updates the variable, and the Keychain is never touched.
            routine.onUnauthorized = {}
            routine.unauthorizedDetail = rejectedRoutineToken
            return routine
        default:
            return found
        }
    }

    /// The notes writer for the app's provider. The API-key provider needs ANTHROPIC_API_KEY in the environment; the
    /// local provider needs the address and model set in Earshot.
    static func notesWriter(_ settings: EarshotSettings, claudePath: String?, io: IO) throws -> any NotesWriter {
        let client: any ClaudeClient
        switch settings.provider {
        case .claudeAPI:
            let secrets = EnvironmentSecrets(environment: io.environment)
            guard secrets.read(.anthropicKey) != nil else {
                throw UsageError("Earshot is set to use an API key, and earshot reads it only from ANTHROPIC_API_KEY. Set it, or switch to Claude Code in Settings.", showUsage: false)
            }
            client = ClaudeAPIClient(apiKey: { secrets.read(.anthropicKey) }, endpoint: io.anthropicEndpoint, session: io.urlSession)
        case .claudeCode:
            guard let claudePath else { throw NotesError.claudeNotFound }
            client = ClaudeCodeClient(claudePath: claudePath, runner: io.runner,
                                      slots: ClaudeSlots(folder: ClaudeSlots.defaultFolder(home: io.home)))
        case .local:
            if let problem = settings.localSetupProblem { throw UsageError(problem, showUsage: false) }
            client = try settings.localModelClient(session: io.urlSession)
        }
        return ClaudeNotesWriter(client: client, model: settings.model(for: .notes), effort: settings.effort(for: .notes))
    }

    static func run(_ audio: URL, title: String?, target: (any DoTarget)?, writer: any NotesWriter, json: Bool,
                    context: Context) async throws -> Int32 {
        let io = context.io, store = context.store
        let created = (try? audio.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? io.now()
        let duration = (try? io.compressor.duration(of: audio)) ?? 0
        var session = try store.importAudio(from: audio, mode: target == nil ? .notes : .notesAndDo, startedAt: created,
                                            duration: duration, busyPID: io.pid)
        let id = session.id
        defer { if let current = store.find(id) { store.clearBusy(current) } }
        session = try store.update(id) { session in
            session.startedBy = .cli
            // The AI's picks go out only in this run. On disk before any work, so even after a kill -9 the app
            // never sends them on its own; only Retry, which asks first, sends again.
            if target != nil { session.stages[.dispatch] = StageState(failures: autoResumeStop) }
        }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            session = try store.retitle(session, to: title)
        }
        var config = context.settings.pipelineConfig
        config.timeZone = io.timeZone
        // The index and lessons this run was pointed at, and its clock.
        config.index = context.index
        config.lessons = LessonsStore(url: context.lessonsURL)
        config.now = io.now
        let failure = Locked<String?>(nil)
        let pipeline = Pipeline(
            store: store, transcriber: io.transcriber, compressor: io.compressor, makeWriter: { writer },
            makeTargets: { target.map { [$0] } ?? [] }, config: { [config] in config },
            confirm: { _, notes in ActionItem.defaultSelection(notes.actionItems) },
            events: { event in
                switch event {
                case let .started(_, stage): io.err("earshot: \(label(stage))...\n")
                case let .failed(_, stage, message): failure.update { $0 = "\(label(stage)) failed: \(message)" }
                default: break
                }
            })
        // Ctrl-C or SIGTERM stops the run; the pipeline leaves the stage pending and the hold below makes it safe. A
        // second one can't wait for that, so it holds the send itself before quitting. The trap stays until this
        // returns, so no signal after the run but before the hold gets the default handling.
        // Through the held send: the hold is for the app, and this run is the one the agent asked for.
        let work = Task { await pipeline.run(sessionID: id, throughHeld: true) }
        let release = io.trapInterrupts({ work.cancel() }, { cleanUpBeforeQuitting(id, store: store, io: io) })
        defer { release() }
        await work.value
        guard let ended = store.find(id) else { throw SessionStoreError.notFound(id) }
        let final = try holdIfUnfinished(ended, store: store)
        updateIndex(final, store: store, config: config, context: context)
        let notes = store.file(final, MeetingFile.notesMarkdown)
        // A run can stop without a failed event (cancelled, or the pipeline had nothing to do): still a failure.
        let error = failure.get ?? (final.isFinished ? nil : final.nextStage == .dispatch ? sendInterrupted : notFinished)
        let report = ProcessReport(id: id, title: MeetingRecord.load(final, from: store).title, folder: store.folder(final).path,
                                   notes: FileManager.default.fileExists(atPath: notes.path) ? notes.path : nil,
                                   finished: final.isFinished, sent: final.sent, warnings: final.warnings, error: error)
        return try printReport(report, json: json, io: io)
    }

    /// Prints the report; exit 1 when the meeting didn't finish.
    static func printReport(_ report: ProcessReport, json: Bool, io: IO) throws -> Int32 {
        if json {
            io.out(try EarshotCLI.json(report))
        } else {
            var lines = ["\(report.title): \(report.folder)"]
            if let path = report.notes { lines.append("Notes: \(path)") }
            if !report.sent.isEmpty { lines.append(ItemStatus.sentText(report.sent) + ".") }
            lines += report.warnings
            io.out(lines.joined(separator: "\n") + "\n")
        }
        if let error = report.error {
            io.err("earshot: \(error)\n")
            return 1
        }
        return 0
    }

    /// Holds the send when this run was to send and didn't finish sending. A sent meeting keeps its items.json, which
    /// records what went out.
    static func holdIfUnfinished(_ session: Session, store: SessionStore) throws -> Session {
        guard session.mode == .notesAndDo, session.stages[.dispatch]?.status != .done else { return session }
        return try holdUnfinishedSend(session, store: store)
    }

    /// A second Ctrl-C quits without waiting for the run: hold an unfinished send and clear the busy marker first.
    /// Only a kill -9 now leaves the AI's picks on disk.
    static func cleanUpBeforeQuitting(_ id: String, store: SessionStore, io: IO) {
        guard let current = store.find(id) else { return }
        do {
            _ = try holdIfUnfinished(current, store: store)
        } catch {
            io.err("earshot: The unfinished send couldn't be held for Retry: \(describe(error))\n")
        }
        if let latest = store.find(id) { store.clearBusy(latest) }
    }

    /// A send that didn't finish (failed, cut off or interrupted) must never be finished by the app without a person:
    /// the stage is held past the auto-resume stop, and the AI's picks are removed so Retry opens the confirm window.
    static func holdUnfinishedSend(_ session: Session, store: SessionStore) throws -> Session {
        var held = session
        if session.nextStage == .dispatch {
            held = try store.update(session.id) { current in
                let state = current.stages[.dispatch] ?? StageState()
                current.stages[.dispatch] = StageState(status: .failed,
                                                       error: state.status == .failed ? state.error : sendInterrupted,
                                                       failures: max(state.failures, autoResumeStop))
            }
        }
        let items = store.file(held, MeetingFile.items)
        if FileManager.default.fileExists(atPath: items.path) { try FileManager.default.removeItem(at: items) }
        return held
    }

    /// The index entry and reminders for this meeting, so the CLI, MCP and the app see it straight away. A
    /// failure here is only a warning: the meeting folder is complete.
    static func updateIndex(_ session: Session, store: SessionStore, config: PipelineConfig, context: Context) {
        do {
            let transcript = try store.readIfPresent([Segment].self, session, MeetingFile.transcript) ?? []
            try context.index.write(MeetingRecord.load(session, from: store), transcript: transcript, names: config.names,
                                    userName: context.settings.userName)
            try context.index.writeReminders(userName: context.settings.userName, now: context.io.now())
        } catch {
            context.io.err("earshot: The meeting was saved, but the index wasn't updated: \(describe(error))\n")
        }
    }

    static func label(_ stage: Stage) -> String {
        switch stage {
        case .transcribe: "Transcribing"
        case .notes: "Writing notes"
        case .dispatch: "Sending"
        case .compress: "Compressing the audio"
        }
    }
}
