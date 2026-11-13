import Foundation

/// ⌥⌥ with nothing selected, when it isn't "open" or "search": a question or a request about what's on
/// screen. It either writes text for the box you're typing in ("reply saying I'll be there at 5") or answers
/// ("what does this error mean"), shown in a panel.
enum Assistant {
    struct Reply: Decodable {
        /// "write" or "answer".
        let mode: String
        let text: String
        var writes: Bool { mode == "write" }
    }

    private static let system = """
    You're a voice assistant on the user's Mac. You get what they said and what's on their screen: the front \
    app, its window's text and maybe a picture of it. They're either asking you to write something for the text \
    box they're typing in, or asking a question.

    mode "write": they want text to put in the text box (a reply, a message, an email, a comment, a commit \
    message). Write only that text, ready to send: no quotes, no notes, no subject line unless asked. Match the \
    conversation on screen: its language (unless they ask for another), its tone, and how long people write \
    there. Use what's on screen (names, dates, what was asked). If they said what to say, say that, in good words. \
    If there's already a draft in the box, write the full text that should replace it.

    mode "answer": anything else (a question, explain, summarise, what's this). Answer short and direct, like a \
    colleague looking at the same screen: the answer first, a few sentences at most, plain text, no headings. A \
    short list only when it's a list. Answer in the language they spoke.

    Never make up what isn't on screen or what you don't know; say so in one sentence.
    """

    static func run(_ said: String, screen: ScreenContext.Snapshot, canWrite: Bool) async throws -> Reply {
        var prompt = "Front app: \(screen.app)\(screen.window.isEmpty ? "" : ", window \"\(screen.window)\"")\n"
        prompt += canWrite ? "The cursor is in a text box." : "There's no text box in focus, so answer (mode \"answer\")."
        if let draft = screen.draft { prompt += "\nAlready typed in the box:\n<draft>\n\(draft)\n</draft>" }
        prompt += "\n\nThe window's text:\n<screen>\n\(screen.text.isEmpty ? "(couldn't read it)" : screen.text)\n</screen>"
        prompt += "\n\nWhat they said: \(said)"

        let text: String
        if let key = Keychain.claudeKey, !Prefs.localOnly {
            let schema: [String: Any] = [
                "type": "object",
                "properties": ["mode": ["type": "string", "enum": ["write", "answer"]], "text": ["type": "string"]],
                "required": ["mode", "text"],
                "additionalProperties": false,
            ]
            text = try await Claude.send(prompt, system: system, images: screen.image.map { [$0] } ?? [], key: key,
                                         effort: "low", schema: schema, maxTokens: 6000, timeout: 60, what: "assistant")
        } else if let key = Keychain.groqKey {
            let messages = [
                ["role": "system", "content": system + "\n\nReply with one JSON object: {\"mode\": \"write\" or \"answer\", \"text\": \"...\"}"],
                ["role": "user", "content": prompt],
            ]
            text = try await Groq.chat(messages, key: key, model: Prefs.cleanupModel, maxTokens: 3000, timeout: 20, json: true)
        } else {
            throw Claude.Failure(message: "The assistant needs a Claude or Groq key")
        }
        var reply = try JSONDecoder().decode(Reply.self, from: Data(text.utf8))
        if reply.writes, !canWrite { reply = Reply(mode: "answer", text: reply.text) }
        return Reply(mode: reply.mode, text: reply.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
