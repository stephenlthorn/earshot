import AppKit
import EarshotKit
import SwiftUI

// v2: screenshots. `--render-screenshots <dir>` draws the README images and quits before the app starts, so
// AppModel.shared never loads the user's settings or meetings. Otherwise the app runs as before.
@main
enum EarshotMain {
    @MainActor static func main() {
        if let status = Screenshots.runIfRequested(CommandLine.arguments) { exit(status) }
        EarshotApp.main()
    }
}

struct EarshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            MenuBarIcon(recording: model.isRecording, processing: model.isProcessing,
                        badge: model.calls.showsBadge)  // v2: a call question waits in the menu (B3)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Idle, recording (red) and processing. Menu bar images are drawn as templates (one colour), so the red one is a
/// non-template image. `badge` marks a call question waiting in the menu because notifications don't reach
/// the user; during a recording it is a dot on the red image.
struct MenuBarIcon: View {
    let recording: Bool
    let processing: Bool
    var badge = false

    var body: some View {
        if recording {
            Image(nsImage: badge ? Self.recordingBadgedImage : Self.recordingImage)
        } else if badge {
            Image(systemName: "waveform.badge.mic").accessibilityLabel("Earshot. A call question is waiting.")
        } else {
            Image(systemName: processing ? "waveform.circle" : "waveform")
                .accessibilityLabel(processing ? "Earshot, working" : "Earshot")
        }
    }

    static let recordingImage: NSImage = {
        let symbol = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
        let image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) ?? NSImage()
        image.isTemplate = false
        return image
    }()

    /// The recording image with a dot: a call question waits in the menu during a recording.
    static let recordingBadgedImage: NSImage = {
        let base = recordingImage
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let side = rect.width * 0.42
            let dot = NSBezierPath(ovalIn: NSRect(x: rect.maxX - side, y: rect.maxY - side, width: side, height: side))
            NSColor.systemOrange.setFill()
            dot.fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Recording. A call question is waiting."
        return image
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // v2: a non-actor delegate with the call and consent buttons (spec 17; NotificationRouter.swift, B3)
        NotificationRouter.install()
        AppModel.shared.launched()
        AppModel.shared.liveController.registerHotkeys()  // v2: ⌃⌥⌘F and ⌃⌥⌘H
    }

    /// A recording is stopped and saved first. If Claude Code or a command is still working on a meeting, the user
    /// is asked; quitting then stops it, and the meeting waits for Retry instead of running it again on its own.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.prepareToQuit() else { return .terminateCancel }
        // v2: live Start sends already going get a few seconds, so live.json records how they ended.
        let live = AppModel.shared.liveController
        guard live.hasLiveWork else { return .terminateNow }
        Task {
            await live.finishBeforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Plain AppKit windows for the confirm checklist and onboarding, so the pipeline can open them at any time.
@MainActor
final class WindowPresenter {
    private var windows: [String: NSWindow] = [:]
    private var observers: [String: any NSObjectProtocol] = [:]

    /// `size` makes the window resizable, opening at that content size; without it the window fits its content.
    func show(_ id: String, title: String, size: CGSize? = nil, onClose: (@MainActor () -> Void)? = nil,
              @ViewBuilder content: () -> some View) {
        let style: NSWindow.StyleMask = size == nil ? [.titled, .closable] : [.titled, .closable, .resizable]
        let window = windows[id] ?? NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
        window.title = title
        let host = NSHostingController(rootView: content())
        // A resizable window takes only its minimum size from the view, so the user's size isn't put back.
        if size != nil { host.sizingOptions = [.minSize] }
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        if windows[id] == nil {
            if let size { window.setContentSize(size) }
            window.center()
            windows[id] = window
            observers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.forget(id)
                    onClose?()
                }
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // v2: an open window comes to the front with its content kept (Ask keeps an unsaved Fix). False when not open.
    func bringToFront(_ id: String) -> Bool {
        guard let window = windows[id] else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return true
    }

    /// Closes without running onClose: for when the app itself is done with the window.
    func close(_ id: String) {
        let window = windows[id]
        forget(id)
        window?.close()
    }

    private func forget(_ id: String) {
        if let observer = observers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(observer) }
        windows.removeValue(forKey: id)
    }
}
