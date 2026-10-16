import Foundation
import Testing
@testable import EarshotKit

/// The settings the app's `--e2e` and `--e2e-import` harnesses run with (App/E2E.swift). They are never saved.
struct E2ESettingsTests {
    let folder = URL(fileURLWithPath: "/tmp/earshot-e2e/meetings")

    @Test func baseSendsThePayloadToTheMeetingFolderWithClaudeCode() {
        let settings = EarshotSettings.e2e(saveFolder: folder, claudePath: "")
        #expect(settings.saveFolder == folder.path)
        #expect(settings.provider == .claudeCode)
        #expect(settings.userName == "Tester")
        #expect(settings.commandOn)
        #expect(settings.command == #"cat > "$EARSHOT_SESSION_DIR/payload.json""#)
        #expect(settings.sendWithoutAsking)
        #expect(!settings.consentReminder)
    }

    @Test func importUsesSonnetAndNotesAndDo() {
        let settings = EarshotSettings.e2eImport(saveFolder: folder, claudePath: "")
        #expect(EarshotSettings.e2eImportModel == "claude-sonnet-5-5")
        #expect(settings.model == "claude-sonnet-5-5")
        #expect(settings.claudeCodeModel == "claude-sonnet-5-5")
        #expect(settings.defaultMode == .notesAndDo)
        #expect(settings.provider == .claudeCode)
        #expect(settings.commandOn && settings.sendWithoutAsking)
    }

    /// Nothing that could ask for a permission, register a global hotkey or read the user's own data stays on.
    @Test func importTurnsOffEveryPermissionAndHotkeySwitch() {
        let settings = EarshotSettings.e2eImport(saveFolder: folder, claudePath: "")
        #expect(!settings.liveAssistant)
        #expect(!settings.showLivePanel)
        #expect(!settings.voiceFlags)
        #expect(!settings.flagHotkey)
        #expect(!settings.useCalendar)
        #expect(!settings.noticeCalls)
        #expect(!settings.autoRecordCalls)
        #expect(!settings.readScreen)
        #expect(!settings.keepScreenshots)
        #expect(!settings.learnFromEdits)
        #expect(!settings.launchAtLogin)
    }

    /// Only the command target sends: no Claude Code target, webhook or routine gets the test meeting.
    @Test func importSendsOnlyToTheCommandTarget() {
        let settings = EarshotSettings.e2eImport(saveFolder: folder, claudePath: "")
        #expect(!settings.claudeCodeTargetOn)
        #expect(!settings.webhookOn)
        #expect(!settings.routineOn)
    }

    /// The user's Claude Code path override is a location, not a credential, and without it a Mac where `claude`
    /// is found only through the override would fail with "Claude Code not found".
    @Test func bothKeepTheClaudePathOverride() {
        let path = "/Users/someone/.local/bin/claude"
        #expect(EarshotSettings.e2e(saveFolder: folder, claudePath: path).claudePath == path)
        #expect(EarshotSettings.e2eImport(saveFolder: folder, claudePath: path).claudePath == path)
        #expect(EarshotSettings.e2eImport(saveFolder: folder, claudePath: "").claudePath == "")
    }
}

/// The harnesses' command lines, and where a run keeps its index and lessons: never the user's own.
struct E2ELaunchTests {
    let temp = URL(fileURLWithPath: "/tmp/earshot-e2e-data-T", isDirectory: true)
    let data = URL(fileURLWithPath: "/tmp/run/data", isDirectory: true)

    @Test func recordTakesItsDataFolder() throws {
        let launch = try #require(E2ELaunch.parse(["Earshot", "--e2e", "notes_and_do", "40", "/tmp/run/meetings",
                                                   "/tmp/run/data"], temporaryFolder: { temp }))
        #expect(launch == .record(mode: .notesAndDo, seconds: 40, meetings: URL(fileURLWithPath: "/tmp/run/meetings"),
                                  data: .inside(data)))
        #expect(launch.data.index == data.appending(path: "Index", directoryHint: .isDirectory))
        #expect(launch.data.lessons == data.appending(path: "lessons.json"))
    }

    @Test func importTakesItsDataFolder() throws {
        let launch = try #require(E2ELaunch.parse(["Earshot", "--e2e-import", "/tmp/a.m4a", "/tmp/run/meetings",
                                                   "/tmp/run/data"], temporaryFolder: { temp }))
        #expect(launch == .importAudio(audio: URL(fileURLWithPath: "/tmp/a.m4a"),
                                       meetings: URL(fileURLWithPath: "/tmp/run/meetings"), data: .inside(data)))
    }

    /// Without a data folder (or with a flag macOS added in its place) the run gets a temporary one.
    @Test func noDataFolderMeansATemporaryOneNeverTheUsers() throws {
        let plain = try #require(E2ELaunch.parse(["Earshot", "--e2e", "notes", "5", "/tmp/m"], temporaryFolder: { temp }))
        let flagged = try #require(E2ELaunch.parse(["Earshot", "--e2e-import", "/tmp/a.m4a", "/tmp/m",
                                                    "-NSDocumentRevisionsDebugMode"], temporaryFolder: { temp }))
        for launch in [plain, flagged] {
            #expect(launch.data == .inside(temp))
            #expect(launch.data.index != LibraryIndex.defaultURL && launch.data.lessons != LessonsStore.defaultURL)
        }
        let fresh = E2ELaunch.newTemporaryFolder()
        #expect(fresh.path.hasPrefix(FileManager.default.temporaryDirectory.path) && fresh != E2ELaunch.newTemporaryFolder())
    }

    @Test func otherCommandLinesAreNotAnE2ERun() {
        #expect(E2ELaunch.parse(["Earshot"]) == nil)
        #expect(E2ELaunch.parse(["Earshot", "--e2e", "loud", "5", "/tmp/m"]) == nil)
        #expect(E2ELaunch.parse(["Earshot", "--e2e", "notes", "soon", "/tmp/m"]) == nil)
        #expect(E2ELaunch.parse(["Earshot", "--e2e-import", "/tmp/a.m4a"]) == nil)
    }

    @Test func thePipelineWritesTheIndexAndReadsLessonsWhereItIsTold() {
        let config = EarshotSettings().pipelineConfig(at: .inside(data))
        #expect(config.index?.url == data.appending(path: "Index", directoryHint: .isDirectory))
        #expect(config.lessons?.url == data.appending(path: "lessons.json"))
        #expect(EarshotSettings().pipelineConfig.index?.url == DataLocations.standard.index)
    }
}
