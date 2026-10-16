import Foundation

/// Reading what a local OpenAI-compatible server answered: the JSON object out of a chat completion, and what a
/// failure means.
enum LocalModelReply {
    /// What a status other than 200 calls for.
    enum Failure: Equatable {
        /// The server can't do `response_format`: send the request again without it.
        case withoutResponseFormat
        /// Overloaded or a server error: try again after a delay.
        case retry
        /// The meeting doesn't fit in the model's context window.
        case context
        /// The server has no model by that name.
        case model
        /// A 404 that isn't about the model: the address is missing its /v1.
        case endpoint
        /// A redirect, which is never followed.
        case redirect
        /// The server wants an API key.
        case key
        case other
    }

    static func failure(status: Int, message: String, structuredOutputs: Bool) -> Failure {
        let text = message.lowercased()
        let about = { (words: [String]) in words.contains(where: text.contains) }
        if status == 400 || status == 413, text.contains("context"), about(["exceed", "too long", "length", "size"]) {
            return .context
        }
        if status == 404 { return text.contains("model") ? .model : .endpoint }
        if status == 400, text.contains("model"), about(["not found", "does not exist", "not exist"]) { return .model }
        if (300...399).contains(status) { return .redirect }
        if status == 400, structuredOutputs, about(["response_format", "json_schema"]) { return .withoutResponseFormat }
        if status == 401 || status == 403 { return .key }
        if status == 429 || (500...599).contains(status) { return .retry }
        return .other
    }

    /// The JSON object the model wrote, from a 200 reply. A cut-off answer or a refusal is a failure, never half an
    /// object. The thinking (`reasoning_content`, or a `<think>` block) is never read as the answer. `sentBytes` is the
    /// UTF-8 size of the prompt text: a server that kept far fewer tokens than that (Ollama cuts a long prompt to its
    /// context and answers 200) gets the context message, not notes from part of the meeting.
    static func json(from data: Data, sentBytes: Int) throws -> Data {
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (reply["choices"] as? [[String: Any]])?.first else {
            throw NotesError.badOutput(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if promptWasCut(reply["usage"], sentBytes: sentBytes) { throw NotesError.local(LocalModelClient.contextTooSmall) }
        if choice["finish_reason"] as? String == "length" { throw NotesError.truncated }
        let message = choice["message"] as? [String: Any] ?? [:]
        if let refusal = message["refusal"], !(refusal is NSNull), (refusal as? String)?.isEmpty != true {
            throw NotesError.refused
        }
        let text = answer(text(of: message["content"]))
        guard let object = object(in: text) ?? object(in: answer(afterOpenThinking(text))) else {
            throw NotesError.badOutput(String(text.prefix(200)))
        }
        return Data(object.utf8)
    }

    /// Whether `usage.prompt_tokens` is under half a rough count of what was sent (4 bytes a token). A missing or zero
    /// count says nothing.
    static func promptWasCut(_ usage: Any?, sentBytes: Int) -> Bool {
        guard let tokens = ((usage as? [String: Any])?["prompt_tokens"] as? NSNumber)?.intValue, tokens > 0 else { return false }
        return tokens < sentBytes / 8
    }

    /// The text after the first `</think>` when no `<think>` opened it: the chat template put `<think>` in the
    /// prompt, so the reply starts with the thinking itself.
    static func afterOpenThinking(_ text: String) -> String {
        guard let close = text.range(of: "</think>", options: .caseInsensitive) else { return text }
        if let open = text.range(of: "<think>", options: .caseInsensitive), open.lowerBound < close.lowerBound { return text }
        return String(text[close.upperBound...])
    }

    /// Message content as text: a string, or the text parts of a list.
    static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.filter { ($0["type"] as? String ?? "text") == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    /// The text without leading `<think>` blocks (any case) and without a code fence around it.
    static func answer(_ content: String) -> String {
        var text = Substring(content)
        let thinking = /^\s*<think>.*?<\/think>/.ignoresCase().dotMatchesNewlines()
        while let match = text.prefixMatch(of: thinking) { text = text[match.range.upperBound...] }
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            // ```json then a new line; on one line, only the backticks go and `object(in:)` finds the braces.
            if let newline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: newline)...])
            } else {
                trimmed.removeFirst(3)
            }
            if trimmed.hasSuffix("```") { trimmed.removeLast(3) }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    /// The text from the first `{` to the last `}`, when it is one JSON object.
    static func object(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let candidate = String(text[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) is [String: Any] ? candidate : nil
    }

    /// The server's own words: `{"error":{"message":..}}`, `{"error":".."}` or `{"message":..}`, else the first 300
    /// bytes.
    static func errorMessage(_ data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"]
        let said = (error as? [String: Any])?["message"] as? String ?? error as? String ?? object?["message"] as? String
        return (said ?? String(decoding: data.prefix(300), as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
