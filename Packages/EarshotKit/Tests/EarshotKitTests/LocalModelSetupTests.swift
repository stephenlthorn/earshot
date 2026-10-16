import Foundation
import Testing
@testable import EarshotKit

/// What Settings, onboarding, the menu and the live panel say and do with the local model provider.
struct LocalModelSetupTests {
    @Test func theModelsLineNamesTheLocalModel() {
        #expect(LocalModelSetup.modelsLine(" qwen3:8b ") == "Notes, live to-dos, the brief, Ask and Fix all use qwen3:8b.")
        #expect(LocalModelSetup.modelsLine("  ") == "Notes, live to-dos, the brief, Ask and Fix all use the local model you pick above.")
    }

    @Test func theCaptionsReadAsWritten() {
        #expect(LocalModelSetup.serversCaption == "Works with Ollama, LM Studio, llama.cpp and other OpenAI-compatible "
            + "servers. When the server runs on this Mac, your meetings never leave it.")
        #expect(LocalModelSetup.doCaption == "The Claude Code Do target still needs Claude Code.")
        #expect(LocalModelSetup.liveIntervalHint == "Local models can be slow; 120 seconds or more between passes works better.")
        #expect(LocalModelSetup.guideURL.absoluteString
            == "https://github.com/stephenlthorn/earshot/blob/main/docs/local-models.md")
    }

    @Test func noLineHasAnEmDash() {
        let lines = [LocalModelSetup.serversCaption, LocalModelSetup.doCaption, LocalModelSetup.liveCaption,
                     LocalModelSetup.liveIntervalHint, LocalModelSetup.modelsLine("m"), LocalModelSetup.modelsLine(""),
                     LocalModelSetup.notSetUp, LiveStatus.failed("x").line(provider: .local)]
        #expect(lines.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("\u{2013}") })
    }

    @Test func thePickerOffersWhatTheServerListsPlusTheTypedName() {
        let listed = ["gemma3:12b", "qwen3:8b"]
        #expect(LocalModelSetup.modelOptions(listed: listed, current: "qwen3:8b") == listed)
        #expect(LocalModelSetup.modelOptions(listed: listed, current: "") == listed)
        #expect(LocalModelSetup.modelOptions(listed: listed, current: "   ") == listed)
        // A name the server doesn't list (yet) stays selectable, so the picker never shows an invalid choice.
        #expect(LocalModelSetup.modelOptions(listed: listed, current: "llama3.1:8b") == listed + ["llama3.1:8b"])
        #expect(LocalModelSetup.modelOptions(listed: [], current: "qwen3:8b") == ["qwen3:8b"])
    }

    @Test func aCheckWaitsOnlyWhileTheAddressOrModelIsBeingTyped() {
        let last = LocalModelStatus(state: .ready, address: "http://localhost:11434/v1", model: "qwen3:8b",
                                    models: ["qwen3:8b"], problem: nil)
        #expect(LocalModelSetup.checkDelay(last: nil, address: "http://localhost:11434/v1", model: "qwen3:8b") == .zero)
        #expect(LocalModelSetup.checkDelay(last: last, address: " http://localhost:11434/v1 ", model: "qwen3:8b") == .zero)
        #expect(LocalModelSetup.checkDelay(last: last, address: "http://localhost:1234/v1", model: "qwen3:8b")
            == .milliseconds(600))
        #expect(LocalModelSetup.checkDelay(last: last, address: "http://localhost:11434/v1", model: "qwen3")
            == .milliseconds(600))
    }

    /// Onboarding and What's New check again when they appear unless the last status is ready for the address and
    /// model in Settings, so a stale "Can't reach" never stays.
    @Test func theSetupRowChecksAgainUnlessTheLastStatusIsReadyForTheseSettings() {
        let address = "http://localhost:11434/v1"
        func status(_ state: LocalModelStatus.State, model: String = "qwen3:8b") -> LocalModelStatus {
            LocalModelStatus(state: state, address: address, model: model, models: ["qwen3:8b"], problem: nil)
        }
        #expect(LocalModelSetup.checksOnAppear(last: nil, address: address, model: "qwen3:8b"))
        #expect(!LocalModelSetup.checksOnAppear(last: status(.ready), address: " \(address) ", model: "qwen3:8b"))
        for state in [LocalModelStatus.State.unreachable, .failed, .modelMissing, .noModelChosen, .badAddress] {
            #expect(LocalModelSetup.checksOnAppear(last: status(state), address: address, model: "qwen3:8b"), "\(state)")
        }
        #expect(LocalModelSetup.checksOnAppear(last: status(.ready), address: "http://localhost:1234/v1", model: "qwen3:8b"))
        #expect(LocalModelSetup.checksOnAppear(last: status(.ready), address: address, model: "gemma3:12b"))
    }

    /// Ask and the brief read the answer through `ClaudeClient.decode`: a local model's answer in the wrong shape
    /// says "The model", never Claude.
    @Test func aLocalAnswerInTheWrongShapeNeverNamesClaude() async throws {
        func local() -> LocalModelClient {
            LocalModelClient(baseURL: StubHTTP.url(path: "/v1", replies: [(200, chatReply(#"{"fine":1}"#))]),
                             session: StubHTTP.session, gate: ClaudeGate(), sleep: { _ in })
        }
        let expected = "The model's answer came back in the wrong shape: it did not match the expected format"
        do {
            _ = try await MeetingQA(client: local(), model: "qwen3:8b")
                .ask(question: "Who owns the budget?", notes: nil, transcript: [])
            Issue.record("Ask read an answer in the wrong shape")
        } catch {
            #expect(error.localizedDescription == expected)
            #expect(!error.localizedDescription.contains("Claude"))
        }
        do {
            _ = try await BriefWriter(client: local(), model: "qwen3:8b")
                .write(event: nil, title: "Acme sync", history: [], now: Date())
            Issue.record("The brief read an answer in the wrong shape")
        } catch {
            #expect(error.localizedDescription == expected)
            #expect(!error.localizedDescription.contains("Claude"))
        }
    }

    /// The Record and Import banner offers "Set up notes" for every setup problem any provider can have.
    @Test func everySetupProblemGetsTheSetUpLink() {
        var settings = EarshotSettings()
        settings.provider = .claudeAPI
        let missingKey = settings.notesSetupProblem(secrets: FakeSecrets())
        settings.provider = .claudeCode
        let notFound = settings.notesSetupProblem(secrets: FakeSecrets(), locate: { _ in nil })
        settings.provider = .local
        var problems = [missingKey, notFound]
        for (url, model) in [("", "qwen3:8b"), ("ftp://x", "qwen3:8b"), ("http://me:pw@localhost:11434/v1", "qwen3:8b"),
                             ("http://example.com/v1", "qwen3:8b"), ("http://localhost:11434/v1", " ")] {
            settings.localURL = url
            settings.localModel = model
            problems.append(settings.notesSetupProblem(secrets: FakeSecrets()))
        }
        #expect(Set(problems.compactMap(\.self)).count == 7)
        for line in problems.compactMap(\.self) {
            #expect(NotesSetup.needsSetup(banner: line))
            #expect(NotesSetup.needsSetup(banner: "Low disk space.\n\(line)"))
        }
        #expect(!NotesSetup.needsSetup(banner: nil))
        #expect(!NotesSetup.needsSetup(banner: "Recording stopped: less than 500 MB of disk space was left."))
    }

    @Test func aFailedLivePassNamesTheLocalModel() {
        #expect(LiveStatus.failed("x").line(provider: .local) == "Couldn't reach the local model; trying at the next check")
        for provider in [NotesProvider.claudeCode, .claudeAPI] {
            #expect(LiveStatus.failed("x").line(provider: provider) == "Couldn't reach Claude; trying at the next check")
        }
        for status in [LiveStatus.listening, .reading, .paused("Claude usage limit")] {
            #expect(status.line(provider: .local) == status.line)
        }
    }

    @Test(.timeLimit(.minutes(1))) func withoutALocalModelThePanelSaysTheLocalModelIsntSetUp() async throws {
        #expect(LiveSession.notSetUp(.local) == "the local model isn't set up, check Settings, Claude")
        #expect(LiveSession.notSetUp(.claudeCode) == LiveSession.claudeNotSetUp)
        let h = try LiveHarness()
        var settings = EarshotSettings()
        settings.provider = .local
        let live = h.live(client: nil, settings: settings)
        let events = Events(live.events)
        await live.start()
        await pollUntil { events.all.get.contains(.status(.paused(LocalModelSetup.notSetUp))) }
        #expect(await live.passNow() == nil)
        await live.stop()
    }
}
