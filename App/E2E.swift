import AppKit
import EarshotKit
import Foundation

/// `Earshot --e2e <mode> <seconds> <folder> [<data folder>]`: record for <seconds> into <folder>, with Claude Code notes
/// and a command target that saves the payload, then quit. Scripts/e2e.sh drives it. Nothing is saved to the real
/// Settings, and the run's library index and lessons are in <data folder> (a temporary one when it is left out).
/// Writes `e2e-recording` once capture is running (the script starts the meeting then) and `e2e-done` at the end.
///
/// `Earshot --e2e-import <audio> <folder> [<data folder>] [--local <url> <model>]`: imports <audio> into <folder> as a
/// Notes + Do meeting and runs the whole pipeline with the user's own Claude Code (or, with `--local`, that local model
/// server), then quits (Scripts/e2e-import.sh). It never records, so it asks for no permission. Writes `e2e-session` (the meeting id) once the import is saved and `e2e-done` at the end.
@MainActor
enum E2E {
    static let callAudioDenied = "call audio permission not granted (allow Earshot under Privacy & Security > Screen & System Audio Recording)"
    static var sessionID: String?
    static var folder: URL?
    private static var done = false

    /// The library index and lessons go to the run's data folder (`E2ELaunch`), never to the user's own.
    static func configure(_ model: AppModel) -> Bool {
        guard let launch = E2ELaunch.parse(CommandLine.arguments) else { return false }
        folder = launch.meetings
        model.e2e = true
        model.dataLocations = launch.data
        switch launch {
        case let .record(mode, seconds, meetings, _):
            var settings = EarshotSettings.e2e(saveFolder: meetings, claudePath: model.settings.claudePath)
            settings.claudeCodeModel = "sonnet"
            model.settings = settings
            model.mode = mode
            model.title = "E2E check"
            Task { await run(model, seconds: seconds) }
        case let .importAudio(audio, meetings, _, local):
            // Only the Claude Code path override comes from the loaded settings; E2ESettingsTests prove the rest.
            model.settings = EarshotSettings.e2eImport(saveFolder: meetings, claudePath: model.settings.claudePath,
                                                       local: local.map { (url: $0.url, model: $0.model) })
            model.mode = .notesAndDo
            Task { await runImport(model, audio: audio) }
        }
        return true
    }

    // MARK: Import

    /// The same steps as Import in the menu, without the open panel. The run ends on the pipeline's finished or
    /// failed event, or here from the saved stages if the run returned without one.
    static func runImport(_ model: AppModel, audio: URL) async {
        guard FileManager.default.isReadableFile(atPath: audio.path) else {
            finish(error: "the audio file can't be read: \(audio.path)")
            return
        }
        if let problem = model.setupProblem(for: .notesAndDo) {
            finish(error: problem)
            return
        }
        let store = model.store
        let session: Session
        do {
            let created = (try? audio.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let duration = (try? AudioCompressor().duration(of: audio)) ?? 0
            session = try store.importAudio(from: audio, mode: .notesAndDo, startedAt: created, duration: duration)
        } catch {
            finish(error: "import failed: \(error.localizedDescription)")
            return
        }
        sessionID = session.id
        mark("e2e-session", session.id)
        model.refresh()
        await model.pipeline(for: store).run(sessionID: session.id)
        // Events arrive on the main actor after `run` returns; let them land first.
        await Task.yield()
        guard !done else { return }
        let saved = store.all().first { $0.id == session.id }
        if let saved, saved.isFinished {
            finish(error: nil)
        } else {
            let stage = saved?.nextStage
            let reason = stage.flatMap { saved?.stages[$0]?.error } ?? "the pipeline stopped before \(stage?.label ?? "the end")"
            finish(error: reason)
        }
    }

    static func run(_ model: AppModel, seconds: Double) async {
        // Without call audio the meeting can't be heard, so fail now with the reason instead of after the whole run.
        // The check plays a short sound and listens for it, off the main thread.
        guard await SystemAudioCheck.run() else {
            finish(error: callAudioDenied)
            return
        }
        await model.startRecording()
        guard model.isRecording, let id = model.currentSessionID else {
            finish(error: model.banner ?? "recording didn't start")
            return
        }
        sessionID = id
        mark("e2e-recording", id)
        try? await Task.sleep(for: .seconds(seconds))
        model.stopRecording()
    }

    static func finished(_ id: String) { if id == sessionID { finish(error: nil) } }
    static func failed(_ id: String, _ message: String) { if id == sessionID { finish(error: message) } }

    /// Always leaves a result for the script, even when recording never started and the folder was never made,
    /// so it can tell a failure from a hang. If even that write fails, the result goes to stderr.
    static func finish(error: String?) {
        guard !done else { return }
        done = true
        mark("e2e-done", error ?? "ok")
        NSApp.terminate(nil)
    }

    static func mark(_ name: String, _ text: String) {
        guard let folder else { return }
        do {
            try writeMarker(text, named: name, in: folder)
        } catch {
            NSLog("%@", "Earshot e2e: couldn't write \(name) in \(folder.path) (\(error.localizedDescription)). Result: \(text)")
        }
    }

    static func writeMarker(_ text: String, named name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appending(path: name), options: .atomic)
    }
}
