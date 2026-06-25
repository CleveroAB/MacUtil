import Foundation

final class OpenRouterClient {
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    @discardableResult
    func generateEmailReply(
        transcript: String,
        context: String?,
        model: String,
        apiKey: String,
        completion: @escaping (Result<String, VoiceInputError>) -> Void
    ) -> URLSessionDataTask {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MacUtil", forHTTPHeaderField: "X-OpenRouter-Title")

        let requestBody = ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: Self.systemPrompt),
                ChatMessage(role: "user", content: userPrompt(transcript: transcript, context: context)),
            ],
            temperature: 0.35,
            maxTokens: 900
        )

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            completion(.failure(.aiReplyFailed(error.localizedDescription)))
            return URLSession.shared.dataTask(with: request)
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.aiReplyFailed(error.localizedDescription)))
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data else {
                completion(.failure(.aiReplyFailed("OpenRouter returned an empty response.")))
                return
            }

            guard (200..<300).contains(statusCode) else {
                let message = Self.errorMessage(from: data) ?? "OpenRouter returned HTTP \(statusCode)."
                completion(.failure(.aiReplyFailed(message)))
                return
            }

            do {
                let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
                let text = decoded.choices.first?.message.content
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else {
                    completion(.failure(.aiReplyFailed("The selected model returned no text.")))
                    return
                }
                completion(.success(text))
            } catch {
                completion(.failure(.aiReplyFailed(error.localizedDescription)))
            }
        }
        task.resume()
        return task
    }

    private func userPrompt(transcript: String, context: String?) -> String {
        let cleanedContext = context?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleanedContext.isEmpty {
            return """
            Original email/context:
            No explicit email context was provided.

            User's spoken intent:
            \(cleanedTranscript)

            Write the email reply.
            """
        }

        return """
        Original email/context:
        \(cleanedContext)

        User's spoken intent:
        \(cleanedTranscript)

        Write the email reply.
        """
    }

    private static let systemPrompt = """
    You write email replies from rough spoken notes.
    Return only the email body, with no subject line, markdown, preamble, or explanation.
    Keep the reply concise, clear, and professional unless the user's spoken intent asks otherwise.
    Infer the language from the user's spoken intent and write the reply in that same language.
    If the email context is in a different language than the spoken intent, still answer in the spoken intent's language.
    Preserve names, dates, prices, product names, commitments, and constraints from the context.
    Do not invent facts, promises, attachments, meetings, prices, or deadlines.
    If the spoken intent is ambiguous, write a safe reply that asks for clarification instead of guessing.
    """

    private static func errorMessage(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(OpenRouterErrorResponse.self, from: data) {
            return decoded.error.message
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ChatMessage
    }
}

private struct OpenRouterErrorResponse: Decodable {
    let error: OpenRouterError

    struct OpenRouterError: Decodable {
        let message: String
    }
}
