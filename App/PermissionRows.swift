import AppKit
import CoreGraphics
import EarshotKit
import SwiftUI
import UserNotifications

/// What onboarding and "New in v0.2" show for a permission the user turned down earlier. macOS doesn't ask twice, so
/// an Allow button would do nothing; the row sends the user to the right pane of System Settings instead.
enum PermissionText {
    static let deniedBefore = "Denied before. Open System Settings to turn it on."
    /// Screen Recording can't be read as denied, and a grant only shows after a relaunch, so this is true both ways.
    static let screenOff = "Screen Recording is off for Earshot. Turn it on in System Settings, then reopen Earshot."
    /// A profile (MDM or Screen Time) forbids calendar access; System Settings can't change it.
    static let calendarBlocked = "Calendar access is blocked on this Mac."
    static let openSettings = "Open System Settings"
}

extension AppModel {
    /// Set once Earshot has asked for Screen Recording. macOS shows its prompt only the first time, and there is no
    /// way to read "denied", so a later ask that finds no access counts as denied before.
    static let screenAccessAskedKey = "screenAccessAsked"

    var screenAccessAsked: Bool { UserDefaults.standard.bool(forKey: Self.screenAccessAskedKey) }

    /// Opens Earshot's page under System Settings, Notifications.
    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.stephenthorn.earshot"
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)"
        guard let url = URL(string: pane) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Notifications as onboarding shows them. Reading the status never prompts.
    static func notificationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// "Denied before. Open System Settings to turn it on." with the button that opens the pane. Without `open`, the
/// text alone (for a setting System Settings can't change).
struct DeniedBeforeRow: View {
    var text = PermissionText.deniedBefore
    let open: (@MainActor () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Caption(text, color: Brand.orangeText)
            Spacer()
            if let open { Button(PermissionText.openSettings, action: open).controlSize(.small) }
        }
    }
}

extension CalendarAuthorization {
    /// The user turned calendar access down, so asking again shows no prompt; System Settings can turn it on.
    var deniedBefore: Bool { self == .denied }
}
