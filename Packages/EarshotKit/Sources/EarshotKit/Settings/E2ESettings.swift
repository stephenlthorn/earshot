import Foundation

/// The settings the app's end-to-end harnesses run with (App/E2E.swift, Scripts/e2e.sh and Scripts/e2e-import.sh).
/// They live here, not in the App, so a test proves every switch. The app never saves them.
extension EarshotSettings {
    /// The notes model for `--e2e-import`: Sonnet, for speed.
    public static let e2eImportModel = "claude-sonnet-5-5"

    /// Claude Code notes and a command target that saves the payload in the meeting folder, sent without asking.
    /// `claudePath` is the user's Claude Code path override (a location, not a credential), so a Mac where `claude`
    /// is found only through it still works.
    public static func e2e(saveFolder: URL, claudePath: String) -> EarshotSettings {
        var settings = EarshotSettings()
        settings.saveFolder = saveFolder.path
        settings.claudePath = claudePath
        settings.provider = .claudeCode
        settings.userName = "Tester"
        settings.commandOn = true
        settings.command = #"cat > "$EARSHOT_SESSION_DIR/payload.json""#
        settings.sendWithoutAsking = true
        settings.consentReminder = false
        return settings
    }

    /// `e2e` with Sonnet notes in Notes + Do. Everything that could ask for a permission, register a global hotkey
    /// or read the user's own data (the live assistant and its panel, flags, the calendar, call noticing, the
    /// screen, lessons from edits) is off. With `local`, the notes come from that local model server instead
    /// (`--e2e-import ... --local <url> <model>`); nothing else changes.
    public static func e2eImport(saveFolder: URL, claudePath: String,
                                 local: (url: String, model: String)? = nil) -> EarshotSettings {
        var settings = e2e(saveFolder: saveFolder, claudePath: claudePath)
        if let local {
            settings.provider = .local
            settings.localURL = local.url
            settings.localModel = local.model
        }
        settings.model = e2eImportModel
        settings.claudeCodeModel = e2eImportModel
        settings.defaultMode = .notesAndDo
        settings.liveAssistant = false
        settings.showLivePanel = false
        settings.voiceFlags = false
        settings.flagHotkey = false
        settings.useCalendar = false
        settings.noticeCalls = false
        settings.autoRecordCalls = false
        settings.readScreen = false
        settings.keepScreenshots = false
        settings.learnFromEdits = false
        return settings
    }
}
