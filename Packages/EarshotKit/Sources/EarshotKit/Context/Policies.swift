import Foundation

/// Whether the confirm window must open before anything is sent (spec 5.3).
public enum ConfirmPolicy {
    /// True unless the user chose to send without asking, and the meeting is not external and was not started
    /// automatically: those meetings' text comes from outside parties. A meeting `earshot process` made always asks:
    /// an agent chose its sends, and the app's targets (a shell command, say) are not the one it was given.
    public static func mustAsk(session: Session, settings: EarshotSettings) -> Bool {
        !settings.sendWithoutAsking || session.profile == .external || session.startedBy == .auto
            || session.startedBy == .cli
    }
}

/// The recording reminder (spec 7.4).
public enum ConsentPolicy {
    public static let screenSentence = "It also reads what's shared on screen."
    /// How long the banner stays for a recording started by hand.
    public static let bannerDuration: TimeInterval = 120

    public enum Delivery: Equatable, Sendable {
        /// The banner in the panel, with Copy line.
        case banner
        /// A notification, because the panel is hidden.
        case notification
    }

    /// The line to copy: the user's line (or the default when blank), plus the screen sentence when screen reading
    /// is on and the line doesn't already say it.
    public static func line(settings: EarshotSettings) -> String {
        let typed = settings.consentLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = typed.isEmpty ? EarshotSettings.defaultConsentLine : typed
        guard settings.readScreen, !base.contains(screenSentence) else { return base }
        return "\(base) \(screenSentence)"
    }

    /// How the reminder appears when a recording starts, or nil when the reminder is off.
    public static func delivery(settings: EarshotSettings, panelShown: Bool) -> Delivery? {
        guard settings.consentReminder else { return nil }
        return panelShown ? .banner : .notification
    }

    /// A recording started automatically keeps the banner until it is dismissed.
    public static func bannerPersists(startedBy: StartTrigger) -> Bool {
        startedBy == .auto
    }

    /// Whether the banner still shows: never once dismissed, always for an automatic start, otherwise for
    /// `bannerDuration` after it appeared.
    public static func bannerVisible(startedBy: StartTrigger, shownAt: Date, now: Date, dismissed: Bool) -> Bool {
        guard !dismissed else { return false }
        return bannerPersists(startedBy: startedBy) || now.timeIntervalSince(shownAt) < bannerDuration
    }
}
