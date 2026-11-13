import Foundation

/// Formatting said out loud: "new line", "new paragraph", "bullet", punctuation by name, and "send" at the end.
///
/// Groq's cleanup is told about these and judges from context ("add a new line to the file" stays as words).
/// This pass handles the text nothing cleaned (Exact tone, a few words, Apple's model, which only punctuates),
/// and after Groq it only catches a "new line" or "bullet" left standing on its own between punctuation.
nonisolated enum SpokenFormat {
    /// Every rule, for text no model formatted.
    static func apply(_ text: String) -> String { run(text, strict: false) }

    /// After Groq: only phrases standing on their own ("Hi Marco. New line. Thanks"), never inside a sentence.
    static func safetyNet(_ text: String) -> String { run(text, strict: true) }

    private static let paragraph = "new paragraph|nuovo paragrafo"
    private static let line = "new line|newline|next line|nuova riga|vai a capo"
    /// Also an ordinary phrase in Italian ("è a capo del team"), so only when it stands on its own.
    private static let lineWeak = "a capo"
    private static let bullet = "bullet point|bullet|punto elenco"
    /// Longest first, so "punto e virgola" isn't read as "virgola".
    private static let marks: [(String, String)] = [
        ("question mark|punto interrogativo", "?"),
        ("exclamation mark|exclamation point|punto esclamativo", "!"),
        ("semicolon|punto e virgola", ";"),
        ("full stop", "."),
        ("comma|virgola", ","),
        ("colon", ":"),
    ]

    /// "adding a new line character", "a missing comma": talking about it, not dictating it.
    private static let talkingAbout = "(?<!\\b(?:a|an|the|this|that|one|another|each|every|no|any|missing|extra|un|una|la|il|nuova|ogni)[ \\t])"

    private static func run(_ text: String, strict: Bool) -> String {
        var t = text
        // Standing on its own: after the start, a line break or a mark, and before a mark, a line break or the end.
        let alone = { (words: String) in "(?:^|(?<=[\\n.,;:!?]))[ \\t]*\\b(?:\(words))\\b[ \\t]*(?=[\\n.,;:!?]|$)[.,;:!?]?[ \\t]*" }
        let anywhere = { (words: String) in "[ \\t]*" + talkingAbout + "\\b(?:\(words))\\b[.,;:!?]?[ \\t]*" }

        if !strict {
            // The mark the recognizer put before it goes: "is it ready, question mark" → "is it ready?"
            for (words, mark) in marks {
                t = sub(t, "[ \\t]*[,.;:!?]?[ \\t]*" + talkingAbout + "\\b(?:\(words))\\b[.,;:!?]?", mark)
            }
        }
        t = sub(t, strict ? alone(paragraph) : anywhere(paragraph), "\n\n")
        t = sub(t, strict ? alone(line) : anywhere(line), "\n")
        t = sub(t, alone(lineWeak), "\n")
        // A bullet starts a line, so after Groq it must at least start a sentence.
        let bulletLeft = strict ? "(?:^|(?<=[\\n.!?:]))" : "(?:^|(?<=[\\n.!?:,;])|[ \\t]+)"
        t = sub(t, bulletLeft + "[ \\t]*" + talkingAbout + "\\b(?:\(bullet))\\b[.,;:]?[ \\t]*", "\n- ")
        return tidy(t)
    }

    private static func tidy(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        // "new line, bullet" makes one break, not two.
        t = t.replacingOccurrences(of: "\\n+- ", with: "\n- ", options: .regularExpression)
        // List items don't end in a full stop or a comma; "..." stays.
        t = t.replacingOccurrences(of: "(?m)^(- .*?[^.])[.,;]$", with: "$1", options: .regularExpression)
        // A list at the very start doesn't need a blank line before it.
        if t.hasPrefix("\n- ") { t.removeFirst() }
        return t
    }

    /// Replaces each match, and capitalises what follows a line break, a list dash or the end of a sentence.
    private static func sub(_ text: String, _ pattern: String, _ with: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let capsAfter = with.hasSuffix("\n") || with.hasSuffix("- ") || with == "?" || with == "!" || with == "."
        var out = ""
        var last = 0
        var cap = false
        for m in matches {
            out += capped(ns.substring(with: NSRange(location: last, length: m.range.location - last)), cap)
            out += with
            cap = capsAfter
            last = m.range.location + m.range.length
        }
        out += capped(ns.substring(from: last), cap)
        return out
    }

    private static func capped(_ s: String, _ cap: Bool) -> String {
        guard cap, let i = s.firstIndex(where: { !$0.isWhitespace }), s[i].isLowercase else { return s }
        return s.replacingCharacters(in: i...i, with: s[i].uppercased())
    }

    /// "New line, in the regex…" at the very start: the break is split off, since a model tends to drop it.
    static func leadingBreak(_ text: String) -> (lead: String, rest: String) {
        let pattern = "^\\s*\\b(?:(\(paragraph))|\(line)|a capo)\\b[.,;:!?]?\\s*"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text)
        else { return ("", text) }
        let rest = String(text[r.upperBound...])
        return (m.range(at: 1).location != NSNotFound ? "\n\n" : "\n", rest)
    }

    // MARK: Send

    /// "See you tomorrow, send." → ("See you tomorrow", true). Only the very last word, and not when it's
    /// part of the sentence ("I'll send", "te lo invia").
    static func takeSend(_ text: String) -> (text: String, send: Bool) {
        let pattern = "[ \\t]*[,;:]?[ \\t]*\\b(send|invia)\\b[.!]?\\s*$"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text)
        else { return (text, false) }
        let before = String(text[..<r.lowerBound])
        let previous = before.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).last.map(String.init)
        let partOfSentence: Set<String> = [
            "to", "will", "i'll", "i’ll", "we'll", "we’ll", "you'll", "you’ll", "can", "could", "should", "would",
            "not", "don't", "don’t", "didn't", "didn’t", "did", "i", "we", "you", "they", "he", "she", "it", "please",
            "ti", "mi", "lo", "la", "li", "gli", "le", "ci", "vi", "si", "ne", "non", "da", "per", "che",
        ]
        // "…works for you, send": a mark before it means it's said on its own, whatever comes before.
        let markBefore = text[r].contains { ",;:".contains($0) } || before.last.map { ".!?".contains($0) } == true
        if !markBefore, let previous, partOfSentence.contains(previous) { return (text, false) }
        return (before.trimmingCharacters(in: .whitespacesAndNewlines), true)
    }
}
