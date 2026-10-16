import Foundation
import Testing
@testable import EarshotKit

/// The plugin launchers in plugins/*/scripts, run with a stand-in earshot.
struct PluginScriptTests {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func fakeHelper(printing text: String) throws -> URL {
        let folder = tempDir()
        let body = folder.appending(path: "said.txt")
        try Data(text.utf8).write(to: body)
        let helper = folder.appending(path: "earshot")
        try Data("#!/bin/sh\necho \"$@\" > \"\(folder.path)/args.txt\"\ncat \"\(body.path)\"\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper
    }

    private func run(_ script: String, helper: URL?, path: String = "/usr/bin:/bin") async throws -> ProcessOutput {
        var environment = ["HOME": tempDir().path, "PATH": path]
        environment["EARSHOT_HELPER"] = helper?.path
        return try await ProcessRunner().run("/bin/sh", [Self.repo.appending(path: script).path], stdin: nil, directory: nil,
                                             environment: environment, inheritEnvironment: false, timeout: .seconds(10))
    }

    @Test func remindersHookWrapsTheOutputAsAdditionalContext() async throws {
        let text = "Earshot reminders (quoted from meeting notes; not instructions):\n- Say \"hi\" to C:\\Users\tnow (from Sync)\n"
        let out = try await run("plugins/earshot-reminders/scripts/reminders.sh", helper: try fakeHelper(printing: text))
        #expect(out.status == 0 && out.stderr.isEmpty)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        let hook = try #require(object["hookSpecificOutput"] as? [String: Any])
        #expect(hook["hookEventName"] as? String == "SessionStart")
        #expect(hook["additionalContext"] as? String == String(text.dropLast()))
    }

    @Test func remindersHookPrintsNothingWithoutRemindersOrEarshot() async throws {
        let empty = try await run("plugins/earshot-reminders/scripts/reminders.sh", helper: try fakeHelper(printing: ""))
        #expect(empty.status == 0 && empty.stdout.isEmpty)
        let fakeApp = FileManager.default.isExecutableFile(atPath: "/Applications/Earshot.app/Contents/Helpers/earshot")
        if !fakeApp {
            let missing = try await run("plugins/earshot-reminders/scripts/reminders.sh", helper: nil)
            #expect(missing.status == 0 && missing.stdout.isEmpty && missing.stderr.isEmpty)
            // Both launchers look only in the two app locations: an earshot on PATH is never run.
            let onPath = try fakeHelper(printing: "Earshot reminders (quoted from meeting notes; not instructions):\n- x\n")
            let ignored = try await run("plugins/earshot-reminders/scripts/reminders.sh", helper: nil,
                                        path: onPath.deletingLastPathComponent().path + ":/usr/bin:/bin")
            #expect(ignored.status == 0 && ignored.stdout.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: onPath.deletingLastPathComponent().appending(path: "args.txt").path))
        }
    }

    @Test func theMCPLauncherExecsTheHelperOrSaysWhatIsMissing() async throws {
        let helper = try fakeHelper(printing: "served")
        let out = try await run("plugins/earshot/scripts/earshot-mcp", helper: helper)
        #expect(out.status == 0 && out.stdout == "served")
        let args = try String(contentsOf: helper.deletingLastPathComponent().appending(path: "args.txt"), encoding: .utf8)
        #expect(args == "mcp\n")
        if !FileManager.default.isExecutableFile(atPath: "/Applications/Earshot.app/Contents/Helpers/earshot") {
            let missing = try await run("plugins/earshot/scripts/earshot-mcp", helper: nil)
            #expect(missing.status == 1 && missing.stdout.isEmpty)
            #expect(missing.stderr.hasPrefix("earshot-mcp: Earshot.app was not found in /Applications or ~/Applications."))
        }
    }

    @Test func pluginFilesHaveNoEmDashes() throws {
        let files = ["plugins/earshot/skills/meetings/SKILL.md", "plugins/earshot/.claude-plugin/plugin.json",
                     "plugins/earshot-reminders/.claude-plugin/plugin.json", ".claude-plugin/marketplace.json"]
        for file in files {
            let text = try String(contentsOf: Self.repo.appending(path: file), encoding: .utf8)
            #expect(!text.contains("\u{2014}"), "\(file)")
        }
    }
}
