import Foundation
import Security
import Testing
@testable import EarshotKit

struct FakeSecrets: SecretReading {
    var values: [KeychainStore.Item: String] = [:]
    func read(_ item: KeychainStore.Item) -> String? { values[item] }
}

/// Counts reads, to show when settings ask the Keychain.
final class SpySecrets: SecretReading, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func read(_ item: KeychainStore.Item) -> String? {
        lock.withLock { count += 1 }
        return nil
    }
}

/// A throwaway UserDefaults whose plist lives in a temp folder that is deleted when the body finishes. A named suite
/// would leave earshot-test-<uuid>.plist in ~/Library/Preferences: removePersistentDomain does not reliably clear it.
func withFreshDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
    let folder = FileManager.default.temporaryDirectory.appending(path: "earshot-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = folder.appending(path: "defaults").path
    let defaults = UserDefaults(suiteName: name)!
    defer {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: folder)
    }
    return try body(defaults)
}

struct SettingsTests {
    @Test func defaultsMatchTheSpec() throws {
        let s = try withFreshDefaults { EarshotSettings.load(from: $0, secrets: FakeSecrets()) }
        #expect(s.saveFolder.hasSuffix("/Documents/Earshot"))
        #expect(s.defaultMode == .notes && s.provider == .claudeCode && s.model == "claude-opus-5-5" && s.effort == "medium")
        #expect(s.consentReminder && !s.sendWithoutAsking && s.keepAudio && !s.echoCancellation)
        #expect(s.permissionMode == "restricted")
    }

    @Test func v2FieldsHaveTheSpecDefaults() {
        let s = EarshotSettings()
        #expect(!s.liveAssistant && s.liveInterval == 90 && s.liveModel == "claude-sonnet-5-5" && s.quickModel == "claude-sonnet-5-5")
        #expect(s.liveTarget == "" && !s.allowRoutineLiveStart && s.showLivePanel && s.hidePanelFromCapture)
        #expect(s.voiceFlags && s.flagHotkey)
        #expect(!s.useCalendar && s.myDomains == "" && s.externalMode == .notesAndDo && s.internalMode == .notes)
        #expect(s.salesKeywords == "demo, discovery, intro, proposal, pricing, sales, pitch, quote, consult")
        #expect(s.briefEnabled)
        #expect(!s.noticeCalls && !s.autoRecordCalls && s.autoStopCalls)
        #expect(!s.readScreen && !s.screenWholeDisplay && !s.keepScreenshots)
        #expect(s.learnFromEdits && !s.routineOn && s.routineURL == "" && s.onboardedVersion == 0)
        #expect(s.consentLine == "Quick heads-up: I'm recording this call so an AI assistant can transcribe it and take notes. I'll share the notes afterwards.")
        #expect(KeychainStore.Item.routineToken.rawValue == "routine-token")
    }

    @Test func aFreshInstallUsesClaudeCodeAndSavesIt() throws {
        try withFreshDefaults { defaults in
            let s = EarshotSettings.load(from: defaults, secrets: FakeSecrets())
            #expect(s.provider == .claudeCode && s.permissionMode == "restricted")
            #expect(defaults.data(forKey: EarshotSettings.defaultsKey) != nil)
            // A key added later doesn't switch the provider on its own.
            #expect(EarshotSettings.load(from: defaults, secrets: FakeSecrets(values: [.anthropicKey: "sk"])).provider == .claudeCode)
        }
    }

    @Test func aV1UserWithAnAPIKeyAndNoSavedSettingsKeepsTheAPI() throws {
        try withFreshDefaults { defaults in
            let s = EarshotSettings.load(from: defaults, secrets: FakeSecrets(values: [.anthropicKey: "sk-ant-api03-x"]))
            #expect(s.provider == .claudeAPI)
            #expect(EarshotSettings.load(from: defaults, secrets: FakeSecrets()).provider == .claudeAPI, "the migration is saved")
        }
        try withFreshDefaults { defaults in
            #expect(EarshotSettings.load(from: defaults, secrets: FakeSecrets(values: [.anthropicKey: "  "])).provider == .claudeCode)
        }
    }

    @Test func aSavedV1BlobLoadsUnchangedAndGainsTheNewDefaults() throws {
        // Every key v0.1 saved, as it saved them.
        let v1: [String: Any] = [
            "saveFolder": "/Users/alex/Documents/Earshot", "defaultMode": "notes_and_do", "userName": "Alex",
            "consentReminder": true, "echoCancellation": false, "launchAtLogin": false, "localeIdentifier": "en_US",
            "provider": "claude_api", "model": "claude-opus-5-5", "effort": "high", "claudePath": "", "claudeCodeModel": "",
            "style": "sales_call", "extraInstructions": "", "sendWithoutAsking": false, "claudeCodeTargetOn": true,
            "claudeCodeFolder": "/Users/alex/work", "permissionMode": "acceptEdits", "webhookOn": false, "webhookURL": "",
            "commandOn": false, "command": "", "keepAudio": true,
        ]
        let s = try withFreshDefaults { defaults in
            defaults.set(try JSONSerialization.data(withJSONObject: v1), forKey: EarshotSettings.defaultsKey)
            return EarshotSettings.load(from: defaults, secrets: FakeSecrets())
        }
        #expect(s.provider == .claudeAPI && s.permissionMode == "acceptEdits" && s.effort == "high")
        #expect(s.defaultMode == .notesAndDo && s.style == .salesCall && s.claudeCodeTargetOn && s.userName == "Alex")
        #expect(!s.liveAssistant && s.liveInterval == 90 && s.onboardedVersion == 0 && s.externalMode == .notesAndDo)
    }

    @Test func modelsAndEffortsFollowTheRole() {
        var s = EarshotSettings()
        s.model = "claude-opus-5-5"
        s.liveModel = "claude-haiku-5"
        s.quickModel = "claude-sonnet-5-5"
        #expect(ClaudeRole.allCases.map { s.model(for: $0) }
                == ["claude-opus-5-5", "claude-haiku-5", "claude-sonnet-5-5", "claude-sonnet-5-5", "claude-opus-5-5"])
        #expect(ClaudeRole.allCases.map { s.effort(for: $0) } == ["medium", "low", "low", "medium", "medium"])
        // A Claude Code model set in v1 still picks the notes model for that provider.
        s.claudeCodeModel = "opus"
        #expect(s.model(for: .notes) == "opus" && s.model(for: .fix) == "opus")
        s.provider = .claudeAPI
        #expect(s.model(for: .notes) == "claude-opus-5-5")
    }

    /// Decision (fix round 1): a v1 Claude Code user who left the Claude Code model blank got the CLI's own default.
    /// v2 follows spec 3.2 and 3.3 and always names the notes model, so after the upgrade they get `model`.
    @Test func aV1ClaudeCodeUserWithNoModelOfTheirOwnGetsTheNotesModel() throws {
        let v1: [String: Any] = ["provider": "claude_code", "model": "claude-opus-5-5", "claudeCodeModel": "", "effort": "medium"]
        let s = try withFreshDefaults { defaults in
            defaults.set(try JSONSerialization.data(withJSONObject: v1), forKey: EarshotSettings.defaultsKey)
            return EarshotSettings.load(from: defaults, secrets: FakeSecrets())
        }
        #expect(s.provider == .claudeCode && s.model(for: .notes) == "claude-opus-5-5")
        let request = ClaudeNotesWriter(client: codeClient(FakeRunner()), model: s.model(for: .notes),
                                        effort: s.effort(for: .notes)).request(for: sampleRequest)
        let arguments = ClaudeCodeClient.arguments(for: request, systemPromptFile: "/tmp/x/system.txt")
        #expect(arguments.suffix(4) == ["--model", "claude-opus-5-5", "--effort", "medium"])
    }

    @Test func theSecretsAreReadOnlyWhenNothingIsSaved() throws {
        try withFreshDefaults { defaults in
            let spy = SpySecrets()
            _ = EarshotSettings.load(from: defaults, secrets: spy)
            #expect(spy.reads == 1, "a first load asks the Keychain once")
            _ = EarshotSettings.load(from: defaults, secrets: spy)
            #expect(spy.reads == 1, "once settings are saved, a load never touches the Keychain")
        }
    }

    @Test func anyTargetOnCountsEverySwitch() {
        var s = EarshotSettings()
        #expect(!s.anyTargetOn)
        for flip in [\EarshotSettings.claudeCodeTargetOn, \.webhookOn, \.commandOn, \.routineOn] {
            var one = s
            one[keyPath: flip] = true
            #expect(one.anyTargetOn)
        }
        s.routineOn = false
        #expect(!s.anyTargetOn)
    }

    @Test func savedSettingsRoundTripAndMissingKeysKeepDefaults() throws {
        try withFreshDefaults { defaults in
            var s = EarshotSettings()
            s.userName = "Stephen"
            s.webhookOn = true
            s.save(to: defaults)
            #expect(EarshotSettings.load(from: defaults, secrets: FakeSecrets()) == s)
            defaults.set(try JSONSerialization.data(withJSONObject: ["userName": "Old version"]), forKey: EarshotSettings.defaultsKey)
            let old = EarshotSettings.load(from: defaults, secrets: FakeSecrets())
            #expect(old.userName == "Old version" && old.model == "claude-opus-5-5")
        }
    }

    @Test func oneUnreadableSettingDoesNotResetTheRest() throws {
        let saved: [String: Any] = ["userName": "Stephen", "defaultMode": "hologram", "provider": 42]
        let s = try withFreshDefaults { defaults in
            defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: EarshotSettings.defaultsKey)
            return EarshotSettings.load(from: defaults, secrets: FakeSecrets())
        }
        #expect(s.userName == "Stephen")
        #expect(s.defaultMode == .notes)
        #expect(s.provider == .claudeCode)
    }

    @Test func notesSetupProblem() {
        var s = EarshotSettings()
        s.provider = .claudeAPI
        #expect(s.notesSetupProblem(secrets: FakeSecrets(), locate: { _ in nil }) == NotesError.missingKey.errorDescription)
        #expect(s.notesSetupProblem(secrets: FakeSecrets(values: [.anthropicKey: "sk"]), locate: { _ in nil }) == nil)
        s.provider = .claudeCode
        #expect(s.notesSetupProblem(secrets: FakeSecrets(), locate: { _ in nil }) == NotesError.claudeNotFound.errorDescription)
        #expect(s.notesSetupProblem(secrets: FakeSecrets(), locate: { _ in "/bin/claude" }) == nil)
    }

    @Test func theClientFollowsTheProvider() throws {
        var s = EarshotSettings()
        s.provider = .claudeAPI
        #expect(try s.claudeClient(secrets: FakeSecrets(), locate: { _ in nil }) is ClaudeAPIClient)
        s.provider = .claudeCode
        #expect(throws: NotesError.claudeNotFound) { try s.claudeClient(secrets: FakeSecrets(), locate: { _ in nil }) }
        #expect(throws: NotesError.claudeNotFound) { try s.notesWriter(secrets: FakeSecrets(), locate: { _ in nil }) }
        let client = try #require(try s.claudeClient(secrets: FakeSecrets(values: [.anthropicKey: "sk"]),
                                                     locate: { _ in "/bin/claude" }) as? ClaudeCodeClient)
        // The subscription provider never hands Claude Code the API key.
        #expect(client.claudePath == "/bin/claude" && client.apiKey == nil)
        s.effort = "high"
        let writer = try #require(try s.notesWriter(secrets: FakeSecrets(), locate: { _ in "/bin/claude" }) as? ClaudeNotesWriter)
        #expect(writer.client is ClaudeCodeClient && writer.model == "claude-opus-5-5" && writer.effort == "high")
    }

    @Test func targetsAreBuiltOnlyWhenOnAndComplete() {
        var s = EarshotSettings()
        let claude: (String?) -> String? = { _ in "/bin/claude" }
        #expect(s.targets(secrets: FakeSecrets(), locate: claude).isEmpty)
        s.webhookOn = true
        s.webhookURL = "not a url"
        s.commandOn = true
        s.command = "  "
        // A webhook that is on but can't be used fails with the reason (WebhookURLPolicyTests); a blank command is off.
        #expect(s.targets(secrets: FakeSecrets(), locate: claude).map(\.id) == ["webhook"])
        #expect(s.doTargetLabels(locate: claude).isEmpty)
        s.webhookURL = "https://example.com/earshot"
        s.command = "cat > /tmp/x.json"
        s.claudeCodeTargetOn = true
        s.claudeCodeFolder = "/tmp"
        let ids = s.targets(secrets: FakeSecrets(), locate: claude).map(\.id)
        #expect(ids == ["claude-code", "webhook", "command"])
        #expect(s.doTargetLabels(locate: claude) == ["Claude Code", "Webhook", "Command"])
        #expect(s.doTargetProblems(locate: claude).isEmpty)
    }

    @Test func aClaudeCodeTargetThatCantRunFailsWithTheReason() async throws {
        var s = EarshotSettings()
        s.claudeCodeTargetOn = true
        let (payload, folder) = try samplePayload()
        let json = try payload.encoded()
        func sent(locate: (String?) -> String?, isFolder: (String) -> Bool) async -> (ids: [String], result: DispatchResult?) {
            let targets = s.targets(secrets: FakeSecrets(), locate: locate, isFolder: isFolder)
            return (targets.map(\.id), await targets.first?.send(payload, json: json, folder: folder))
        }
        let noFolder = await sent(locate: { _ in "/bin/claude" }, isFolder: { _ in true })
        #expect(noFolder.ids == ["claude-code"])
        #expect(noFolder.result == DispatchResult(ok: false, detail: "Choose a work folder for Claude Code in Settings, Do."))
        s.claudeCodeFolder = "/Volumes/Gone/work"
        let goneFolder = await sent(locate: { _ in "/bin/claude" }, isFolder: { _ in false })
        #expect(goneFolder.result == DispatchResult(ok: false, detail: "Choose a work folder for Claude Code in Settings, Do."))
        s.claudeCodeFolder = "/tmp"
        let noClaude = await sent(locate: { _ in nil }, isFolder: { _ in true })
        #expect(noClaude.result == DispatchResult(ok: false, detail: NotesError.claudeNotFound.errorDescription!))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "do-claude-code.log").path))
        // What the confirm window and Settings show: only what will run, and why the rest won't.
        #expect(s.doTargetLabels(locate: { _ in nil }, isFolder: { _ in true }).isEmpty)
        #expect(s.doTargetProblems(locate: { _ in nil }, isFolder: { _ in true }) == [NotesError.claudeNotFound.errorDescription!])
        #expect(s.doTargetLabels(locate: { _ in "/bin/claude" }, isFolder: { _ in true }) == ["Claude Code"])
    }

    @Test func aWorkFolderWithATildeIsInTheHomeFolder() throws {
        var s = EarshotSettings()
        s.claudeCodeTargetOn = true
        s.claudeCodeFolder = "~/Projects/inbox"
        let home = NSHomeDirectory()
        let target = try #require(s.targets(secrets: FakeSecrets(), locate: { _ in "/bin/claude" },
                                            isFolder: { $0 == home + "/Projects/inbox" }).first as? ClaudeCodeTarget)
        #expect(target.workingFolder.path == home + "/Projects/inbox")
    }

    @Test func aWebhookURLWithCredentialsIsNotUsed() {
        var s = EarshotSettings()
        s.webhookOn = true
        for url in ["https://user:pass@example.com/hook", "https://user@example.com/hook", "https://:pass@example.com/hook"] {
            s.webhookURL = url
            let targets = s.targets(secrets: FakeSecrets(), locate: { _ in nil })
            #expect((targets.first as? UnavailableTarget)?.reason == WebhookURLPolicy.credentials, "\(url)")
            #expect(!targets.contains { $0 is WebhookTarget }, "\(url)")
        }
        s.webhookURL = "https://example.com/hook"
        #expect(s.targets(secrets: FakeSecrets(), locate: { _ in nil }).map(\.id) == ["webhook"])
    }

    @Test func diskSpaceLevels() {
        #expect(DiskSpace.level(freeBytes: 10_000_000_000) == .ok)
        #expect(DiskSpace.level(freeBytes: 1_500_000_000) == .low)
        #expect(DiskSpace.level(freeBytes: 400_000_000) == .critical)
    }

    @Test func diskProbeIsTheFolderOrItsNearestExistingParent() {
        let exists: (String) -> Bool = { ["/", "/Volumes/Ext", "/Volumes/Ext/Meetings"].contains($0) }
        let probe = { DiskSpace.probe(for: URL(fileURLWithPath: $0), exists: exists).path }
        #expect(probe("/Volumes/Ext/Meetings") == "/Volumes/Ext/Meetings")
        #expect(probe("/Volumes/Ext/Meetings/2026/Q4") == "/Volumes/Ext/Meetings")
        #expect(probe("/Volumes/Ext/../Ext/New") == "/Volumes/Ext")
        #expect(probe("/Nowhere/at/all") == "/")
        #expect(DiskSpace.probe(for: URL(fileURLWithPath: "/a/b"), exists: { _ in false }).path == "/")
    }

    @Test func freeSpaceIsReadForASaveFolderThatDoesNotExistYet() {
        let root = tempDir()
        let missing = root.appending(path: "not/made/yet", directoryHint: .isDirectory)
        #expect(DiskSpace.probe(for: missing).standardizedFileURL.path == root.standardizedFileURL.path)
        #expect(DiskSpace.free(at: missing) == nil)
        #expect(DiskSpace.free(near: missing) != nil)
    }
}

/// The delete path against a stand-in for SecItemDelete, so none of this touches the real keychain.
struct KeychainDeleteTests {
    @Test func aFailedDeleteIsNotSwallowed() {
        let denied = KeychainStore(service: "unused") { _ in errSecInteractionNotAllowed }
        let failure = KeychainStore.KeychainError.status(errSecInteractionNotAllowed)
        #expect(throws: failure) { try denied.delete(.anthropicKey) }
        // Clearing a key in Settings goes through write(""): a failed delete must not look like a cleared key.
        #expect(throws: failure) { try denied.write("", for: .anthropicKey) }
        #expect(throws: failure) { try denied.write(" \n", for: .anthropicKey) }
    }

    @Test func nothingToDeleteIsNotAnError() throws {
        for status in [errSecSuccess, errSecItemNotFound] {
            let store = KeychainStore(service: "unused") { _ in status }
            try store.delete(.webhookToken)
            try store.write("", for: .webhookToken)
        }
    }
}

@Suite(.enabled(if: deviceTests, "touches the login keychain"))
struct KeychainTests {
    @Test func writesReadsAndDeletes() throws {
        // A unique throwaway service, so no existing keychain item is ever read or changed.
        let keychain = KeychainStore(service: "com.stephenthorn.earshot.tests-\(UUID().uuidString)")
        defer {
            try? keychain.delete(.webhookToken)
            try? keychain.delete(.anthropicKey)
        }
        #expect(keychain.read(.webhookToken) == nil)
        try keychain.write("first", for: .webhookToken)
        try keychain.write(" second \n", for: .webhookToken)
        #expect(keychain.read(.webhookToken) == "second")
        try keychain.write("", for: .webhookToken)
        #expect(keychain.read(.webhookToken) == nil)
        try keychain.write("", for: .webhookToken)  // clearing what is already gone is not an error
        try keychain.delete(.anthropicKey)
    }
}
