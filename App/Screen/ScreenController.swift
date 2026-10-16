import AppKit
import CoreGraphics
import EarshotKit
import Foundation
import os

/// Reading the screen during a recording (spec 9): only while "Read my screen during calls" is on and Screen Recording
/// is allowed. A ScreenSampler captures the call app's windows every 15 s and saves screen.json in the meeting folder;
/// it is saved once more at stop. With no call app known it captures nothing.
@MainActor
final class ScreenController {
    /// How long Stop waits for a sample in progress before saving the moments already kept. System capture and
    /// Vision calls ignore cancellation and can hang around permission or display changes.
    static let stopWait = Duration.seconds(10)

    private var sampler: ScreenSampler?
    private var task: Task<Void, Never>?
    /// The running sampler's options, and the save of a sampler stopped during the recording, for Stop to wait on.
    private var saves = ScreenSaves()
    /// The call app's bundle prefix once known. Read by the sampler on its own executor.
    private let pinned = Locked<String?>(nil)
    /// Running apps, kept fresh as apps launch and quit, so a Safari call opened after Record is still matched.
    private let runningApps = Locked<[String: String]>([:])
    private var appObservers: [any NSObjectProtocol] = []
    private let log = Logger(subsystem: "com.stephenthorn.earshot", category: "screen")

    /// Asks for Screen Recording (the system prompt shows once; the app must relaunch after the grant). True when it
    /// is already allowed.
    static func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Starts reading for the meeting in `folder`. `clock` gives seconds on the meeting clock.
    func start(folder: URL, call: CallEvent.Call?, settings: EarshotSettings, clock: @escaping @Sendable () -> Double?) {
        stopSampling()
        saves.started(nil)
        guard ScreenReading.shouldRun(settings: settings, hasPermission: Self.hasAccess) else { return }
        let options = ScreenReading.options(settings: settings)
        pinned.update { $0 = ScreenReading.appPrefix(for: call) }
        followRunningApps()
        let pinned = pinned, apps = runningApps, me = ProcessInfo.processInfo.processIdentifier
        // Without a call from call detection, the call app using the microphone now, looked up at each sample.
        let prefix: @Sendable () -> String? = {
            pinned.get ?? ScreenReading.appPrefix(for: CallMatch.activeCall(CoreAudioProcessSource().processes(),
                                                                            runningApps: apps.get, ownPID: me))
        }
        let sampler = ScreenSampler(folder: folder, capturer: ScreenCaptureKitCapturer(), recognizer: VisionTextRecognizer(),
                                    appBundlePrefix: prefix, now: clock, options: options)
        self.sampler = sampler
        saves.started(options)
        task = Task { await sampler.run() }
        log.info("Screen reading started.")
    }

    /// Settings changed. Switching "Read my screen during calls" off stops a recording's reading at once and saves
    /// what it has (spec 9); Stop still waits for that save. So does switching off "Read the whole display" or "Keep
    /// screenshots" while the sampler uses it: its options are fixed at start, so it reads again at the next
    /// recording. Switching anything on takes effect at the next recording.
    func settingsChanged(from old: EarshotSettings, to new: EarshotSettings) {
        guard saves.stopsNow(from: old, to: new), let save = stopRunning() else { return }
        saves.stoppedMidCall(saving: save)
        if new.readScreen {
            log.info("Screen reading was narrowed during the recording; stopped it and saved what it had. It reads again at the next recording.")
        } else {
            log.info("Screen reading switched off during the recording; saved what it had.")
        }
    }

    /// Stops reading and saves screen.json. The returned task finishes once it is saved, including a save started
    /// when reading was stopped earlier in the recording.
    @discardableResult
    func stop() -> Task<Void, Never> {
        saves.takeForStop(running: stopRunning())
    }

    /// Stops the running sampler and starts its save; nil when none runs.
    private func stopRunning() -> Task<Void, Never>? {
        guard let sampler, let task else { return nil }
        stopSampling()
        let log = log
        return Task {
            if !(await TaskWait.finished(task, within: Self.stopWait)) {
                log.error("A screen sample didn't finish in time; saving the moments already kept.")
            }
            do {
                try await sampler.save()
            } catch {
                log.error("Couldn't save screen.json: \(error.localizedDescription, privacy: .public)")
            }
            if let problem = await sampler.lastError {
                log.error("Screen reading: \(problem, privacy: .public)")
            }
        }
    }

    private func stopSampling() {
        task?.cancel()
        task = nil
        sampler = nil
        pinned.update { $0 = nil }
        appObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        appObservers = []
    }

    /// Reads the running apps now and again each time an app launches or quits, until sampling stops.
    private func followRunningApps() {
        let apps = runningApps
        apps.update { $0 = CallController.runningApps() }
        let center = NSWorkspace.shared.notificationCenter
        appObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification]
            .map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { apps.update { $0 = CallController.runningApps() } }
                }
            }
    }
}
