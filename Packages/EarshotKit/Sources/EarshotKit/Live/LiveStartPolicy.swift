import Foundation

/// Which live target Start uses, and whether it starts in one click, after a sheet, or not at all (spec 4.1, 4.4 and
/// the decision that only contained targets get one-click Start).
public enum LiveStartPolicy {
    /// The kinds of Do target, by their ids.
    public enum TargetKind: String, CaseIterable, Sendable {
        case claudeCode = "claude-code"
        case webhook
        case command
        case routine

        public init?(id: String) { self.init(rawValue: id) }
    }

    public enum Decision: Equatable, Sendable {
        /// One click, then the "Starting… Cancel" window.
        case oneClick
        /// A sheet shows exactly what will be sent; a second click sends it.
        case confirmSheet
        /// Start is not offered; the reason says why.
        case unavailable(String)
    }

    /// How long "Starting… Cancel" is shown after a one-click Start.
    public static let cancelWindow: Duration = .seconds(3)
    /// Shown in place of Start when no live target works.
    public static let setUpTarget = "Set up a Do target"
    public static let routineNotAllowed = "Turn on Allow Start during calls in Settings to start routines from the panel."

    /// - Claude Code in restricted mode, and webhooks: one click.
    /// - Claude Code in any other mode (acceptEdits, auto, bypassPermissions): the sheet.
    /// - A command runs whatever the user set up, so it always gets the sheet.
    /// - A routine: one click, only when "Allow Start during calls" is on.
    public static func decide(target: TargetKind, permissionMode: String, allowRoutine: Bool) -> Decision {
        switch target {
        case .claudeCode: permissionMode == ClaudeCodeTarget.restricted ? .oneClick : .confirmSheet
        case .webhook: .oneClick
        case .command: .confirmSheet
        case .routine: allowRoutine ? .oneClick : .unavailable(routineNotAllowed)
        }
    }

    /// The target Start sends to, per `LiveTargetChoice`: the one chosen in Settings, or when none is chosen or the
    /// chosen one is off or can't run, the first that is switched on and can run (spec 4.4 as adopted).
    /// - Parameter targets: `EarshotSettings.targets(...)`, the targets that are switched on.
    public static func liveTarget(settings: EarshotSettings, targets: [any DoTarget]) -> (any DoTarget)? {
        LiveTargetChoice.make(settings: settings, targets: targets).target
    }

    /// The decision for the live target, or `.unavailable(setUpTarget)` when there is none Start can use.
    public static func decision(settings: EarshotSettings, targets: [any DoTarget]) -> Decision {
        LiveTargetChoice.make(settings: settings, targets: targets).decision
    }

    /// True when the panel shows Start: the live assistant is on, the meeting is Notes + Do, and the live target
    /// works.
    public static func startAvailable(mode: Mode, settings: EarshotSettings, targets: [any DoTarget]) -> Bool {
        guard settings.liveAssistant, mode == .notesAndDo else { return false }
        if case .unavailable = decision(settings: settings, targets: targets) { return false }
        return true
    }
}
