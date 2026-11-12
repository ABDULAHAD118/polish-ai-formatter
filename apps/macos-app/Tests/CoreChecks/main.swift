import Foundation
import FormatterCore

var failures = 0
func check(_ name: String, _ passed: Bool) {
    print("\(passed ? "PASS" : "FAIL") \(name)")
    if !passed { failures += 1 }
}

func settings(_ provider: String = "ollama", model: String? = nil, key: String = "k", baseUrl: String = "http://127.0.0.1:11434", mode: String = "professional", custom: String = "") -> AISettings {
    AISettings(provider: provider, model: model ?? SharedConfig.shared.providers[provider]!.defaultModel, apiKey: key, baseUrl: baseUrl, mode: mode, customInstructions: custom, timeoutSeconds: 30)
}

func client(status: Int = 200, _ body: String) -> AIClient {
    AIClient(transport: { _ in (Data(body.utf8), status) })
}

func failureCode(_ work: () async throws -> String) async -> String {
    do {
        _ = try await work()
        return "no-error"
    } catch let e as AIError {
        return e.code
    } catch {
        return "other"
    }
}

let good = #"{"message":{"content":"Hello there."}}"#

check("config: Ollama and qwen2.5:3b are the defaults", SharedConfig.shared.defaults.provider == "ollama" && SharedConfig.shared.providers["ollama"]?.defaultModel == "qwen2.5:3b")
check("config: six modes with Professional as default", SharedConfig.shared.modes.count == 6 && SharedConfig.shared.defaults.mode == "professional")

check("update: v1.10.0 is newer than 1.9.2", isNewerVersion("v1.10.0", than: "1.9.2"))
check("update: same version is not newer", !isNewerVersion("v1.2.0", than: "1.2.0") && !isNewerVersion("1.2", than: "1.2.0"))
check("update: older version is not newer", !isNewerVersion("v1.1.9", than: "1.2.0"))
check("config: releases repo is owner/name", SharedConfig.shared.releasesRepo.split(separator: "/").count == 2)

let okText = try await client(good).format(draft: "hello there", settings: settings())
check("successful formatting", okText == "Hello there.")
check("empty input", await failureCode { try await client(good).format(draft: "  ", settings: settings()) } == "empty_draft")
check("empty model response", await failureCode { try await client(#"{"message":{"content":" "}}"#).format(draft: "hi", settings: settings()) } == "empty_response")
check("invalid JSON", await failureCode { try await client("<html>").format(draft: "hi", settings: settings()) } == "invalid_response")
check("wrong JSON shape", await failureCode { try await client("{}").format(draft: "hi", settings: settings()) } == "invalid_response")
check("model not found", await failureCode { try await client(status: 404, #"{"error":"x"}"#).format(draft: "hi", settings: settings()) } == "model_missing")

let down = AIClient(transport: { _ in throw URLError(.cannotConnectToHost) })
check("Ollama unavailable", await failureCode { try await down.format(draft: "hi", settings: settings()) } == "ollama_unavailable")
let slow = AIClient(transport: { _ in throw URLError(.timedOut) })
check("timeout", await failureCode { try await slow.format(draft: "hi", settings: settings()) } == "timeout")
let cancelled = AIClient(transport: { _ in throw URLError(.cancelled) })
check("cancelled", await failureCode { try await cancelled.format(draft: "hi", settings: settings()) } == "cancelled")
check("remote Ollama address refused", await failureCode { try await client(good).format(draft: "hi", settings: settings(baseUrl: "http://evil.example:11434")) } == "bad_url")
check("cloud provider needs a key", await failureCode { try await client(good).format(draft: "hi", settings: settings("openai", key: "")) } == "missing_key")
check("bad key", await failureCode { try await client(status: 401, "{}").format(draft: "hi", settings: settings("openai")) } == "auth")
check("rate limit", await failureCode { try await client(status: 429, "{}").format(draft: "hi", settings: settings("gemini")) } == "rate_limited")

let draft = "ali said api v2 deploy on 5 nov at 10:30, see https://x.io/a"
func rejects(_ text: String) -> Bool { (try? Validation.validate(text, draft: draft, mode: "professional")) == nil }
check("preserved numbers and links pass", !rejects("Ali said the API v2 deployment is on 5 Nov at 10:30. See https://x.io/a."))
check("changed date rejected", rejects("Ali said the API v2 deployment is on 6 Nov at 10:30. See https://x.io/a"))
check("dropped link rejected", rejects("Ali said the API v2 deployment is on 5 Nov at 10:30."))
check("invented number rejected", rejects("API v2 deploys on 5 Nov at 10:30, 99% done. See https://x.io/a"))
check("custom mode may translate", (try? Validation.validate("Bonjour", draft: draft, mode: "custom")) != nil)
check("commentary rejected", (try? Validation.validate("Here is the improved message:\nHello.", draft: "hello", mode: "professional")) == nil)
check("thinking and wrapping quotes removed", Validation.clean("<think>hmm</think>\n\"Hello.\"", draft: "hello") == "Hello.")
check("draft tags removed", Validation.clean("<draft>\nHello.\n</draft>", draft: "hello") == "Hello.")
check("added opener removed", Validation.clean("Sure, can you send it?", draft: "can you send it") == "Can you send it?")
check("sender's own opener kept", Validation.clean("Sure, I will send it.", draft: "sure i will send it") == "Sure, I will send it.")

func body(_ r: URLRequest) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:] }
let c = AIClient()

let ollamaRequest = try c.chatRequest(settings(), system: "sys", draft: "hi")
check("Ollama request", ollamaRequest.url?.absoluteString == "http://127.0.0.1:11434/api/chat" && body(ollamaRequest)["stream"] as? Bool == false)

let claudeRequest = try c.chatRequest(settings("claude"), system: "sys", draft: "hi")
check("Claude headers", claudeRequest.value(forHTTPHeaderField: "x-api-key") == "k" && claudeRequest.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
check("Claude has no sampling parameters", body(claudeRequest)["temperature"] == nil)
check("Claude uses server fallbacks", body(claudeRequest)["fallbacks"] as? String == "default")
let haikuRequest = try c.chatRequest(settings("claude", model: "claude-haiku-5-5"), system: "sys", draft: "hi")
check("Haiku omits fallbacks", body(haikuRequest)["fallbacks"] == nil && haikuRequest.value(forHTTPHeaderField: "anthropic-beta") == nil)
let parsedClaude = try c.parse(provider: "claude", ["stop_reason": "end_turn", "content": [["type": "thinking"], ["type": "text", "text": "Hi."]]])
check("Claude text blocks only", parsedClaude == "Hi.")
check("Claude refusal", (try? c.parse(provider: "claude", ["stop_reason": "refusal", "content": []])) == nil)

let openAIRequest = try c.chatRequest(settings("openai"), system: "sys", draft: "hi")
check("OpenAI request", openAIRequest.url?.path == "/v1/chat/completions" && openAIRequest.value(forHTTPHeaderField: "Authorization") == "Bearer k")
let geminiRequest = try c.chatRequest(settings("gemini"), system: "sys", draft: "hi")
check("Gemini request keeps the key out of the URL", geminiRequest.url?.absoluteString.contains("gemini-3.8-flash:generateContent") == true && geminiRequest.url?.query == nil && geminiRequest.value(forHTTPHeaderField: "x-goog-api-key") == "k")

let tags = try await client(#"{"models":[{"name":"qwen2.5:3b"}]}"#).checkConnection(settings())
check("connection check finds the model", tags.modelAvailable)
let tagsMissing = try await client(#"{"models":[]}"#).checkConnection(settings())
check("connection check reports a missing model", !tagsMissing.modelAvailable)

print(failures == 0 ? "All core checks passed" : "\(failures) core check(s) failed")
exit(failures == 0 ? 0 : 1)
