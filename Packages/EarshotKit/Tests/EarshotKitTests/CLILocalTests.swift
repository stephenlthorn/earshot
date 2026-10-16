import Foundation
import Testing
@testable import EarshotKit

/// One fixed line of speech.
private struct OneLineTranscriber: Transcribing {
    func transcribe(_ file: URL, track: Track, locale: Locale) async throws -> [Segment] {
        [Segment(track: .speaker, start: 2, end: 4, text: "Dana, I'll send the scope by Friday.")]
    }
}

/// Copies instead of encoding.
private struct CopyCompressor: AudioCompressing {
    func compress(_ source: URL, to destination: URL) async throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func duration(of file: URL) throws -> Double { 120 }
}

/// `earshot process` and `earshot doctor` with the local model provider: no `claude`, only the server.
struct CLILocalTests {
    private func harness(url: String, model: String = "qwen3:8b") -> CLIHarness {
        var h = CLIHarness()
        h.settings?.provider = .local
        h.settings?.localURL = url
        h.settings?.localModel = model
        h.claudePath = nil
        return h
    }

    private func process(_ h: CLIHarness, _ words: [String]) async throws -> (code: Int32, out: String, err: String) {
        let audio = h.home.appending(path: "memo.m4a")
        try Data("audio".utf8).write(to: audio)
        let printed = Printed()
        var io = h.io(printed)
        io.transcriber = OneLineTranscriber()
        io.compressor = CopyCompressor()
        let code = await EarshotCLI.main(["earshot", "process", audio.path] + words, io: io)
        return (code, printed.out.get, printed.err.get)
    }

    @Test func processWritesNotesThroughTheLocalServer() async throws {
        let url = StubHTTP.url(path: "/v1", replies: [(200, chatReply("<think>Reading.</think>\n" + notesText))])
        let h = harness(url: url.absoluteString)
        let result = try await process(h, ["--title", "Acme kickoff", "--json"])
        #expect(result.code == 0, "\(result.err)")
        let report = try JSONFiles.decoder().decode(EarshotCLI.ProcessReport.self, from: Data(result.out.utf8))
        #expect(report.finished && report.error == nil && report.notes == report.folder + "/notes.md")
        let saved = try JSONFiles.read(MeetingNotes.self, from: URL(filePath: report.folder).appending(path: MeetingFile.notes))
        #expect(saved.actionItems == sampleNotes.actionItems)
        let sent = try #require(StubHTTP.requests(url).first)
        #expect(sent.url?.path() == "/v1/chat/completions" && sent.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "qwen3:8b")
        #expect((body["messages"] as? [[String: String]])?.last?["content"]?.contains("I'll send the scope by Friday") == true)
        #expect((h.runner as? FakeRunner)?.calls.isEmpty == true, "no claude is run")
    }

    @Test func processRefusesALocalSetupThatIsntFinished() async throws {
        let noModel = try await process(harness(url: "http://localhost:11434/v1", model: " "), [])
        #expect(noModel.code == 2 && noModel.err == "earshot: \(LocalModelClient.pickModel)\n")
        let badAddress = try await process(harness(url: "http://example.com/v1"), [])
        #expect(badAddress.code == 2 && badAddress.err.contains(LocalModelClient.plainHTTP))
    }

    @Test func processSaysWhenTheServerIsDown() async throws {
        let url = StubHTTP.url(path: "/v1", replies: [(URLError.Code.cannotConnectToHost.rawValue, "")])
        let result = try await process(harness(url: url.absoluteString), ["--json"])
        #expect(result.code == 1)
        let report = try JSONFiles.decoder().decode(EarshotCLI.ProcessReport.self, from: Data(result.out.utf8))
        #expect(!report.finished && report.error?.contains(LocalModelClient.unreachable(url.absoluteString)) == true)
    }

    @Test func doctorChecksTheLocalModelFirst() async throws {
        let list = #"{"object":"list","data":[{"id":"qwen3:8b"}]}"#
        let url = StubHTTP.url(path: "/v1", replies: [(200, list), (200, list)])
        let ready = harness(url: url.absoluteString)
        let checks = try JSONDecoder().decode([EarshotCLI.Check].self, from: Data(await ready.run("doctor", "--json").out.utf8))
        #expect(checks.map(\.name) == ["Local model", "Speech model", "Meetings folder", "Index", "MCP server", "Claude Code plugin",
                                       "App location"])
        let host = try #require(url.host())
        #expect(checks[0] == EarshotCLI.Check(name: "Local model", status: .ok, detail: "Connected to \(host). qwen3:8b is ready."))
        #expect(StubHTTP.requests(url).first?.url?.path() == "/v1/models")
        let missing = harness(url: url.absoluteString, model: "llama3.1:8b")
        let text = await missing.run("doctor")
        #expect(text.code == 1 && text.out.hasPrefix("fail Local model: \(host) has no model named llama3.1:8b. It has: qwen3:8b\n"))
        #expect((missing.runner as? FakeRunner)?.calls.isEmpty == true, "no claude is run")
    }

    @Test func helpNamesTheLocalOption() async {
        let help = await CLIHarness().run("help")
        #expect(help.out.contains("a local model server (Ollama, LM Studio, llama.cpp)"))
    }
}
