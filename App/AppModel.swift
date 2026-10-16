import AppKit
import AVFoundation
import EarshotKit
import Observation
import os
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension Stage {
    var label: String {
        switch self {
        case .transcribe: "Transcription"
        case .notes: "Notes"
        case .dispatch: "Sending"
        case .compress: "Compression"
        }
    }

    var activeText: String {
        switch self {
        case .transcribe: "Transcribing…"
        case .notes: "Writing notes…"
        case .dispatch: "Sending…"
        case .compress: "Compressing audio…"
        }
    }
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    static let consentReminder = "Tell everyone you're recording."
    nonisolated static let log = Logger(subsystem: "com.stephenthorn.earshot", category: "app")
    static let micDeniedText = "Earshot can't use the microphone. Allow it in System Settings, Privacy & Security, Microphone."

    var settings: EarshotSettings {
        didSet {
            snapshot.update { $0 = settings }
            if !e2e { settings.save() }
            if oldValue.saveFolder != settings.saveFolder { buildPipeline() }
            watchersFollowSettings(from: oldValue)  // v2: calendar, calls and screen reading follow their switches
            liveSettingsChanged(from: oldValue)  // v2: hotkeys and the live panel follow Settings (B2)
        }
    }
    var mode: Mode
    var title = ""
    var isRecording = false
    /// Between pressing Record and capture running: waiting on the mic prompt or on Core Audio.
    var isStarting = false
    var elapsed: TimeInterval = 0
    var levels = CaptureSession.Levels()
    var sessions: [Session] = []
    var activity: [String: Stage] = [:]
    /// v2: meetings whose Write notes was pressed and hasn't finished, so the button hides at once.
    var writingNotes: Set<String> = []
    var banner: String?
    var micDenied = false
    var e2e = false
    var livePanelVisible = false  // v2: set by the live panel (B2), read by the consent rule (B3)
    /// The Settings tab shown. Links into Settings set it first, so they open at the right tab.
    var settingsTab = SettingsTab.general

    var isProcessing: Bool { !activity.isEmpty }
    var confirmRequest: ConfirmRequest? { pendingConfirms.first?.request }
    var currentSessionID: String? { current?.id }
    var store: SessionStore { SessionStore(root: URL(fileURLWithPath: settings.saveFolder)) }
    /// The banner says notes aren't set up, so the panel offers a "Set up notes" link next to it.
    /// v2: the setup problem is one line of the banner now that the recording starts anyway (B3). v3: any provider's.
    var bannerNeedsSetup: Bool { NotesSetup.needsSetup(banner: banner) }

    let keychain = KeychainStore()
    let windows = WindowPresenter()
    // v2: calendar, call detection and screen reading (B3)
    let context = ContextController()
    let calls = CallController()
    @ObservationIgnored let screen = ScreenController()
    /// v2: the live assistant, flags and the live panel (B2).
    @ObservationIgnored private(set) lazy var liveController = LiveController(model: self)
    @ObservationIgnored private let snapshot: Locked<EarshotSettings>
    /// v2: the library index and lessons.json. An e2e run sets its own, so it never touches the user's.
    @ObservationIgnored private let locations = Locked(DataLocations.standard)
    var dataLocations: DataLocations {
        get { locations.get }
        set { locations.update { $0 = newValue } }
    }
    @ObservationIgnored private(set) var pipeline: Pipeline!
    @ObservationIgnored private var capture: CaptureSession?
    @ObservationIgnored private var current: Session?
    /// The store the current recording was started in. Stop saves and processes it there, whatever the save folder is by then.
    @ObservationIgnored private var recordingStore: SessionStore?
    @ObservationIgnored private var pipelineRoot = URL(fileURLWithPath: "/")
    @ObservationIgnored private var recordingStarted = Date()
    @ObservationIgnored private var nextDiskCheck = Date()
    @ObservationIgnored private var timer: Timer?
    // v2: internal so AppModel+Confirm.swift can reach it.
    var pendingConfirms: [(request: ConfirmRequest, reply: CheckedContinuation<[ActionItem]?, Never>)] = []

    init() {
        let loaded = EarshotSettings.load()
        settings = loaded
        mode = loaded.defaultMode
        snapshot = Locked(loaded)
        buildPipeline()
    }

    // v2: screenshots. A model over sample settings for `--render-screenshots`: the user's settings are never read,
    // and `e2e` keeps every change from being saved.
    init(sample: EarshotSettings) {
        settings = sample
        mode = sample.defaultMode
        snapshot = Locked(sample)
        e2e = true
        buildPipeline()
    }

    /// Pipeline runs are started in unstructured tasks and never cancelled: a cancelled run leaves its stage
    /// pending with no event. Automatic resumes go through `resumeAll()`, which honours the two-failure stop.
    func buildPipeline() {
        pipelineRoot = store.root
        pipeline = makePipeline(store)
    }

    /// The pipeline for meetings in `store`: the shared one, or a pipeline of its own for a meeting in another folder.
    func pipeline(for store: SessionStore) -> Pipeline {
        store.root == pipelineRoot ? pipeline : makePipeline(store)
    }

    private func makePipeline(_ store: SessionStore) -> Pipeline {
        let snapshot = snapshot, keychain = keychain, locations = locations
        return Pipeline(
            store: store, transcriber: AppleSpeechTranscriber(), compressor: AudioCompressor(),
            makeWriter: { try snapshot.get.notesWriter(secrets: keychain) },
            makeTargets: { snapshot.get.targets(secrets: keychain) },
            config: { snapshot.get.pipelineConfig(at: locations.get) },
            // v2: the store, so the confirm window can read the meeting's live.json.
            confirm: { [weak self] session, notes in await self?.askToConfirm(session, notes, store: store) ?? nil },
            events: { [weak self] event in Task { @MainActor in self?.handle(event) } })
    }

    func launched() {
        if E2E.configure(self) { return }
        _ = try? store.recover()
        liveController.recover(in: store)  // v2: live to-dos left sending become interrupted
        refresh()
        // v2: meetings deleted in Finder leave the CLI, MCP and plugins (spec 11.1). The reconcile runs first, off
        // the main actor, so a resumed run's fresher index entry is never overwritten by an older one.
        let runner: Pipeline = pipeline
        Task {
            await reconcileLibraryIndex()
            await runner.resumeAll()
        }
        startWatchers()  // v2: calendar and call detection, each only while switched on (B3)
        showWelcomeIfNeeded()  // v2: onboarding for new users, "New in v0.2" once for upgrading ones
    }

    /// The reconcile pass at launch (spec 11.1), off the main actor and best effort: what goes wrong is logged.
    private func reconcileLibraryIndex() async {
        let store = store, userName = settings.userName, log = Self.log
        let index = LibraryIndex(url: dataLocations.index)
        await Task.detached(priority: .utility) {
            let problems = index.refreshAtLaunch(with: store, userName: userName, now: Date())
            for problem in problems { log.error("\(problem, privacy: .public)") }
        }.value
    }

    func refresh() {
        sessions = Array(store.all().prefix(10))
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        micDenied = mic == .denied || mic == .restricted
    }

    // MARK: Recording

    func setupProblem(for mode: Mode) -> String? {
        mode == .record ? nil : settings.notesSetupProblem(secrets: keychain)
    }

    /// Every check runs before anything starts. Nothing here blocks the main actor: the mic prompt is awaited, and
    /// capture starts on another thread, because AVAudioEngine.inputNode waits on coreaudiod (for as long as a
    /// permission prompt is unanswered). `isStarting` keeps Record from being pressed twice; Stop only acts once
    /// capture is running, since `capture`, `current` and `recordingStore` are set after start returns.
    /// v2: capture never waits for Claude (spec 2): a Claude setup problem goes in the banner and the recording
    /// starts. `trigger` and `call` say whether call detection started it (B3).
    func startRecording(trigger: StartTrigger = .manual, call: CallEvent.Call? = nil) async {
        guard !isRecording, !isStarting else { return }
        let mode = self.mode, title = self.title
        let store = self.store
        // One line each, so the consent reminder never hides a disk or Do warning.
        let check = RecordingStart.check(setupProblem: setupProblem(for: mode), disk: diskLevel(store.root))
        if let blocker = check.blocker {
            banner = blocker
            return
        }
        var notices = check.notices
        isStarting = true
        defer { isStarting = false }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        refresh()  // picks up the answer: a denied mic disables Record and offers "Grant microphone access"
        guard !micDenied else {
            banner = Self.micDeniedText
            return
        }
        let start = recordingStart(mode: mode, typedTitle: title, trigger: trigger)  // v2: event, profile, trigger
        do {
            var session = try store.create(mode: mode, title: start.title, startedBy: trigger)
            let capture = CaptureSession()
            let folder = store.folder(session), echoCancellation = settings.echoCancellation
            liveController.prepare(capture: capture, session: session, store: store, mode: mode)  // v2: live feed first
            do {
                try await Task.detached { try capture.start(in: folder, echoCancellation: echoCancellation) }.value
            } catch {
                liveController.discard()  // v2
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            // So a recording a crash interrupts still points at its audio when it is recovered. Stop fills in the
            // real offsets. Best effort: if this save fails, Stop saves the tracks anyway.
            session.tracks = Self.startedTracks(in: folder)
            start.apply(to: &session)  // v2
            try? store.save(session)
            self.capture = capture
            current = session
            recordingStore = store
            isRecording = true
            recordingStarted = Date()
            elapsed = 0
            // Say now, not at Stop, that a track didn't start (call audio, say): the user can still fix it.
            notices += capture.startWarnings
            if settings.consentReminder { notices.append(Self.consentReminder) }
            if mode == .notesAndDo {
                if let problem = settings.doTargetProblems().first {
                    notices.append(problem)
                } else if settings.doTargetLabels().isEmpty {
                    notices.append("No Do target is on, so nothing will be sent. Set one up in Settings, Do.")
                }
            }
            banner = notices.isEmpty ? nil : notices.joined(separator: "\n")
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            // .common includes the modal panel mode, so the clock, the meters and the disk stop keep going while a
            // dialog such as Import's open panel is up.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            // v2: the live panel first, so livePanelVisible is known when the consent rule runs in recordingDidStart.
            liveController.begin()  // v2: live work, the consent banner and the panel (B2)
            recordingDidStart(session, store: store, call: call, capture: capture)  // v2: calendar, calls, screen, consent (B3)
            refresh()
        } catch {
            banner = error.localizedDescription
        }
    }

    /// The files CaptureSession opened: it writes mic.caf and system.caf, and deletes the file of a track that failed to start.
    static func startedTracks(in folder: URL) -> [TrackFile] {
        [(Track.me, "mic.caf"), (Track.them, "system.caf")]
            .filter { FileManager.default.fileExists(atPath: folder.appending(path: $0.1).path) }
            .map { TrackFile(track: $0.0, file: $0.1, offset: 0) }
    }

    func tick() {
        elapsed = Date().timeIntervalSince(recordingStarted)
        levels = capture?.levels ?? CaptureSession.Levels()
        guard Date() >= nextDiskCheck else { return }
        nextDiskCheck = Date().addingTimeInterval(30)
        if let root = recordingStore?.root, diskLevel(root) == .critical {
            stopRecording()
            // Keep anything Stop reported (a full disk can also fail the save).
            banner = ["Recording stopped: less than 500 MB of disk space was left.", banner].compactMap { $0 }.joined(separator: "\n")
        }
    }

    /// How full the drive is that holds (or will hold) the save folder `root`; nil if it can't be read.
    func diskLevel(_ root: URL) -> DiskSpace.Level? {
        DiskSpace.free(near: root).map { DiskSpace.level(freeBytes: $0) }
    }

    /// `process: false` saves the meeting without starting its pipeline, for quitting: the next launch resumes it.
    func stopRecording(process: Bool = true) {
        guard let capture, let session = current, let store = recordingStore else { return }
        timer?.invalidate()
        timer = nil
        let (tracks, warnings) = capture.stop()
        // v2: finishes in the background, never delays Stop (B2); queued live to-dos are taken back first
        let liveTakenBack = liveController.end()
        let screenSaved = recordingWillStop()  // v2: calendar, calls and screen (B3)
        let endedAt = Date().wholeSeconds
        var saveProblem: String?
        // v2: through update (spec 14.3), so the event and the flags saved during the recording are kept; from memory
        // when session.json can't be read.
        do {
            try store.finishRecording(session, tracks: tracks, warnings: warnings, endedAt: endedAt)
        } catch {
            // session.json still says "recording", so the pipeline would skip it now. The next launch's recover(),
            // which scans the save folder, closes it and resumes it.
            saveProblem = "Couldn't save this meeting's record (\(error.localizedDescription)). Its audio is kept in "
                + "\(store.folder(session).path). Earshot will process it the next time it opens, as long as the save "
                + "folder is still \(store.root.path)."
        }
        self.capture = nil
        current = nil
        recordingStore = nil
        isRecording = false
        levels = CaptureSession.Levels()
        title = ""
        if let shown = banner {
            let kept = shown.split(separator: "\n").filter { $0 != Self.consentReminder }.joined(separator: "\n")
            banner = kept.isEmpty ? nil : kept
        }
        // Say once what went wrong with the audio (silent call audio, a track that never started); it is in session.json too.
        if !warnings.isEmpty { banner = warnings.joined(separator: " ") }
        if let saveProblem { banner = saveProblem }
        refresh()
        if let saveProblem {
            if e2e { E2E.failed(session.id, saveProblem) }
            return
        }
        guard process else { return }
        let id = session.id, runner = pipeline(for: store)
        Task {
            await screenSaved.value  // v2: screen.json is saved before the notes read it
            await liveTakenBack?.value  // live.json no longer holds a queued to-do the notes could miss
            await runner.run(sessionID: id)
        }
    }

    func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let mode: Mode = self.mode == .record ? .notes : self.mode
        if let problem = setupProblem(for: mode) {
            banner = problem
            return
        }
        do {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let duration = (try? AudioCompressor().duration(of: url)) ?? 0
            let session = try store.importAudio(from: url, mode: mode, startedAt: created, duration: duration)
            refresh()
            Task { await pipeline.run(sessionID: session.id) }
        } catch {
            banner = error.localizedDescription
        }
    }

    // MARK: Quitting

    /// False if the user chose to keep Earshot open. Otherwise a running recording is stopped and saved, and every
    /// program Earshot started is stopped, so nothing keeps working on its own after Earshot has gone.
    func prepareToQuit() -> Bool {
        let busy = quitBusyLabels  // v2: live Start runs too
        if !busy.isEmpty, !e2e {
            let alert = NSAlert()
            alert.messageText = "Quit anyway?"
            alert.informativeText = quitWarningText  // v2: live to-dos are marked Interrupted, not retried
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        if isRecording { stopRecording(process: false) }
        liveController.holdQueues()  // v2: no live job starts once its programs are stopped
        ProcessRegistry.shared.terminateAll()
        return true
    }

    /// Do targets working right now that won't be sent again on their own once stopped (Claude Code, a command).
    /// One switched off in Settings since it started isn't known to be safe to stop, so it counts too.
    func busyTargetLabels() -> [String] {
        let sending = Set(store.all().flatMap(\.sendingTargets))
        guard !sending.isEmpty else { return [] }
        let known = Dictionary(settings.targets(secrets: keychain).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return sending.sorted().compactMap { id in
            known[id]?.repeatsSafely == true ? nil : known[id]?.label ?? id
        }
    }

    // MARK: Meetings

    func retry(_ session: Session) { Task { await pipeline.retry(sessionID: session.id) } }

    /// v2: "Write notes" on a finished Record meeting: it becomes a Notes meeting, then is transcribed and
    /// summarized. Needs notes set up, like Import.
    func writeNotes(for session: Session) {
        let id = session.id
        guard !writingNotes.contains(id) else { return }  // a second click before the first stage starts
        if let problem = setupProblem(for: .notes) {
            banner = problem
            return
        }
        let runner: Pipeline = pipeline
        writingNotes.insert(id)
        Task {
            do {
                try await runner.writeNotesForRecording(sessionID: id)
            } catch {
                banner = error.localizedDescription
            }
            writingNotes.remove(id)
            refresh()
        }
    }

    /// v2: notes.html first, then notes.md, then the folder (spec 10).
    func open(_ session: Session) {
        NSWorkspace.shared.open(MeetingOpener.target(folder: store.folder(session)))
    }

    func statusText(_ session: Session) -> String {
        if session.recording { return "Recording" }
        if let stage = activity[session.id] { return stage.activeText }
        if let failed = session.failedStage { return "\(failed.label) failed: \(session.stages[failed]?.error ?? "")" }
        if session.nextStage != nil { return "Waiting" }
        if session.mode == .notesAndDo, !session.sent.isEmpty { return "Notes ready, sent" }
        return session.mode == .record ? "Recorded" : "Notes ready"
    }

    func handle(_ event: PipelineEvent) {
        switch event {
        case let .started(id, stage):
            activity[id] = stage
        case let .failed(id, stage, message):
            activity[id] = nil
            notify("\(stage.label) failed", message, path: nil)
            if e2e { E2E.failed(id, message) }
        case let .notesReady(_, notes):
            notify("Notes ready", notes.deletingLastPathComponent().lastPathComponent, path: notes.path)
        case let .finished(id):
            activity[id] = nil
            // Record mode has no notes, so its notification points at the meeting folder instead.
            if let session = store.all().first(where: { $0.id == id }), session.mode == .record {
                notify("Recording saved", session.folderName, path: store.folder(session).path)
            }
            if e2e { E2E.finished(id) }
        }
        refresh()
    }

    func notify(_ title: String, _ body: String, path: String?) {
        guard !e2e else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let path { content.userInfo = ["path": path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Confirm

    // v2: the confirm glue is in AppModel+Confirm.swift.

    // MARK: Onboarding and helpers

    // v2: showOnboarding, finishOnboarding and the "New in v0.2" window are in OnboardingView.swift.

    func chooseFolder(_ done: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { done(url.path) }
    }

    /// Opens a pane of System Settings, Privacy & Security, such as "Privacy_Microphone".
    func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settings.launchAtLogin = on
        } catch {
            banner = "Couldn't change Open at login: \(error.localizedDescription)"
        }
    }
}
