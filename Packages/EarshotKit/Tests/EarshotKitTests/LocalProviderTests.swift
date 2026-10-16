import Foundation
import Testing
@testable import EarshotKit

/// The local model provider in Settings, the e2e harness and the live assistant.
struct LocalProviderSettingsTests {
    private func local(url: String = "http://localhost:11434/v1", model: String = "qwen3:8b") -> EarshotSettings {
        var settings = EarshotSettings()
        settings.provider = .local
        settings.localURL = url
        settings.localModel = model
        return settings
    }

    @Test func theProviderIsLastAndNamed() {
        #expect(NotesProvider.allCases.last == .local && NotesProvider.local.rawValue == "local")
        #expect(NotesProvider.local.label == "Local model (Ollama, LM Studio, llama.cpp)")
        #expect(EarshotSettings().localURL == "http://localhost:11434/v1" && EarshotSettings().localModel.isEmpty)
    }

    @Test func theProviderAddressAndModelRoundTrip() throws {
        try withFreshDefaults { defaults in
            let saved = local(url: "http://192.168.1.20:1234/v1", model: "qwen3-8b")
            saved.save(to: defaults)
            let loaded = EarshotSettings.load(from: defaults, secrets: FakeSecrets())
            #expect(loaded == saved && loaded.provider == .local && loaded.localURL == "http://192.168.1.20:1234/v1")
        }
    }

    /// Settings v0.2 saved, which has no local keys, load with the local defaults and nothing else changes.
    @Test func aV02BlobLoadsWithTheLocalDefaults() throws {
        var v02 = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(EarshotSettings())) as? [String: Any])
        v02["localURL"] = nil
        v02["localModel"] = nil
        v02["provider"] = "claude_api"
        v02["userName"] = "Alex"
        v02["liveModel"] = "claude-haiku-5"
        #expect(v02["localURL"] == nil && v02.count > 40, "every other key v0.2 saved")
        let s = try withFreshDefaults { defaults in
            defaults.set(try JSONSerialization.data(withJSONObject: v02), forKey: EarshotSettings.defaultsKey)
            return EarshotSettings.load(from: defaults, secrets: FakeSecrets())
        }
        #expect(s.localURL == LocalModelClient.defaultURL && s.localModel == "")
        #expect(s.provider == .claudeAPI && s.userName == "Alex" && s.liveModel == "claude-haiku-5")
    }

    @Test func theLocalModelDoesEveryRoleAndEffortIsUnchanged() {
        var s = local(model: "  qwen3:8b \n")
        s.claudeCodeModel = "opus"
        #expect(ClaudeRole.allCases.map { s.model(for: $0) } == Array(repeating: "qwen3:8b", count: ClaudeRole.allCases.count))
        #expect(ClaudeRole.allCases.map { s.effort(for: $0) } == ["medium", "low", "low", "medium", "medium"])
        s.provider = .claudeCode
        #expect(s.model(for: .notes) == "opus" && s.model(for: .live) == "claude-sonnet-5-5")
    }

    @Test func theSetupProblemIsTheAddressThenTheModel() {
        let none: (String?) -> String? = { _ in nil }
        #expect(local().notesSetupProblem(secrets: FakeSecrets(), locate: none) == nil)
        #expect(local(model: " ").notesSetupProblem(secrets: FakeSecrets(), locate: none) == LocalModelClient.pickModel)
        #expect(local(url: "", model: "").notesSetupProblem(secrets: FakeSecrets(), locate: none)
                == "Type the address of your local model server in Settings, Claude.")
        #expect(local(url: "http://example.com/v1").notesSetupProblem(secrets: FakeSecrets(), locate: none)
                == LocalModelClient.addressProblem("http://example.com/v1"))
        #expect(local(url: "localhost:11434").localSetupProblem == "The local model address must start with http:// or https://.")
    }

    @Test func theClientIsTheLocalOneOrSaysWhatToFix() throws {
        let client = try #require(try local(url: " http://127.0.0.1:18300/v1 ").claudeClient(secrets: FakeSecrets(), locate: { _ in nil })
                                  as? LocalModelClient)
        #expect(client.baseURL.absoluteString == "http://127.0.0.1:18300/v1")
        // The Keychain's API key is never handed over, and no `claude` is needed.
        #expect(try local().claudeClient(secrets: FakeSecrets(values: [.anthropicKey: "sk"]), locate: { _ in nil }) is LocalModelClient)
        #expect(throws: NotesError.local(LocalModelClient.pickModel)) {
            try local(model: "").claudeClient(secrets: FakeSecrets(), locate: { _ in "/bin/claude" })
        }
        #expect(throws: NotesError.local(LocalModelClient.plainHTTP)) {
            try local(url: "http://example.com/v1").claudeClient(secrets: FakeSecrets(), locate: { _ in nil })
        }
        let writer = try #require(try local().notesWriter(secrets: FakeSecrets(), locate: { _ in nil }) as? ClaudeNotesWriter)
        #expect(writer.client is LocalModelClient && writer.model == "qwen3:8b")
        #expect(NotesError.local("A whole sentence.").errorDescription == "A whole sentence.")
    }

    /// Many local servers run one request at a time. With one slot, a live pass during the notes is skipped instead of
    /// queueing on the server while its timer runs.
    @Test func theLocalServerTakesOneCallAtATime() async throws {
        let client = try local().localModelClient(session: StubHTTP.session)
        #expect(client.gate === LocalModelClient.serverGate)
        let live = LocalModelClient(baseURL: StubHTTP.url(path: "/v1", replies: [(200, chatReply(#"{"ok":true}"#))]),
                                    session: StubHTTP.session, gate: client.gate)
        let pass = ClaudeRequest(role: .live, system: "s", user: "u", schema: #"{"type":"object"}"#, model: "qwen3:8b",
                                 effort: "low", maxTokens: 100, timeout: .seconds(120))
        let held = try await client.gate.run(.notes, skipIfBusy: false) {
            await #expect(throws: ClaudeBusy.self) { try await live.structured(pass) }
            return true
        }
        #expect(held == true && StubHTTP.requests(live.baseURL).isEmpty)
    }
}

struct LocalProviderE2ETests {
    let folder = URL(fileURLWithPath: "/tmp/earshot-e2e/meetings")
    let temp = URL(fileURLWithPath: "/tmp/earshot-e2e-data-T", isDirectory: true)

    @Test func importParsesTheLocalServer() throws {
        let launch = try #require(E2ELaunch.parse(["Earshot", "--e2e-import", "/tmp/a.m4a", "/tmp/m", "/tmp/d",
                                                   "--local", "http://127.0.0.1:18300/v1", "qwen3-8b"], temporaryFolder: { temp }))
        #expect(launch == .importAudio(audio: URL(fileURLWithPath: "/tmp/a.m4a"), meetings: URL(fileURLWithPath: "/tmp/m"),
                                       data: .inside(URL(fileURLWithPath: "/tmp/d", isDirectory: true)),
                                       local: E2ELaunch.LocalModel(url: "http://127.0.0.1:18300/v1", model: "qwen3-8b")))
        let noData = try #require(E2ELaunch.parse(["Earshot", "--e2e-import", "/tmp/a.m4a", "/tmp/m", "--local", "http://h/v1", "m"],
                                                  temporaryFolder: { temp }))
        #expect(noData == .importAudio(audio: URL(fileURLWithPath: "/tmp/a.m4a"), meetings: URL(fileURLWithPath: "/tmp/m"),
                                       data: .inside(temp), local: E2ELaunch.LocalModel(url: "http://h/v1", model: "m")))
        let claude = try #require(E2ELaunch.parse(["Earshot", "--e2e-import", "/tmp/a.m4a", "/tmp/m"], temporaryFolder: { temp }))
        #expect(claude == .importAudio(audio: URL(fileURLWithPath: "/tmp/a.m4a"), meetings: URL(fileURLWithPath: "/tmp/m"),
                                       data: .inside(temp), local: nil))
    }

    @Test func halfALocalServerIsRejected() {
        let base = ["Earshot", "--e2e-import", "/tmp/a.m4a", "/tmp/m", "/tmp/d", "--local"]
        for tail in [[], ["http://h/v1"], ["http://h/v1", ""], ["http://h/v1", "-NSDocumentRevisionsDebugMode"], ["", "m"]] {
            #expect(E2ELaunch.parse(base + tail) == nil, "\(tail)")
        }
    }

    /// With a local server, exactly the provider, address and model differ from the Claude Code import.
    @Test func importWithALocalServerChangesOnlyTheProvider() {
        let plain = EarshotSettings.e2eImport(saveFolder: folder, claudePath: "/x/claude")
        let local = EarshotSettings.e2eImport(saveFolder: folder, claudePath: "/x/claude",
                                              local: (url: "http://127.0.0.1:18300/v1", model: "qwen3-8b"))
        #expect(local.provider == .local && local.localURL == "http://127.0.0.1:18300/v1" && local.localModel == "qwen3-8b")
        var expected = plain
        expected.provider = .local
        expected.localURL = "http://127.0.0.1:18300/v1"
        expected.localModel = "qwen3-8b"
        #expect(local == expected)
        #expect(EarshotSettings.e2eImport(saveFolder: folder, claudePath: "/x/claude", local: nil) == plain)
        #expect(local.notesSetupProblem(secrets: FakeSecrets(), locate: { _ in nil }) == nil)
    }
}

/// A client that always fails with one error.
private struct FailingClient: ClaudeClient {
    let error: NotesError
    let calls = Locked(0)
    func structured(_ request: ClaudeRequest) async throws -> Data {
        calls.update { $0 += 1 }
        throw error
    }
}

struct LocalProviderLiveTests {
    /// The server may be started mid-call, so a local problem fails the pass and the next one tries again.
    @Test func aLocalProblemFailsThePassInsteadOfPausing() async {
        let error = NotesError.local(LocalModelClient.unreachable("http://localhost:11434/v1"))
        #expect(LiveExtractor.setupPause(error) == nil)
        let client = FailingClient(error: error)
        let finals = Locked<[Segment]>([])
        let statuses = Locked<[LiveStatus]>([])
        let extractor = LiveExtractor(client: client, model: "qwen3:8b", effort: "low", interval: .seconds(90),
                                      finals: { finals.get }, finalize: {}, now: { 100 },
                                      context: { LivePrompt.Meeting(title: "Sync", userName: "Stephen", attendees: []) },
                                      onItems: { _ in }, onStatus: { status in statuses.update { $0.append(status) } },
                                      sleep: { _ in })
        let text = String(repeating: "Dana will send the pilot scope to the team by Friday afternoon. ", count: 4)
        finals.update { $0 = [Segment(track: .them, start: 10, end: 20, text: text)] }
        #expect(await extractor.passNow() == .failed(error.localizedDescription))
        finals.update { $0.append(Segment(track: .them, start: 30, end: 40, text: text)) }
        #expect(await extractor.passNow() == .failed(error.localizedDescription))
        #expect(client.calls.get == 2, "every later pass tries again")
        #expect(statuses.get.last == .failed(error.localizedDescription))
    }
}
