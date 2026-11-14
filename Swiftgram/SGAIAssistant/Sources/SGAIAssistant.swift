import Foundation
import SwiftSignalKit

public enum SGAIAssistantError {
    case missingApiKey
    // The Keychain read itself failed (device locked, entitlement issue, ...),
    // as opposed to no key being stored.
    case keychainRead(OSStatus)
    // HTTP 401: the stored API key is invalid, revoked or expired.
    case invalidApiKey
    // HTTP 429: rate limited; retryAfterSeconds comes from the Retry-After
    // header when it is a plain seconds value.
    case rateLimited(retryAfterSeconds: Int?)
    // Transport-level failures and HTTP 5xx: generic, retryable.
    case network
    case decoding
    case api(String)
}

public enum SGAIAssistantMode {
    case summarize
    case translate
    case draftReply
}

// NOTE: the data-collection acknowledgement is persisted in
// SGSimpleSettings.shared.aiAssistantDisclosureAccepted (one-time, set from the
// enable toggle in settings or on first use from the context menu).

private let sgAIAssistantModel: String = "claude-opus-4-8"
private let sgAIAssistantMaxTokens: Int = 1024
private let sgAIAssistantAnthropicVersion: String = "2023-06-01"
private let sgAIAssistantEndpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!
private let sgAIAssistantRequestTimeout: TimeInterval = 60.0

private let sgAIAssistantSessionConfiguration: URLSessionConfiguration = {
    let configuration: URLSessionConfiguration = .ephemeral
    configuration.timeoutIntervalForRequest = sgAIAssistantRequestTimeout
    return configuration
}()
private let sgAIAssistantSession: URLSession = URLSession(configuration: sgAIAssistantSessionConfiguration)

private func sgAIAssistantPrompt(_ mode: SGAIAssistantMode, text: String, lang: String) -> String {
    let languageInstruction: String = "Write your entire response in the language identified by the IETF/BCP-47 code \"\(lang)\"."
    switch mode {
        case .summarize:
            return "You are a concise assistant. Summarize the message below in a few sentences. \(languageInstruction) Output only the summary, with no preamble.\n\nMessage:\n\(text)"
        case .translate:
            return "You are a translation engine. Translate the message below into the language identified by the IETF/BCP-47 code \"\(lang)\". Output only the translation, with no preamble or notes.\n\nMessage:\n\(text)"
        case .draftReply:
            return "You are helping the user reply to a chat message. Draft a short, natural reply to the message below. \(languageInstruction) Output only the reply text, with no preamble or quotation.\n\nMessage:\n\(text)"
    }
}

private func sgAIAssistantParseSuccess(_ data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        return nil
    }
    guard let content = object["content"] as? [[String: Any]] else {
        return nil
    }
    var result: String = ""
    for block in content {
        if let type = block["type"] as? String, type == "text", let blockText = block["text"] as? String {
            result += blockText
        }
    }
    let trimmed: String = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func sgAIAssistantParseError(_ data: Data?, statusCode: Int) -> String {
    if let data = data, let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any], let error = object["error"] as? [String: Any], let message = error["message"] as? String {
        return message
    }
    return "HTTP \(statusCode)"
}

public func requestSGAIAssistant(apiKey: String, prompt: String) -> Signal<String, SGAIAssistantError> {
    return Signal { subscriber in
        let completed: Atomic<Bool> = Atomic(value: false)
        var request: URLRequest = URLRequest(url: sgAIAssistantEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = sgAIAssistantRequestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(sgAIAssistantAnthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": sgAIAssistantModel,
            "max_tokens": sgAIAssistantMaxTokens,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        guard let bodyData: Data = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            subscriber.putError(.decoding)
            return EmptyDisposable
        }
        request.httpBody = bodyData

        let downloadTask: URLSessionDataTask = sgAIAssistantSession.dataTask(with: request, completionHandler: { data, response, _ in
            let _ = completed.swap(true)
            guard let response: HTTPURLResponse = response as? HTTPURLResponse else {
                subscriber.putError(.network)
                return
            }
            if response.statusCode == 200 {
                if let data: Data = data, let result: String = sgAIAssistantParseSuccess(data) {
                    subscriber.putNext(result)
                    subscriber.putCompletion()
                } else {
                    subscriber.putError(.decoding)
                }
            } else if response.statusCode == 401 {
                subscriber.putError(.invalidApiKey)
            } else if response.statusCode == 429 {
                var retryAfterSeconds: Int?
                if let retryAfterValue: String = response.value(forHTTPHeaderField: "Retry-After"), let seconds: Int = Int(retryAfterValue.trimmingCharacters(in: .whitespaces)), seconds > 0 {
                    retryAfterSeconds = seconds
                }
                subscriber.putError(.rateLimited(retryAfterSeconds: retryAfterSeconds))
            } else if response.statusCode >= 500 {
                subscriber.putError(.network)
            } else {
                subscriber.putError(.api(sgAIAssistantParseError(data, statusCode: response.statusCode)))
            }
        })
        downloadTask.resume()

        return ActionDisposable {
            if !completed.with({ $0 }) {
                downloadTask.cancel()
            }
        }
    }
}

public func sgAIAssistant(_ mode: SGAIAssistantMode, text: String, lang: String) -> Signal<String, SGAIAssistantError> {
    let apiKey: String
    switch SGAIAssistantKeychain.readApiKey() {
        case let .success(storedKey):
            guard let storedKey = storedKey, !storedKey.isEmpty else {
                return .fail(.missingApiKey)
            }
            apiKey = storedKey
        case let .failure(.unexpectedStatus(status)):
            return .fail(.keychainRead(status))
    }
    let prompt: String = sgAIAssistantPrompt(mode, text: text, lang: lang)
    return requestSGAIAssistant(apiKey: apiKey, prompt: prompt)
}
