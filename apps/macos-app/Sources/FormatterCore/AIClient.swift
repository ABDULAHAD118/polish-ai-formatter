import Foundation

// Provider client for the macOS app. apps/chrome-extension/src/ai-core.js mirrors it.
// Never log drafts or model output here.

public struct SharedConfig: Decodable, Sendable {
    public struct Provider: Decodable, Sendable {
        public let name: String
        public let local: Bool
        public let baseUrl: String
        public let defaultModel: String
    }
    public struct Mode: Decodable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let instruction: String
    }
    public struct Defaults: Decodable, Sendable {
        public let provider: String
        public let mode: String
        public let timeoutSeconds: Double
        public let temperature: Double
    }
    public let whatsAppBundleId: String
    public let defaults: Defaults
    public let providers: [String: Provider]
    public let modes: [Mode]
    public let systemPrompt: String

    public static let shared: SharedConfig = {
        // Config ships in the binary, so a decode failure is a build error caught by CoreChecks.
        try! JSONDecoder().decode(SharedConfig.self, from: Data(PackageResources.config_json))
    }()

    public static let providerOrder = ["ollama", "claude", "openai", "gemini"]
}

public struct AIError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

public struct AISettings: Sendable {
    public var provider: String
    public var model: String
    public var apiKey: String
    public var baseUrl: String
    public var mode: String
    public var customInstructions: String
    public var timeoutSeconds: Double

    public init(provider: String, model: String, apiKey: String, baseUrl: String, mode: String, customInstructions: String, timeoutSeconds: Double) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
        self.baseUrl = baseUrl
        self.mode = mode
        self.customInstructions = customInstructions
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum Validation {
    private static func matches(_ pattern: String, _ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func digitRuns(_ text: String) -> Set<String> {
        Set(matches(#"\d+"#, text).map { run -> String in
            let trimmed = run.drop { $0 == "0" }
            return trimmed.isEmpty ? "0" : String(trimmed)
        }.filter { $0 != "0" })
    }

    private static func urls(_ text: String) -> [String] {
        matches(#"https?://[^\s)]+"#, text).map { url in
            var u = url
            while let last = u.last, ".,!?;:".contains(last) { u.removeLast() }
            return u
        }
    }

    public static func clean(_ raw: String, draft: String) -> String {
        var text = raw.replacingOccurrences(of: #"(?is)<think>.*?</think>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</?draft>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let draftQuoted = draft.trimmingCharacters(in: .whitespacesAndNewlines).first.map { "\"“".contains($0) } ?? false
        if text.count >= 2, let first = text.first, let last = text.last,
           "\"“".contains(first), "\"”".contains(last), !draftQuoted {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Small models keep adding this opener despite the prompt, and it reads as a reply.
        if let opener = text.range(of: #"(?i)^(sure|certainly|of course)[,!.]\s+"#, options: .regularExpression),
           draft.range(of: #"(?i)^\s*(sure|certainly|of course)\b"#, options: .regularExpression) == nil {
            text.removeSubrange(opener)
            text = text.prefix(1).uppercased() + text.dropFirst()
        }
        return text
    }

    // Numbers and links are checked both ways: a missing one was dropped and a new one was
    // invented. Custom mode skips this because the user may ask for something like translation.
    public static func validate(_ text: String, draft: String, mode: String) throws {
        if text.isEmpty {
            throw AIError("empty_response", "The AI returned an empty response. Your draft was not changed.")
        }
        if text.range(of: #"(?i)^(here(’|')?s|here is|sure|certainly|of course)\b[^\n]*:\s*\n"#, options: .regularExpression) != nil {
            throw AIError("invalid_response", "The AI added commentary instead of only the message. Your draft was not changed.")
        }
        if mode == "custom" { return }
        let linkDropped = urls(draft).contains { !text.lowercased().contains($0.lowercased()) }
        if digitRuns(draft) != digitRuns(text) || linkDropped {
            throw AIError("facts_changed", "The AI changed a number or link, so your draft was kept. Try again.")
        }
    }
}

public struct AIClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    let config: SharedConfig
    let transport: Transport

    public init(config: SharedConfig = .shared, transport: Transport? = nil) {
        self.config = config
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public func systemPrompt(mode: String, custom: String) throws -> String {
        if mode == "custom" {
            let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw AIError("custom_empty", "Custom mode has no instructions. Add them in Settings.")
            }
            return "\(config.systemPrompt)\n\nAdditional formatting instructions from the user:\n\(trimmed)"
        }
        let m = config.modes.first { $0.id == mode } ?? config.modes[0]
        return "\(config.systemPrompt)\n\nFormatting mode: \(m.name). \(m.instruction)"
    }

    // A "local" setting must never quietly send drafts to another machine.
    func loopbackBase(_ baseUrl: String) throws -> String {
        guard let url = URL(string: baseUrl), let host = url.host, ["127.0.0.1", "localhost", "::1"].contains(host),
              url.scheme?.hasPrefix("http") == true else {
            throw AIError("bad_url", "The Ollama address must be on this computer (127.0.0.1 or localhost).")
        }
        return baseUrl.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
    }

    func applyAuth(_ request: inout URLRequest, _ s: AISettings) throws {
        if s.provider == "ollama" { return }
        if s.apiKey.isEmpty {
            throw AIError("missing_key", "Add your \(config.providers[s.provider]?.name ?? "API") key in Settings.")
        }
        switch s.provider {
        case "claude":
            request.setValue(s.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        case "openai":
            request.setValue("Bearer \(s.apiKey)", forHTTPHeaderField: "Authorization")
        default:
            request.setValue(s.apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
    }

    public func chatRequest(_ s: AISettings, system: String, draft rawDraft: String) throws -> URLRequest {
        // Tags stop models from treating a draft that asks a question as a question to them.
        let draft = "<draft>\n\(rawDraft)\n</draft>"
        let base = s.provider == "ollama" ? try loopbackBase(s.baseUrl) : (config.providers[s.provider]?.baseUrl ?? "")
        var path: String
        var body: [String: Any]
        var beta: String?
        let chatMessages: [[String: String]] = [["role": "system", "content": system], ["role": "user", "content": draft]]

        switch s.provider {
        case "ollama":
            path = "/api/chat"
            body = ["model": s.model, "stream": false, "messages": chatMessages, "options": ["temperature": config.defaults.temperature]]
        case "claude":
            path = "/v1/messages"
            // Sampling parameters are rejected on this API version, so temperature is left out.
            body = ["model": s.model, "max_tokens": 16000, "system": system, "messages": [["role": "user", "content": draft]]]
            if s.model.range(of: #"^claude-(fable|opus|sonnet|haiku)-5"#, options: .regularExpression) != nil {
                body["output_config"] = ["effort": "low"]
            }
            if s.model.range(of: #"^claude-(fable-5-1|opus-5|sonnet-5-5)"#, options: .regularExpression) != nil {
                body["fallbacks"] = "default"
                beta = "server-side-fallback-2026-07-01"
            }
        case "openai":
            path = "/v1/chat/completions"
            // Some OpenAI models reject non-default temperature, so it is left out.
            body = ["model": s.model, "messages": chatMessages]
        default:
            let model = s.model.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._"))) ?? s.model
            path = "/v1beta/models/\(model):generateContent"
            body = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": draft]]]],
                "generationConfig": ["temperature": config.defaults.temperature],
            ]
        }

        guard let url = URL(string: base + path) else { throw AIError("bad_url", "The provider address is not valid.") }
        var request = URLRequest(url: url, timeoutInterval: s.timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        try applyAuth(&request, s)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func parse(provider: String, _ json: [String: Any]) throws -> String {
        let truncated = AIError("truncated", "The AI response was cut off. Your draft was not changed.")
        let invalid = AIError("invalid_response", "The AI returned an unexpected response. Your draft was not changed.")
        var text: String?
        switch provider {
        case "ollama":
            if json["done_reason"] as? String == "length" { throw truncated }
            text = (json["message"] as? [String: Any])?["content"] as? String
        case "claude":
            if json["stop_reason"] as? String == "refusal" {
                throw AIError("refused", "Claude declined this message. Your draft was not changed.")
            }
            if json["stop_reason"] as? String == "max_tokens" { throw truncated }
            if let content = json["content"] as? [[String: Any]] {
                text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            }
        case "openai":
            let choice = (json["choices"] as? [[String: Any]])?.first
            if choice?["finish_reason"] as? String == "length" { throw truncated }
            if choice?["finish_reason"] as? String == "content_filter" {
                throw AIError("refused", "OpenAI declined this message. Your draft was not changed.")
            }
            text = (choice?["message"] as? [String: Any])?["content"] as? String
        default:
            let candidate = (json["candidates"] as? [[String: Any]])?.first
            if candidate?["finishReason"] as? String == "MAX_TOKENS" { throw truncated }
            if json["promptFeedback"].flatMap({ ($0 as? [String: Any])?["blockReason"] }) != nil || candidate?["finishReason"] as? String == "SAFETY" {
                throw AIError("refused", "Gemini declined this message. Your draft was not changed.")
            }
            if let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined()
            }
        }
        guard let text else { throw invalid }
        return text
    }

    func httpError(_ s: AISettings, status: Int, data: Data) -> AIError {
        let name = config.providers[s.provider]?.name ?? "The AI provider"
        if s.provider == "ollama", status == 404 {
            return AIError("model_missing", "Model \"\(s.model)\" is not installed. Run: ollama pull \(s.model). If it is still downloading, wait for it to finish.")
        }
        switch status {
        case 401, 403: return AIError("auth", "\(name) rejected the API key. Check it in Settings.")
        case 404: return AIError("model_missing", "\(name) does not offer model \"\(s.model)\". Pick another in Settings.")
        case 429: return AIError("rate_limited", "\(name) rate limit or quota reached. Try again later or check your plan.")
        default:
            var detail = ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                detail = ((json["error"] as? [String: Any])?["message"] as? String) ?? (json["error"] as? String) ?? ""
            }
            return AIError("http_error", "\(name) returned an error (\(status))\(detail.isEmpty ? "" : ": \(detail.prefix(200))").")
        }
    }

    func send(_ request: URLRequest, _ s: AISettings) async throws -> Data {
        do {
            let (data, status) = try await transport(request)
            if !(200..<300).contains(status) { throw httpError(s, status: status, data: data) }
            return data
        } catch let error as AIError {
            throw error
        } catch is CancellationError {
            throw AIError("cancelled", "Formatting cancelled.")
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw AIError("cancelled", "Formatting cancelled.")
            case .timedOut: throw AIError("timeout", "The AI took too long. Try again, or raise the timeout in Settings.")
            default: break
            }
        } catch {}
        if s.provider == "ollama" {
            throw AIError("ollama_unavailable", "Cannot reach Ollama. Install it from ollama.com, or start it with: ollama serve")
        }
        throw AIError("network", "Cannot reach \(config.providers[s.provider]?.name ?? "the provider"). Check your internet connection.")
    }

    public func format(draft: String, settings s: AISettings) async throws -> String {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIError("empty_draft", "Write a message first.")
        }
        let system = try systemPrompt(mode: s.mode, custom: s.customInstructions)
        let data = try await send(try chatRequest(s, system: system, draft: draft), s)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AIError("invalid_response", "The AI returned an unexpected response. Your draft was not changed.")
        }
        let text = Validation.clean(try parse(provider: s.provider, json), draft: draft)
        try Validation.validate(text, draft: draft, mode: s.mode)
        return text
    }

    public struct ConnectionResult: Sendable {
        public let models: [String]
        public let modelAvailable: Bool
    }

    public func checkConnection(_ s: AISettings) async throws -> ConnectionResult {
        let path: String
        switch s.provider {
        case "ollama": path = "/api/tags"
        case "claude": path = "/v1/models?limit=100"
        case "openai": path = "/v1/models"
        default: path = "/v1beta/models?pageSize=200"
        }
        let base = s.provider == "ollama" ? try loopbackBase(s.baseUrl) : (config.providers[s.provider]?.baseUrl ?? "")
        guard let url = URL(string: base + path) else { throw AIError("bad_url", "The provider address is not valid.") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        try applyAuth(&request, s)
        let data = try await send(request, s)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AIError("invalid_response", "The AI returned an unexpected response.")
        }
        let models: [String]
        switch s.provider {
        case "ollama":
            models = ((json["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        case "gemini":
            models = ((json["models"] as? [[String: Any]]) ?? []).filter {
                ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true
            }.compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
        default:
            models = ((json["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        }
        return ConnectionResult(models: models, modelAvailable: models.contains(s.model) || models.contains("\(s.model):latest"))
    }
}
