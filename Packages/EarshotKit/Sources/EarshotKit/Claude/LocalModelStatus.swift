import Foundation

/// Whether the local model server answers and has the chosen model. Free and fast: one `GET <base>/models`, never a
/// model call. For Settings, onboarding and `earshot doctor`.
public struct LocalModelStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable { case ready, noModelChosen, modelMissing, unreachable, badAddress, failed }

    public var state: State
    public var address: String
    public var model: String
    /// What the server lists, sorted, deduplicated.
    public var models: [String]
    /// The address problem, or the HTTP failure ("<status>: <detail>"), or why the server couldn't be reached.
    public var problem: String?

    public init(state: State, address: String, model: String, models: [String], problem: String?) {
        self.state = state
        self.address = address
        self.model = model
        self.models = models
        self.problem = problem
    }

    static let pullHint = "Download one first, for example: ollama pull qwen3:8b"

    /// The one line Settings shows.
    public var summary: String {
        let host = URL(string: address).map(LocalModelClient.displayHost) ?? address
        switch state {
        case .ready:
            return "Connected to \(host). \(model) is ready."
        case .noModelChosen:
            return models.isEmpty ? "Connected to \(host), but it lists no models. \(Self.pullHint)"
                : "Connected to \(host). Pick a model: \(Self.list(models))"
        case .modelMissing:
            return models.isEmpty ? "\(host) has no model named \(model), and it lists no models. \(Self.pullHint)"
                : "\(host) has no model named \(model). It has: \(Self.list(models))"
        case .unreachable:
            return "Can't reach \(address). Start Ollama, LM Studio or your server."
        case .badAddress:
            return problem ?? LocalModelClient.addressProblem(address) ?? LocalModelClient.wrongScheme
        case .failed:
            return "\(host) answered \(problem ?? "an error")"
        }
    }

    public static func check(address: String, model: String, session: URLSession = .shared,
                             timeout: Duration = .seconds(5)) async -> LocalModelStatus {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        func status(_ state: State, _ models: [String] = [], problem: String? = nil) -> LocalModelStatus {
            LocalModelStatus(state: state, address: address, model: model, models: models, problem: problem)
        }
        if let problem = LocalModelClient.addressProblem(address) { return status(.badAddress, problem: problem) }
        guard let base = URL(string: address) else { return status(.badAddress, problem: LocalModelClient.wrongScheme) }
        var request = URLRequest(url: LocalModelClient.endpoint(base, "models"),
                                 timeoutInterval: ClaudeAPIClient.seconds(timeout))
        request.httpMethod = "GET"
        let data: Data, code: Int
        do {
            let (body, response) = try await session.data(for: request, delegate: NoRedirects())
            (data, code) = (body, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return status(.unreachable, problem: error.localizedDescription)
        }
        guard code == 200 else { return status(.failed, problem: "\(code): \(LocalModelReply.errorMessage(data))") }
        guard let listed = modelIDs(data) else { return status(.failed, problem: "200: the model list couldn't be read") }
        let models = Array(Set(listed)).sorted()
        if model.isEmpty { return status(.noModelChosen, models) }
        return status(models.contains { matches(model, $0) } ? .ready : .modelMissing, models)
    }

    /// The ids in an OpenAI list (`data[].id`) and in Ollama's and llama.cpp's (`models[].name`, `models[].model`), or
    /// nil when the reply is neither.
    static func modelIDs(_ data: Data) -> [String]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let openAI = object["data"] as? [[String: Any]], ollama = object["models"] as? [[String: Any]]
        guard openAI != nil || ollama != nil else { return nil }
        let ids = (openAI ?? []).map { $0["id"] } + (ollama ?? []).flatMap { [$0["name"], $0["model"]] }
        return ids.compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    /// The same model, allowing for Ollama's `:latest` tag on either side.
    static func matches(_ chosen: String, _ listed: String) -> Bool {
        let bare = { (name: String) in name.hasSuffix(":latest") ? String(name.dropLast(":latest".count)) : name }
        return chosen == listed || bare(chosen) == bare(listed)
    }

    /// Up to five names, then how many more.
    static func list(_ models: [String]) -> String {
        let shown = models.prefix(5).joined(separator: ", ")
        return models.count > 5 ? "\(shown), and \(models.count - 5) more" : shown
    }
}
