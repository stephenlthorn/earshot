import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Takes one screenshot of the call (spec 9). Tests use fakes; only the app uses `ScreenCaptureKitCapturer`.
public protocol ScreenCapturing: Sendable {
    /// One frame at most `maxWidth` pixels wide, or nil when there's nothing to capture.
    /// - Parameters:
    ///   - appBundlePrefix: the call app; its on-screen windows are captured, on the display that shows them. For a
    ///     browser only its frontmost window is captured.
    ///   - wholeDisplay: capture the main display instead, minus Earshot's own windows.
    func capture(appBundlePrefix: String?, wholeDisplay: Bool, maxWidth: Int) async throws -> CGImage?

    /// True when Screen Recording is allowed. Never prompts.
    func hasPermission() -> Bool
}

/// The real capturer, on ScreenCaptureKit. It never asks for permission itself: the app does that when the user turns
/// screen reading on.
public struct ScreenCaptureKitCapturer: ScreenCapturing {
    public init() {}

    public func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    public func capture(appBundlePrefix: String?, wholeDisplay: Bool, maxWidth: Int) async throws -> CGImage? {
        guard hasPermission(), maxWidth > 0, wholeDisplay || appBundlePrefix != nil else { return nil }
        // SCShareableContent and SCContentFilter aren't Sendable, so they stay inside this one call.
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let me = ProcessInfo.processInfo.processIdentifier
        let filter: SCContentFilter
        let source: CGRect
        if wholeDisplay {
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else { return nil }
            let own = Self.ownApplicationIndices(pids: content.applications.map(\.processID), me: me)
                .map { content.applications[$0] }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            source = CGRect(origin: .zero, size: display.frame.size)
        } else {
            guard let prefix = appBundlePrefix else { return nil }
            let windows = content.windows
            let infos = windows.map(Self.info)
            let browser = Self.isBrowser(Self.windowOwnerPrefix(prefix))
            guard let plan = Self.plan(windows: infos, displays: content.displays.map(\.frame), me: me, prefix: prefix,
                                       frontToBack: browser ? Self.frontToBackWindowIDs() : [])
            else { return nil }
            filter = SCContentFilter(display: content.displays[plan.display], including: plan.windows.map { windows[$0] })
            source = plan.source
        }
        let config = SCStreamConfiguration()
        let size = Self.outputSize(points: source.size, scale: CGFloat(filter.pointPixelScale), maxWidth: maxWidth)
        config.sourceRect = source
        config.width = size.width
        config.height = size.height
        config.scalesToFit = true
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Window ids on screen, front to back, from the window server. `SCShareableContent` has no documented order.
    static func frontToBackWindowIDs() -> [CGWindowID] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    static func info(_ window: SCWindow) -> WindowInfo {
        WindowInfo(id: window.windowID, pid: window.owningApplication?.processID,
                   bundleID: window.owningApplication?.bundleIdentifier ?? "", layer: window.windowLayer,
                   onScreen: window.isOnScreen, frame: window.frame)
    }

    // MARK: - Pure helpers (tested)

    /// A window as plain values, so the choice of windows can be tested without ScreenCaptureKit.
    struct WindowInfo: Equatable, Sendable {
        var id: CGWindowID
        /// Nil when no app owns the window.
        var pid: pid_t?
        var bundleID: String
        var layer: Int
        var onScreen: Bool
        var frame: CGRect
    }

    /// What to capture for a call app: the display (an index into the displays), the windows (indices into the
    /// windows) and the part of the display they cover, in display points.
    struct Plan: Equatable, Sendable {
        var display: Int
        var windows: [Int]
        var source: CGRect
    }

    /// Browsers from spec 7.1. A browser call captures only the browser's frontmost window, never its others (mail,
    /// banking or admin pages beside the call). Kept in step with call detection's browser list.
    static let browserPrefixes = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// The app that owns the windows for a prefix call detection reported. Safari's audio runs in WebKit helpers,
    /// which own no windows, so they map to Safari; a browser helper (`com.google.Chrome.helper`) maps to its
    /// browser; any other `.helper` id maps to the app before it.
    static func windowOwnerPrefix(_ prefix: String) -> String {
        let lower = prefix.lowercased()
        if lower.hasPrefix("com.apple.webkit") { return "com.apple.Safari" }
        if let browser = browserPrefixes.first(where: { lower.hasPrefix($0.lowercased()) }) { return browser }
        if let helper = lower.range(of: ".helper") { return String(prefix[..<helper.lowerBound]) }
        return prefix
    }

    static func isBrowser(_ prefix: String) -> Bool {
        browserPrefixes.contains { $0.caseInsensitiveCompare(prefix) == .orderedSame }
    }

    /// The windows to capture for the call app behind `prefix`: on-screen, normal-layer windows of that app, never
    /// Earshot's own (`me`); for a browser only its frontmost one by `frontToBack`, and nil when that order names none
    /// of them, so no other browser window is captured by mistake. Then the display showing most of them, and only
    /// those on it.
    static func plan(windows: [WindowInfo], displays: [CGRect], me: pid_t, prefix: String,
                     frontToBack: [CGWindowID]) -> Plan? {
        let owner = windowOwnerPrefix(prefix)
        var candidates = windows.indices.filter { index in
            let window = windows[index]
            guard let pid = window.pid, pid != me else { return false }
            return window.onScreen && window.layer == 0 && window.frame.width > 1 && window.frame.height > 1
                && matches(window.bundleID, prefix: owner)
        }
        if isBrowser(owner) {
            guard let front = frontToBack.lazy.compactMap({ id in candidates.first { windows[$0].id == id } }).first
            else { return nil }
            candidates = [front]
        }
        guard let display = bestIndex(showing: candidates.map { windows[$0].frame }, among: displays) else { return nil }
        let shown = candidates.filter { windows[$0].frame.intersects(displays[display]) }
        guard let bounds = union(shown.map { windows[$0].frame })?.intersection(displays[display]), !bounds.isEmpty
        else { return nil }
        let source = bounds.offsetBy(dx: -displays[display].minX, dy: -displays[display].minY)
        return Plan(display: display, windows: shown, source: source)
    }

    /// Indices of Earshot's own apps among `pids`, so whole-display capture leaves its windows out.
    static func ownApplicationIndices(pids: [pid_t], me: pid_t) -> [Int] {
        pids.indices.filter { pids[$0] == me }
    }

    /// True when `bundleID` is the prefix itself or starts with it (case-insensitive).
    static func matches(_ bundleID: String, prefix: String) -> Bool {
        !prefix.isEmpty && bundleID.lowercased().hasPrefix(prefix.lowercased())
    }

    /// The display that shows the largest area of `frames` (global coordinates).
    static func display(showing frames: [CGRect], among displays: [SCDisplay]) -> SCDisplay? {
        let best = bestIndex(showing: frames, among: displays.map(\.frame))
        return best.map { displays[$0] }
    }

    static func bestIndex(showing frames: [CGRect], among displays: [CGRect]) -> Int? {
        let areas = displays.map { display in
            frames.reduce(0.0) { total, frame in
                let shared = frame.intersection(display)
                return shared.isNull ? total : total + shared.width * shared.height
            }
        }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return nil }
        return best
    }

    static func union(_ frames: [CGRect]) -> CGRect? {
        frames.dropFirst().reduce(frames.first) { $0?.union($1) }
    }

    /// Pixel size for `points` at `scale`, shrunk to `maxWidth` wide with the aspect ratio kept.
    static func outputSize(points: CGSize, scale: CGFloat, maxWidth: Int) -> (width: Int, height: Int) {
        let width = max(1, points.width * max(scale, 1)), height = max(1, points.height * max(scale, 1))
        let shrink = min(1, CGFloat(maxWidth) / width)
        return (max(1, Int((width * shrink).rounded())), max(1, Int((height * shrink).rounded())))
    }
}
