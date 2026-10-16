import AppKit
import EarshotKit
import SwiftUI

/// Earshot's accents: indigo for the brand, cyan for anything live.
enum Brand {
    static let indigo = Color(red: 0x4F / 255, green: 0x46 / 255, blue: 0xE5 / 255)
    static let cyan = Color(red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255)
    /// Brand and status colors for small text. Each passes 4.5:1 on the darkest background it is drawn on: a live row
    /// (the panel's windowBackgroundColor plus the row's Color.primary.opacity(0.035) fill), about #E4E4E4 in light
    /// mode and #393939 in dark mode. Plain .green and .orange are too light there. The words carry the meaning too.
    static let indigoText = dynamic(light: NSColor(red: 0.31, green: 0.27, blue: 0.90, alpha: 1),
                                    dark: NSColor(red: 0.65, green: 0.66, blue: 1.0, alpha: 1))
    static let cyanText = dynamic(light: NSColor(red: 0.0, green: 0.40, blue: 0.48, alpha: 1),
                                  dark: NSColor(red: 0.40, green: 0.87, blue: 0.95, alpha: 1))
    static let greenText = dynamic(light: NSColor(red: 0.05, green: 0.40, blue: 0.15, alpha: 1),
                                   dark: NSColor(red: 0.40, green: 0.85, blue: 0.50, alpha: 1))
    static let orangeText = dynamic(light: NSColor(red: 0.58, green: 0.28, blue: 0.0, alpha: 1),
                                    dark: NSColor(red: 1.0, green: 0.70, blue: 0.30, alpha: 1))
    static let redText = dynamic(light: NSColor(red: 0.75, green: 0.10, blue: 0.10, alpha: 1),
                                 dark: NSColor(red: 1.0, green: 0.55, blue: 0.52, alpha: 1))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// Everything the panel draws, as plain values, so the README screenshots can build it with sample data.
struct LivePanelState {
    enum Layout { case full, collapsed, sharing }
    enum StatusKind { case listening, reading, problem, off }

    var elapsed: TimeInterval
    var layout = Layout.full
    /// "Flagged at 12:31", for a few seconds after a flag.
    var flagNote: String?
    /// The consent banner's line, while it shows.
    var consentLine: String?
    var brief: MeetingBrief?
    var briefExpanded = true
    /// The live assistant runs for this recording: the to-dos, the status line and the ticker show.
    var showsLive = false
    /// The live assistant was switched off during this recording: the to-dos and the status line stay, the Live
    /// chip and the ticker go.
    var liveStopped = false
    var rows: [LiveRow] = []
    var status: String?
    var statusKind = StatusKind.listening
    var tickerMe = ""
    var tickerThem = ""
    var sheet: StartSheetModel?
    var hidesFromCapture = true
}

/// What the panel's controls do. Each defaults to nothing.
struct LivePanelActions {
    var flag: @MainActor () -> Void = {}
    var sharing: @MainActor () -> Void = {}
    var stop: @MainActor () -> Void = {}
    var collapse: @MainActor () -> Void = {}
    var copyConsent: @MainActor () -> Void = {}
    var dismissConsent: @MainActor () -> Void = {}
    var toggleBrief: @MainActor () -> Void = {}
    var start: @MainActor (String) -> Void = { _ in }
    var cancel: @MainActor (String) -> Void = { _ in }
    var dismiss: @MainActor (String) -> Void = { _ in }
    /// Chooses the Settings tab, brings Earshot forward, then runs the opener it is given (the view's `openSettings`).
    var setUp: @MainActor (_ tab: SettingsTab, _ open: @MainActor () -> Void) -> Void = { $1() }
    var open: @MainActor (String) -> Void = { _ in }
    var openRun: @MainActor (String) -> Void = { _ in }
    var hover: @MainActor (String?) -> Void = { _ in }
    var confirmSheet: @MainActor () -> Void = {}
    var cancelSheet: @MainActor () -> Void = {}
}

/// The live panel (spec 4.5). The root view takes plain values only.
struct LivePanelView: View {
    static let width: CGFloat = 340

    let state: LivePanelState
    var actions = LivePanelActions()

    init(state: LivePanelState, actions: LivePanelActions = LivePanelActions()) {
        self.state = state
        self.actions = actions
    }

    var body: some View {
        Group {
            if state.layout == .sharing {
                SharingPill(elapsed: state.elapsed, restore: actions.sharing)
            } else {
                card
            }
        }
        .frame(width: Self.width, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(state: state, actions: actions)
            if state.layout == .full {
                VStack(alignment: .leading, spacing: 10) {
                    if let note = state.flagNote { FlagNote(text: note) }
                    if let line = state.consentLine {
                        ConsentBanner(line: line, copy: actions.copyConsent, dismiss: actions.dismissConsent)
                    }
                    if let brief = state.brief {
                        BriefCard(brief: brief, expanded: state.briefExpanded, toggle: actions.toggleBrief)
                    }
                    if let sheet = state.sheet {
                        StartSheetView(model: sheet, send: actions.confirmSheet, cancel: actions.cancelSheet)
                    } else if state.showsLive {
                        LiveTodoList(rows: state.rows, actions: actions)
                    }
                    if state.showsLive {
                        StatusLine(text: state.status ?? LiveStatus.listening.line, kind: state.statusKind)
                        if !state.liveStopped { Ticker(me: state.tickerMe, them: state.tickerThem) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
        .background(PanelBackground())
    }
}

struct PanelBackground: View {
    var radius: CGFloat = 16

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
    }
}

/// Red dot, timer, Flag, Sharing, Stop and collapse.
struct PanelHeader: View {
    let state: LivePanelState
    let actions: LivePanelActions

    var body: some View {
        HStack(spacing: 6) {
            RecordingDot()
            Text(Self.clock(state.elapsed))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
            if state.showsLive, !state.liveStopped {
                Text("Live")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Brand.cyanText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Brand.cyan.opacity(0.16), in: Capsule())
            }
            Spacer(minLength: 4)
            HeaderButton(symbol: "flag.fill", label: "Flag",
                         help: "Flag this moment (\(LivePanelText.flagCombo))", action: actions.flag)
            HeaderButton(symbol: "eye.slash", label: "Sharing",
                         help: "Sharing: hide what's in the panel (\(LivePanelText.sharingCombo)). \(LivePanelText.hidingNote)",
                         action: actions.sharing)
            HeaderButton(symbol: "stop.fill", label: "Stop recording", help: "Stop recording", tint: .red,
                         action: actions.stop)
            HeaderButton(symbol: state.layout == .collapsed ? "chevron.down" : "chevron.up",
                         label: state.layout == .collapsed ? "Expand the panel" : "Collapse the panel",
                         help: state.layout == .collapsed ? "Expand" : "Collapse", action: actions.collapse)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// An icon-only button. `label` is what VoiceOver says; `help` is the tooltip, read as the hint when it says more.
struct HeaderButton: View {
    let symbol: String
    var label: String?
    let help: String
    var tint: Color = .secondary
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label ?? help)
        .accessibilityHint(label == nil || label == help ? "" : help)
    }
}

struct RecordingDot: View {
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 9, height: 9)
            .background(Circle().fill(Color.red.opacity(0.25)).frame(width: 16, height: 16))
            .frame(width: 16, height: 16)
            .accessibilityLabel("Recording")
    }
}

/// The content-free pill while sharing: nothing about the meeting shows.
struct SharingPill: View {
    let elapsed: TimeInterval
    let restore: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RecordingDot()
            Text(PanelHeader.clock(elapsed)).font(.callout.weight(.semibold)).monospacedDigit()
            Spacer(minLength: 0)
            HeaderButton(symbol: "eye", label: "Show the panel", help: "Show the panel (\(LivePanelText.sharingCombo))",
                         action: restore)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(width: 150)
        .background(PanelBackground(radius: 18))
        .gesture(WindowDragGesture())
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct FlagNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "flag.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(Brand.indigoText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Brand.indigo.opacity(0.12), in: Capsule())
    }
}
