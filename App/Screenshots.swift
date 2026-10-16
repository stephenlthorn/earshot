import AppKit
import EarshotKit
import SwiftUI

/// `Earshot --render-screenshots <dir>` (spec 19): draws the README screenshots from the app's real views with the
/// sample meeting in EarshotKit `ScreenshotSamples`, in light and dark at 2x, plus the twelve live panel frames for
/// the GIF and the sample notes page as HTML. Scripts/screenshots.sh drives it.
///
/// Nothing asks for a permission and nothing is saved: the model runs over sample settings, the sample meetings live
/// in a scratch folder that is removed at the end, and the user's settings, meetings, index and Keychain are never
/// read. The windows are offscreen non-activating panels, made key so controls draw in their active colours; they
/// drop every key and mouse event, so typing elsewhere while they render can't press a button in them.
@MainActor
enum Screenshots {
    static let frameDirectory = "gif"

    /// Nil when the flag isn't given; otherwise the exit status once everything is written. It runs before
    /// `EarshotApp` exists, so `AppModel.shared` never loads the user's settings.
    static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard let request = ScreenshotRun.request(in: arguments) else { return nil }
        guard case let .render(out) = request else {
            FileHandle.standardError.write(Data("Usage: Earshot \(ScreenshotRun.flag) <folder>\n".utf8))
            return 64
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        do {
            let written = try render(into: out)
            written.forEach { print($0.path) }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Earshot couldn't render the screenshots: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func render(into out: URL) throws -> [URL] {
        // Inside `out`, so the script's cleanup removes it too if this process is stopped before its defer runs.
        let scratch = ScreenshotRun.scratchFolder(in: out)
        try? FileManager.default.removeItem(at: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: out.appending(path: frameDirectory), withIntermediateDirectories: true)
        let scene = try SampleScene(scratch: scratch)
        defer { scene.finish() }
        var written: [URL] = []
        let page = ScreenshotSamples.notesPageHTML()
        func save(_ data: Data, _ name: String) throws {
            let url = out.appending(path: name)
            try data.write(to: url, options: .atomic)
            written.append(url)
        }
        for dark in [false, true] {
            let look = dark ? "dark" : "light"
            for shot in scene.shots {
                try save(Snapshot.png(shot.view, dark: dark, chrome: shot.chrome, size: shot.size), "\(shot.name)-\(look).png")
            }
            try save(Data(ScreenshotSamples.pinColorScheme(page, dark: dark).utf8), "notes-page-\(look).html")
        }
        try save(Data(ScreenshotRun.measuringCopy(ScreenshotSamples.pinColorScheme(page, dark: false)).utf8),
                 "notes-page-measure.html")
        for (number, view) in scene.gifFrames().enumerated() {
            try save(Snapshot.png(view, dark: false, chrome: .bare), String(format: "\(frameDirectory)/frame-%02d.png", number + 1))
        }
        return written
    }
}

/// The sample model and the views to draw.
@MainActor
struct SampleScene {
    struct Shot {
        let name: String
        let chrome: Snapshot.Chrome
        var size: CGSize?
        let view: AnyView
    }

    /// The real time, for the menu only: its "Now:" line and recent meetings are read against the system clock.
    /// It shows no dates. The live panel and the notes page use the fixed `ScreenshotSamples.now`.
    let now = Date()
    let model: AppModel
    let shots: [Shot]

    struct MicrophoneDenied: LocalizedError {
        var errorDescription: String? {
            "the microphone is denied for Earshot on this Mac, so the menu would draw \"Grant microphone access\". "
                + "Allow it in System Settings, or render on another Mac."
        }
    }

    init(scratch: URL) throws {
        let meetings = scratch.appending(path: "meetings", directoryHint: .isDirectory)
        let work = scratch.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let settings = ScreenshotSamples.settings(saveFolder: meetings.path, workFolder: work.path)
        let model = AppModel(sample: settings)
        let recent = try ScreenshotSamples.writeRecentMeetings(to: model.store, now: now)
        if let busy = recent.writingNotes { model.activity[busy] = .notes }
        // The calendar is never read: showSample makes the controller sample-only (no read, no poll), and it is never
        // attached to the model (only AppModel.startWatchers attaches it, and the sample model never starts them).
        model.context.showSample(ScreenshotSamples.event(now: now), settings: settings, now: now)
        model.mode = .notesAndDo
        // Reads this Mac's microphone status, never asks. The menu draws it, so a denied mic would be in the image.
        model.refresh()
        guard !model.micDenied else { throw MicrophoneDenied() }
        ClaudeStatusChecker.shared.showSample(ClaudeCodeStatus(state: .ready, path: settings.claudePath,
                                                               version: "2.1.300", subscription: "max"))
        if let session = recent.sessions.first { Self.askToConfirm(session, model: model) }
        self.model = model
        // Settings > Claude with a local model: its own sample model (the menu's keeps Claude Code), and a sample
        // status that also stops the checker, so no server is ever contacted.
        let local = AppModel(sample: ScreenshotSamples.localSettings(saveFolder: meetings.path, workFolder: work.path))
        LocalModelChecker.shared.showSample(ScreenshotSamples.localStatus)
        let app = AIAppsSetup(appURL: URL(fileURLWithPath: "/Applications/Earshot.app", isDirectory: true))
        let last = ScreenshotSamples.panelFrames[ScreenshotSamples.panelFrames.count - 1]
        shots = [
            Shot(name: "menu", chrome: .floating(radius: MenuBackground.radius),
                 view: AnyView(MenuPanel(model: model).background(MenuBackground()))),
            Shot(name: "live-panel", chrome: .floating(radius: 16), view: AnyView(LivePanelView(state: Self.panel(last, now: ScreenshotSamples.now)))),
            Shot(name: "confirm", chrome: .window("Send action items"),
                 view: AnyView(ConfirmView(model: model, sample: ScreenshotSamples.confirmDraft()))),
            Shot(name: "settings-claude", chrome: .window("Claude"), size: CGSize(width: 600, height: 424),
                 view: AnyView(ClaudeTab(model: model))),
            Shot(name: "settings-local", chrome: .window("Claude"), size: CGSize(width: 600, height: 424),
                 view: AnyView(ClaudeTab(model: local))),
            Shot(name: "settings-live", chrome: .window("Live"), size: CGSize(width: 600, height: 716),
                 view: AnyView(LiveTab(model: model))),
            Shot(name: "settings-ai-apps", chrome: .window("AI apps"), size: CGSize(width: 600, height: 744),
                 view: AnyView(AIAppsTab(model: model, setup: app, helperExists: { _ in true }))),
            Shot(name: "onboarding", chrome: .window("Set up Earshot"), view: AnyView(OnboardingView(model: model))),
        ]
    }

    /// The live panel filling up, all at the height of the fullest frame so the GIF doesn't jump.
    func gifFrames() -> [AnyView] {
        let states = ScreenshotSamples.panelFrames.map { Self.panel($0, now: ScreenshotSamples.now) }
        let height = states.map { NSHostingView(rootView: LivePanelView(state: $0)).fittingSize.height }.max() ?? 400
        return states.map { state in
            AnyView(LivePanelView(state: state)
                .background(WindowShadow(radius: 16))
                .frame(height: height, alignment: .top)
                .padding(28)
                .background(LinearGradient(colors: [Color(white: 0.95), Color(red: 0.89, green: 0.90, blue: 0.95)],
                                           startPoint: .top, endPoint: .bottom)))
        }
    }

    /// Answers the confirm request the window shows, so nothing waits on it.
    func finish() {
        while !model.pendingConfirms.isEmpty { model.pendingConfirms.removeFirst().reply.resume(returning: nil) }
    }

    static func panel(_ frame: ScreenshotSamples.PanelFrame, now: Date) -> LivePanelState {
        var state = LivePanelState(elapsed: frame.elapsed)
        state.brief = ScreenshotSamples.brief
        state.showsLive = true
        state.rows = frame.rows(now: now)
        state.status = frame.statusLine
        state.statusKind = frame.isReading ? .reading : .listening
        state.tickerThem = frame.tickerThem
        state.tickerMe = frame.tickerMe
        return state
    }

    /// Puts a confirm request in the queue the way the pipeline does, without opening its window.
    static func askToConfirm(_ session: Session, model: AppModel) {
        let request = ConfirmRequest(session: session, notes: ScreenshotSamples.notes, live: ScreenshotSamples.confirmLive,
                                     only: nil, targets: ["Claude Code"], problems: [])
        Task { _ = await withCheckedContinuation { model.pendingConfirms.append((request, $0)) } }
        let deadline = Date().addingTimeInterval(2)
        while model.pendingConfirms.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}

/// The menu bar window's background: MenuBarExtra draws one round the panel, which a hosted view doesn't get.
struct MenuBackground: View {
    static let radius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

/// The shadow a floating window casts, drawn by a shape of the window's size behind it. A shadow on the view itself
/// would also fall from every text and control inside it.
struct WindowShadow: View {
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor))
            .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
    }
}

/// Draws a view to PNG at 2x in an offscreen window (research: ImageRenderer leaves AppKit controls as placeholders).
@MainActor
enum Snapshot {
    enum Chrome {
        /// A borderless, see-through window with a soft shadow, its corners this round: the menu and the live panel.
        case floating(radius: CGFloat)
        /// The view alone, edge to edge.
        case bare
        /// A titled window with this title, title bar included.
        case window(String)

        var title: String? {
            if case let .window(title) = self { return title }
            return nil
        }
    }

    struct Failed: LocalizedError {
        var errorDescription: String? { "a view drew nothing" }
    }

    static let scale: CGFloat = 2

    static func png(_ view: AnyView, dark: Bool, chrome: Chrome, size: CGSize? = nil) throws -> Data {
        let content: AnyView
        var style: NSWindow.StyleMask = [.nonactivatingPanel]
        switch chrome {
        case let .floating(radius):
            content = AnyView(view.background(WindowShadow(radius: radius)).padding(24))
            style.insert(.borderless)
        case .bare:
            content = view
            style.insert(.borderless)
        case .window:
            content = view
            style.formUnion([.titled, .closable, .miniaturizable])
        }
        let host = NSHostingView(rootView: content.frame(width: size?.width, height: size?.height)
            .environment(\.controlActiveState, .key).environment(\.appearsActive, true))
        let window = OffscreenPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: style,
                                    backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = window.appearance
        if let title = chrome.title {
            window.title = title
        } else {
            window.backgroundColor = .clear
            window.isOpaque = false
        }
        window.contentView = host
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        window.makeKey()
        window.makeMain()
        window.makeFirstResponder(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        settle(0.4)
        window.setContentSize(host.fittingSize)
        settle(0.2)
        // A titled window is drawn from its frame view, so the title bar is in the picture.
        let target = chrome.title == nil ? host : host.superview ?? host
        target.layoutSubtreeIfNeeded()
        return try draw(target)
    }

    /// Lets SwiftUI run onAppear and tasks, and lay out again.
    static func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func draw(_ view: NSView) throws -> Data {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale),
                                         pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { throw Failed() }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw Failed() }
        return data
    }
}

/// Offscreen and key without activating Earshot, so controls draw as in a focused window. It is never on a display.
/// A key non-activating panel gets the keys typed in whatever app is in front, so it drops every key and mouse
/// event: Return can't press a default button (Onboarding's Done saves to UserDefaults) and Space can't press a
/// focused Record or permission button.
final class OffscreenPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        if Self.dropped.contains(event.type) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }

    static let dropped: Set<NSEvent.EventType> = [
        .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
        .mouseMoved, .mouseEntered, .mouseExited, .magnify, .rotate, .swipe, .smartMagnify, .pressure,
    ]
}
