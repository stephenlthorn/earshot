import Foundation
import Testing
@testable import EarshotKit

/// `GET <base>/models` as each kind of server answers it.
private let openAIList = #"{"object":"list","data":[{"id":"qwen3-8b","object":"model"},{"id":"gemma3:4b","object":"model"}]}"#
/// llama.cpp lists both shapes for one model.
private let llamaList = #"{"object":"list","data":[{"id":"qwen3-8b"}],"models":[{"name":"qwen3-8b","model":"qwen3-8b"}]}"#
/// Ollama's own list shape, with `:latest` tags.
private let ollamaList = #"{"models":[{"name":"llama3.1:latest","model":"llama3.1:latest"},{"name":"qwen3:8b","model":"qwen3:8b"}]}"#

private func check(_ replies: [(Int, String)], model: String, path: String = "/v1") async -> (LocalModelStatus, URL) {
    let url = StubHTTP.url(path: path, replies: replies)
    return (await LocalModelStatus.check(address: url.absoluteString, model: model, session: StubHTTP.session), url)
}

struct LocalModelStatusTests {
    @Test func readyWhenTheServerListsTheChosenModel() async throws {
        let (status, url) = await check([(200, openAIList)], model: " qwen3-8b ")
        let host = try #require(url.host())
        #expect(status == LocalModelStatus(state: .ready, address: url.absoluteString, model: "qwen3-8b",
                                           models: ["gemma3:4b", "qwen3-8b"], problem: nil))
        #expect(status.summary == "Connected to \(host). qwen3-8b is ready.")
        let sent = try #require(StubHTTP.requests(url).first)
        #expect(sent.httpMethod == "GET" && sent.url?.path() == "/v1/models" && sent.timeoutInterval == 5)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func bothListShapesAreReadSortedAndDeduplicated() async {
        let (llama, _) = await check([(200, llamaList)], model: "qwen3-8b", path: "/v1/")
        #expect(llama.state == .ready && llama.models == ["qwen3-8b"])
        let (ollama, _) = await check([(200, ollamaList)], model: "qwen3:8b")
        #expect(ollama.state == .ready && ollama.models == ["llama3.1:latest", "qwen3:8b"])
    }

    @Test func ollamasLatestTagMatchesEitherWay() async {
        #expect(await check([(200, ollamaList)], model: "llama3.1").0.state == .ready)
        #expect(await check([(200, #"{"data":[{"id":"mistral"}]}"#)], model: "mistral:latest").0.state == .ready)
        #expect(await check([(200, ollamaList)], model: "qwen3").0.state == .modelMissing)
        #expect(LocalModelStatus.matches("llama3.1", "llama3.1:latest") && LocalModelStatus.matches("a:latest", "a"))
        #expect(!LocalModelStatus.matches("qwen3", "qwen3:8b"))
    }

    @Test func noModelChosenListsUpToFive() async throws {
        let many = (1...8).map { #"{"id":"m\#($0)"}"# }.joined(separator: ",")
        let (status, url) = await check([(200, #"{"data":[\#(many)]}"#)], model: "  ")
        let host = try #require(url.host())
        #expect(status.state == .noModelChosen && status.models.count == 8)
        #expect(status.summary == "Connected to \(host). Pick a model: m1, m2, m3, m4, m5, and 3 more")
        let (two, twoURL) = await check([(200, openAIList)], model: "")
        let twoURLHost = try #require(twoURL.host())
        #expect(two.summary == "Connected to \(twoURLHost). Pick a model: gemma3:4b, qwen3-8b")
    }

    @Test func aServerWithNoModelsSaysHowToGetOne() async throws {
        let (status, url) = await check([(200, #"{"object":"list","data":[]}"#)], model: "")
        #expect(status.state == .noModelChosen && status.models.isEmpty)
        let urlHost = try #require(url.host())
        #expect(status.summary == "Connected to \(urlHost), but it lists no models. Download one first, for example: ollama pull qwen3:8b")
    }

    @Test func aMissingModelNamesWhatTheServerHas() async throws {
        let (status, url) = await check([(200, openAIList)], model: "llama3.1:8b")
        let host = try #require(url.host())
        #expect(status.state == .modelMissing)
        #expect(status.summary == "\(host) has no model named llama3.1:8b. It has: gemma3:4b, qwen3-8b")
        let (none, noneURL) = await check([(200, #"{"data":[]}"#)], model: "llama3.1:8b")
        #expect(none.state == .modelMissing)
        let noneURLHost = try #require(noneURL.host())
        #expect(none.summary == "\(noneURLHost) has no model named llama3.1:8b, and it lists no models. Download one first, for example: ollama pull qwen3:8b")
    }

    @Test func aServerThatIsntRunningIsUnreachable() async {
        let (status, url) = await check([(URLError.Code.cannotConnectToHost.rawValue, "")], model: "qwen3-8b")
        #expect(status.state == .unreachable && status.problem != nil)
        #expect(status.summary == "Can't reach \(url.absoluteString). Start Ollama, LM Studio or your server.")
    }

    @Test func aBadAddressIsNeverCalled() async {
        for (address, problem) in [("", "Type the address of your local model server in Settings, Claude."),
                                   ("http://example.com/v1", "Plain http:// works only for this Mac or your local network. Use https:// for anything else.")] {
            let status = await LocalModelStatus.check(address: address, model: "m", session: StubHTTP.session)
            #expect(status.state == .badAddress && status.problem == problem && status.summary == problem)
        }
    }

    @Test func anHTTPFailureOrAnUnreadableListIsFailed() async throws {
        let (status, url) = await check([(401, #"{"error":{"message":"Invalid API key"}}"#)], model: "m")
        let host = try #require(url.host())
        #expect(status.state == .failed && status.summary == "\(host) answered 401: Invalid API key")
        let (odd, oddURL) = await check([(200, "<html>hello</html>")], model: "m")
        let oddURLHost = try #require(oddURL.host())
        #expect(odd.state == .failed && odd.summary == "\(oddURLHost) answered 200: the model list couldn't be read")
    }

    @Test func aRedirectIsNotFollowed() async throws {
        let elsewhere = "http://leak-\(UUID().uuidString.lowercased()).example.com/v1/models"
        let (status, url) = await check([(307, elsewhere), (200, #"{"data":[{"id":"m"}]}"#)], model: "m")
        #expect(status.state == .failed && StubHTTP.requests(url).count == 1)
        #expect(StubHTTP.requests(try #require(URL(string: elsewhere))).isEmpty)
    }

    @Test func noSummaryHasAnEmDash() {
        let states: [LocalModelStatus.State] = [.ready, .noModelChosen, .modelMissing, .unreachable, .badAddress, .failed]
        for state in states {
            for models in [[], ["a", "b"]] {
                let status = LocalModelStatus(state: state, address: "http://localhost:11434/v1", model: "a", models: models,
                                              problem: "x")
                #expect(!status.summary.contains("\u{2014}") && !status.summary.isEmpty, "\(state)")
            }
        }
        #expect(LocalModelStatus(state: .ready, address: "http://localhost:11434/v1", model: "a", models: ["a"], problem: nil)
                .summary == "Connected to localhost:11434. a is ready.")
    }
}
