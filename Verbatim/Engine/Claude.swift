import Foundation
import os

/// Claude, used once per meeting after the call: it reads the whole transcript, says which names were
/// misheard ("Randy Givens" → "Randy Giveans") and, when the voices were told apart, who "Person 1",
/// "Person 2"… are. It only returns those, so an hour costs about $0.10.
enum Claude {
    static let model = "claude-opus-5-5"
    private static let url = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "meetings")

    struct Fix: Decodable, Equatable {
        let heard: String
        let correct: String
    }

    /// "Person 2" is "Sara Bianchi". `name` is empty when the transcript doesn't make it clear.
    struct Speaker: Decodable, Equatable {
        let label: String
        let name: String
    }

    struct Review: Decodable {
        let fixes: [Fix]
        let speakers: [Speaker]
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The names that were misheard in `transcript`, and who each of `labels` ("Person 1"…) is.
    /// `names` are spellings known to be right (the people in the call and the Dictionary); `people` are
    /// the people known to be in the call, besides the one recording.
    static func review(transcript: String, title: String, names: [String], labels: [String], people: [String],
                       key: String) async throws -> Review {
        let known = names.isEmpty ? "" : "\nNames and words known to be spelled right:\n" + names.joined(separator: "\n") + "\n"
        var who = ""
        if !labels.isEmpty {
            let list = people.isEmpty ? "The names of the people in the call aren't known."
                : "The other people in the call: " + people.joined(separator: ", ") + "."
            who = """

            "You" is the person who recorded the call. The other voices were told apart by sound and labelled \
            \(labels.joined(separator: ", ")). \(list) For each label, say who it is, but only when the transcript \
            makes it clear: someone calls them by name and they answer, they introduce themselves, they're asked \
            something by name and reply, and so on. Prefer the names in the list. Two labels can be the same \
            person. If it isn't clear, leave the name empty: a wrong name is worse than none.

            """
        }
        let prompt = """
        This is the transcript of a meeting called "\(title)", written by a speech recognizer. It often mishears \
        names: people, companies, products, places, and technical terms.
        \(known)
        Find the names in the transcript that were misheard and give the right spelling. Use the list above, the \
        context of the meeting, and what you know (well-known companies, products, places). Only include a fix \
        when you're confident. Copy "heard" exactly as it is written in the transcript, so it can be found and \
        replaced. Leave ordinary words alone, and never change the meaning. If nothing needs fixing, return no fixes.
        \(who)
        <transcript>
        \(transcript)
        </transcript>
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "speakers": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": ["label": ["type": "string"], "name": ["type": "string"]],
                        "required": ["label", "name"],
                        "additionalProperties": false,
                    ],
                ],
                "fixes": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": ["heard": ["type": "string"], "correct": ["type": "string"]],
                        "required": ["heard", "correct"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["fixes", "speakers"],
            "additionalProperties": false,
        ]
        let text = try await send(prompt, key: key, effort: "low", schema: schema, maxTokens: 16000, what: "names")
        let review = try JSONDecoder().decode(Review.self, from: Data(text.utf8))
        let name = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Review(fixes: review.fixes.filter { !$0.heard.isEmpty && $0.heard != $0.correct },
                      speakers: review.speakers.filter { labels.contains($0.label) && !name($0.name).isEmpty
                          && name($0.name).lowercased() != "you" }
                          .map { Speaker(label: $0.label, name: name($0.name)) })
    }

    /// One request; returns the text of the answer (JSON when there's a `schema`).
    static func send(_ prompt: String, system: String? = nil, images: [Data] = [], key: String, effort: String,
                     schema: [String: Any]? = nil, maxTokens: Int, timeout: TimeInterval = 180, what: String) async throws -> String {
        var output: [String: Any] = ["effort": effort]
        if let schema { output["format"] = ["type": "json_schema", "schema": schema] }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "output_config": output,
            "messages": [["role": "user", "content": images.map { image -> [String: Any] in
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]]
            } + [["type": "text", "text": prompt]]]],
        ]
        if let system { body["system"] = system }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let request = req
        let (data, resp) = try await withDeadline(timeout) { try await URLSession.shared.data(for: request) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure(message: errorMessage(data) ?? "Claude didn't answer (\(code))") }

        struct Reply: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            struct Usage: Decodable { let input_tokens: Int; let output_tokens: Int }
            let content: [Block]
            let stop_reason: String?
            let usage: Usage?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        if let u = reply.usage {
            log.notice("claude \(what, privacy: .public): \(u.input_tokens) in, \(u.output_tokens) out, \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
        }
        guard reply.stop_reason != "refusal", reply.stop_reason != "max_tokens",
              let text = reply.content.last(where: { $0.type == "text" })?.text
        else { throw Failure(message: "Claude didn't finish (\(reply.stop_reason ?? "no reason"))") }
        return text
    }

    /// Checks a key with a tiny request.
    static func validate(key: String) async -> Result<Void, Error> {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 30
        let body: [String: Any] = ["model": "claude-haiku-5-5", "max_tokens": 16,
                                   "messages": [["role": "user", "content": "Say ok."]]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return .success(()) }
            return .failure(Failure(message: code == 401 ? "That key doesn't work." : errorMessage(data) ?? "Claude answered \(code)."))
        } catch {
            return .failure(error)
        }
    }

    private static func errorMessage(_ data: Data) -> String? {
        struct E: Decodable { struct Inner: Decodable { let message: String }; let error: Inner }
        return (try? JSONDecoder().decode(E.self, from: data))?.error.message
    }

    /// Puts the fixes into a piece of text, whole words only.
    static func apply(_ fixes: [Fix], to text: String) -> String {
        var out = text
        for f in fixes {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: f.heard) + "(?![\\p{L}\\p{N}])"
            out = out.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: f.correct),
                                           options: .regularExpression)
        }
        return out
    }
}
