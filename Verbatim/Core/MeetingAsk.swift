import Foundation
import os

/// "What did we decide about pricing?" across every meeting, answered by Claude with links to the meetings.
///
/// No index or embeddings: when everything fits in one request, Claude reads it all. When it doesn't, Claude
/// first reads every recap plus the lines a word search found, picks the meetings it needs, and then reads
/// those transcripts in full to answer.
enum MeetingAsk {
    struct Answer {
        /// Markdown. Links look like `meeting:3`, an index into `meetings`.
        let text: String
        let meetings: [MeetingFile]
        /// The meetings it read in full, in the order Claude picked them.
        let read: [MeetingFile]

        /// The meetings the answer links to, in the order they first come up.
        var cited: [MeetingFile] {
            let re = try? NSRegularExpression(pattern: "\\(meeting:(\\d+)\\)")
            let ns = text as NSString
            var out: [MeetingFile] = []
            for m in re?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
                if let i = Int(ns.substring(with: m.range(at: 1))), meetings.indices.contains(i), !out.contains(meetings[i]) {
                    out.append(meetings[i])
                }
            }
            return out
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private static let log = Logger(subsystem: AppInfo.bundleID, category: "meetings")
    /// About 75,000 tokens: everything goes in one request below this.
    private static var oneGo: Int {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "askOneGo") != nil { return UserDefaults.standard.integer(forKey: "askOneGo") }
        #endif
        return 300_000
    }
    /// How much of the transcripts Claude reads in the second step.
    private static let readBudget = 240_000

    static func answer(_ question: String, in meetings: [MeetingFile] = MeetingFile.all()) async throws -> Answer {
        guard let key = Keychain.claudeKey else {
            throw Failure(errorDescription: "Asking needs a Claude key. Add one in Settings → Meetings → Claude.")
        }
        guard !Prefs.localOnly else {
            throw Failure(errorDescription: "Asking sends your meetings to Anthropic, so it's off with “Only this Mac”.")
        }
        guard !meetings.isEmpty else { throw Failure(errorDescription: "There are no meetings yet.") }

        let bodies = meetings.map(body)
        var picked: [Int]
        if bodies.reduce(0, { $0 + $1.count }) <= oneGo {
            picked = Array(meetings.indices)
        } else {
            picked = try await pick(question, meetings: meetings, key: key)
        }
        // Newest first within the budget, so a long old meeting can't crowd out the rest.
        var read: [Int] = []
        var used = 0
        for i in picked where used + min(bodies[i].count, readBudget / 2) <= readBudget || read.isEmpty {
            read.append(i)
            used += min(bodies[i].count, readBudget / 2)
        }
        log.notice("ask: reading \(read.count) of \(meetings.count) meetings in full")

        let today = Date.now.formatted(date: .complete, time: .omitted)
        let full = read.map { i in
            "<meeting number=\"\(i)\" title=\"\(meetings[i].title)\" date=\"\(date(meetings[i]))\">\n\(String(bodies[i].prefix(readBudget / 2)))\n</meeting>"
        }.joined(separator: "\n\n")
        let others = meetings.indices.filter { !read.contains($0) }
        let recaps = others.isEmpty ? "" : "\n\nThe other meetings, recaps only:\n\n" + overview(meetings, only: others, question: question, budget: 60_000)
        let prompt = """
        Today is \(today). These are notes and transcripts of my meetings. "You" in a transcript is me.

        \(full)\(recaps)

        My question: \(question)
        """
        let system = """
        You answer questions about the user's meetings, from the meetings given. Be short and direct, like a \
        colleague who was there: the answer first, then only the details that matter. Use plain words, no \
        headings. Bullet points only for a list of several things.
        When something comes from a meeting, link to it right after, like [Launch plan, 3 Nov](meeting:12), using \
        the meeting's number. Say who said or decided it when the transcript shows it.
        If the meetings don't answer the question, say so in one sentence; never guess. Answer in the language of \
        the question.
        """
        let text = try await Claude.send(prompt, system: system, key: key, effort: "medium", maxTokens: 8000, what: "ask")
        return Answer(text: text.trimmingCharacters(in: .whitespacesAndNewlines), meetings: meetings, read: read.map { meetings[$0] })
    }

    /// Step one, for when there's too much to read: the recaps and the word-search hits, and Claude says which
    /// meetings to open.
    private static func pick(_ question: String, meetings: [MeetingFile], key: String) async throws -> [Int] {
        let prompt = """
        Today is \(Date.now.formatted(date: .complete, time: .omitted)). Below are my meetings, newest first: each \
        with its number, title, date, recap, and the lines of its transcript that contain words from my question.

        \(overview(meetings, only: Array(meetings.indices), question: question, budget: 280_000))

        My question: \(question)

        Which meetings' full transcripts should be read to answer it well? Up to 8, the most useful first. \
        Include a meeting when it might help, but leave out ones that clearly don't. If the question is about \
        the latest meeting or a date, pick by date.
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["meetings": ["type": "array", "items": ["type": "integer"]]],
            "required": ["meetings"],
            "additionalProperties": false,
        ]
        struct Pick: Decodable { let meetings: [Int] }
        let text = try await Claude.send(prompt, key: key, effort: "low", schema: schema, maxTokens: 4000, what: "ask pick")
        let ids = try JSONDecoder().decode(Pick.self, from: Data(text.utf8)).meetings
        var seen = Set<Int>()
        return ids.filter { meetings.indices.contains($0) && seen.insert($0).inserted }
    }

    /// Recap and matching lines for each meeting, cut to fit `budget`.
    private static func overview(_ meetings: [MeetingFile], only: [Int], question: String, budget: Int) -> String {
        let words = keywords(question)
        var out: [String] = []
        var used = 0
        for i in only {
            let m = meetings[i]
            var entry = "<meeting number=\"\(i)\" title=\"\(m.title)\" date=\"\(date(m))\">\n"
            entry += String(recap(m).prefix(1500))
            let hits = transcript(m).filter { line in
                let l = line.lowercased()
                return words.contains { l.contains($0) }
            }
            if !hits.isEmpty {
                entry += "\nLines with words from the question (\(hits.count)):\n"
                entry += hits.prefix(6).map { "- " + String($0.prefix(300)) }.joined(separator: "\n")
            }
            entry += "\n</meeting>"
            if used + entry.count > budget { break }
            used += entry.count
            out.append(entry)
        }
        return out.joined(separator: "\n\n")
    }

    // MARK: Reading the notes

    /// The notes without the title and hidden line.
    private static func body(_ m: MeetingFile) -> String {
        MeetingExport.markdown(m).components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func recap(_ m: MeetingFile) -> String {
        let text = m.text
        guard let start = text.range(of: "## Recap") else { return "" }
        let end = text.range(of: "## Transcript", range: start.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
        return text[start.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func transcript(_ m: MeetingFile) -> [String] {
        guard let start = m.text.range(of: "## Transcript") else { return [] }
        return m.text[start.upperBound...].components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func date(_ m: MeetingFile) -> String {
        m.started.formatted(date: .abbreviated, time: .shortened)
    }

    /// The words worth searching for: not the little ones, in English or Italian.
    static func keywords(_ question: String) -> [String] {
        let stop: Set<String> = [
            "the", "and", "for", "what", "when", "who", "why", "how", "did", "does", "was", "were", "are", "our",
            "about", "with", "that", "this", "from", "have", "has", "had", "you", "your", "they", "them", "said",
            "say", "tell", "any", "all", "can", "could", "would", "should", "which", "there", "last", "meeting",
            "meetings", "call", "calls", "che", "cosa", "come", "quando", "chi", "perché", "per", "con", "del",
            "della", "dei", "delle", "nel", "nella", "sul", "sulla", "abbiamo", "hanno", "detto", "una", "uno",
            "gli", "le", "il", "lo", "la", "di", "da", "in", "su", "riunione", "riunioni", "chiamata",
        ]
        let words = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var out: [String] = []
        for w in words where w.count >= 3 && !stop.contains(w) && !out.contains(w) { out.append(w) }
        return out
    }
}
