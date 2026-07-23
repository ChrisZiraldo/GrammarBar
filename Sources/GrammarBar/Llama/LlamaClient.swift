import Foundation

struct LlamaClient {
    private static let systemPrompt = """
        You are a precise grammar and spelling corrector. \
        Fix all grammar, spelling, and punctuation errors. \
        Improve clarity only when the meaning is genuinely ambiguous. \
        Preserve the author's voice, style, and intent. \
        Return ONLY the corrected text — no commentary, no quotes, no explanation, no preamble.
        """

    private static let proofreadOnlySystemPrompt = """
        You are a precise proofreader. \
        Fix ONLY spelling mistakes, grammar errors, and punctuation errors. \
        Do NOT reword, rephrase, restructure, or otherwise change any part of the text that is already correct. \
        Do NOT improve style, clarity, tone, or word choice. \
        Make the smallest possible edit that fixes the error — leave everything else exactly as written. \
        Preserve the author's voice, style, and intent. \
        Return ONLY the corrected text — no commentary, no quotes, no explanation, no preamble.
        """

    let port: Int
    let proofreadOnly: Bool

    init(port: Int, proofreadOnly: Bool = false) {
        self.port = port
        self.proofreadOnly = proofreadOnly
    }

    // Streams corrected tokens for the given input text.
    func correct(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // Wrap the SSE loop in a structured Task so that cancelling the
            // stream (via continuation.onTermination) also stops the underlying
            // URLSession byte stream — preventing stale generations from piling
            // up on the single-threaded llama-server when the user keeps typing.
            let streamTask = Task {
                do {
                    guard let url = URL(string: "http://127.0.0.1:\(self.port)/v1/chat/completions") else {
                        continuation.finish(throwing: LlamaError.badStatus(-1))
                        return
                    }
                    var request = URLRequest(url: url, timeoutInterval: 30)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let body: [String: Any] = [
                        "model": "local-model",
                        "messages": [
                            ["role": "system", "content": self.proofreadOnly ? Self.proofreadOnlySystemPrompt : Self.systemPrompt],
                            ["role": "user", "content": text]
                        ],
                        "stream": true,
                        "temperature": 0.1,
                        "max_tokens": 2048
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw LlamaError.badStatus(code)
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }

                        guard
                            let data = payload.data(using: .utf8),
                            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                            let choices = json["choices"] as? [[String: Any]],
                            let delta = choices.first?["delta"] as? [String: Any],
                            let content = delta["content"] as? String
                        else { continue }

                        continuation.yield(content)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // When the consumer stops iterating (task cancelled, stream dropped,
            // or normal completion), cancel the producer Task so the URLSession
            // byte stream is torn down immediately rather than running to completion.
            continuation.onTermination = { _ in streamTask.cancel() }
        }
    }
}

enum LlamaError: LocalizedError {
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "llama-server returned HTTP \(code)"
        }
    }
}
