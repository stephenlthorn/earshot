import EarshotKit
import Foundation

/// v2: the AppModel side of the live assistant. Everything else is in App/Live.
extension AppModel {
    func liveSettingsChanged(from old: EarshotSettings) {
        liveController.settingsChanged(from: old)
    }

    /// Do targets and live Start runs that quitting would cut off, for the quit warning.
    var quitBusyLabels: [String] {
        Array(Set(busyTargetLabels() + liveController.busyTargetLabels())).sorted()
    }

    /// The quit warning's text: meeting Do runs wait for Retry, live to-dos are marked Interrupted.
    var quitWarningText: String {
        LivePanelText.quitWarning(meeting: busyTargetLabels(), live: liveController.busyTargetLabels(),
                                  liveItems: liveController.busyItemCount())
    }
}
