import Foundation

/// Which Do target live Start uses (spec 4.4 as adopted). The target chosen in Settings when it is on and can run;
/// otherwise the first working target in the usual order, and Settings says so. With nothing chosen, the first
/// working target.
public struct LiveTargetChoice: Sendable {
    /// The target Start sends to; nil when no target can run.
    public let target: (any DoTarget)?
    /// A target is chosen in Settings, but it is off or can't run.
    public let chosenIsOff: Bool
    /// One click, the sheet, or why Start isn't offered.
    public let decision: LiveStartPolicy.Decision

    /// - Parameter targets: `EarshotSettings.targets(...)`, the targets that are switched on, in the usual order.
    public static func make(settings: EarshotSettings, targets: [any DoTarget]) -> LiveTargetChoice {
        let working = targets.filter { !($0 is UnavailableTarget) }
        let chosenID = settings.liveTarget.trimmingCharacters(in: .whitespaces)
        let chosen = chosenID.isEmpty ? nil : working.first { $0.id == chosenID }
        let target = chosen ?? working.first
        let decision: LiveStartPolicy.Decision
        if let target, let kind = LiveStartPolicy.TargetKind(id: target.id) {
            decision = LiveStartPolicy.decide(target: kind, permissionMode: settings.permissionMode,
                                              allowRoutine: settings.allowRoutineLiveStart)
        } else {
            decision = .unavailable(LiveStartPolicy.setUpTarget)
        }
        return LiveTargetChoice(target: target, chosenIsOff: !chosenID.isEmpty && chosen == nil, decision: decision)
    }

    /// For Settings, Live: what Start uses while the chosen target is off. Nil when the chosen target is used, when
    /// none is chosen, or when no other target can run (Start then says to set one up).
    public var settingsNote: String? {
        guard chosenIsOff, let target else { return nil }
        return Self.fallbackNote(target.label)
    }

    public static func fallbackNote(_ label: String) -> String {
        "The chosen target is off. Start uses \(label) for now."
    }
}
