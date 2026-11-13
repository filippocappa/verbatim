import AppKit
import os

/// Meeting notes: while the call runs, both sides are transcribed in ~25 s pieces and written to a Markdown
/// file in ~/Documents/Verbatim Meetings. When the call ends, the voices on the other side are told apart
/// and a recap goes on top. No audio is kept.
@MainActor
final class MeetingNotes {
    struct Line {
        let at: Double
        let end: Double
        let them: Bool
        var text: String
        /// "Person 1", "Person 2"… once the voices on the other side are told apart. nil is "Them".
        var speaker: String?
        /// Which voice said it, when the voices were told apart.
        var voice: String?
        var label: String { them ? speaker ?? "Them" : "You" }
    }

    let file: URL

    static var folder: URL {
        #if DEBUG
        if let f = UserDefaults.standard.string(forKey: "meetingsFolder") { return URL(fileURLWithPath: f, isDirectory: true) }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Verbatim Meetings", isDirectory: true)
    }
    private let title: String
    private let started: Date
    private(set) var lines: [Line] = []
    private var language: String?
    private let log = Logger(subsystem: AppInfo.bundleID, category: "meetings")

    private let bundleID: String
    private let service: String?
    /// Names spelled right: the people in the call (from the call window and Calendar) and the Dictionary.
    /// They help Parakeet, Groq and Claude get names right.
    private(set) var knownNames: [String]
    /// The people invited to the call, from Calendar.
    private let invited: [String]
    /// The other people seen on the call's video tiles. With just one, "Them" becomes their name.
    private(set) var seen: [String] = []
    /// When each person's captions moved in Meet (seconds from the start): they were talking then.
    private var captioned: [(at: Double, name: String)] = []
    /// Each voice's print (see VoiceBook), by the voice's id.
    private var prints: [String: [Float]] = [:]
    /// Names that came from something sure (captions, the voice book, a call of two), not Claude's guess.
    /// Only these teach the voice book.
    private var sureNames: Set<String> = []

    /// The `service` of a meeting made from a recording instead of a call.
    static let recordingService = "recording"
    /// How long the recording is; for a call it's worked out from when the notes were last written.
    private let length: Double?

    init(title: String, bundleID: String, service: String?, started: Date, people: [String] = [], length: Double? = nil) {
        self.title = title
        self.length = length
        invited = people
        var names = people
        for w in Vocabulary.all().map(\.word) where !names.contains(w) { names.append(w) }
        knownNames = names
        self.bundleID = bundleID
        self.service = service
        self.started = started
        let folder = Self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = started.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits)",
                                                timeZone: .current, calendar: .current))
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        file = folder.appendingPathComponent("\(stamp) \(safe).md")
        write(recap: nil)
        if LocalModels.shared.state(.parakeet) == .ready {
            Task { [names] in await LocalSpeech.shared.listen(for: names) }
        }
    }

    /// People read from the call window as they show up. New names go to Parakeet straight away.
    func met(_ people: [String]) {
        let new = people.filter { !seen.contains($0) }
        guard !new.isEmpty else { return }
        seen += new
        knownNames = new.filter { !knownNames.contains($0) } + knownNames
        log.notice("people on the call: \(self.seen.count)")
        if LocalModels.shared.state(.parakeet) == .ready {
            Task { [knownNames] in await LocalSpeech.shared.listen(for: knownNames) }
        }
    }

    /// Meet's captions showed `name` saying something new, `at` seconds into the call.
    func heard(_ name: String, at: Double) {
        guard let name = CallPeople.clean(name) else { return }
        captioned.append((at, name))
        met([name])
    }

    // MARK: Transcribing a piece

    /// One piece of one side. `at` is seconds from the start of the call.
    func transcribe(_ samples: [Float], at: Double, them: Bool) async {
        let speech = AudioRecorder.speechSeconds(samples)
        guard speech >= 0.8 else { return }
        let audio = AudioRecorder.boost(samples)
        var text: String?
        var segments: [Groq.Segment] = []
        let local = LocalModels.shared.active
        // Parakeet first: on recorded meetings (Nov 2026) it got more words right than Groq's Whisper
        // (12–16% wrong against 16–28%), about 5 times faster, and nothing leaves the Mac.
        let parakeet = LocalModels.shared.state(.parakeet) == .ready
        if parakeet {
            do {
                let t = try await LocalSpeech.shared.transcribe(audio, model: .parakeet, language: nil, prompt: nil,
                                                                timed: true, names: true)
                text = t.text
                segments = t.segments
                if let l = t.language { language = l }
            } catch {
                log.error("meeting piece failed on Parakeet: \(error.localizedDescription, privacy: .public)")
            }
        }
        if text == nil, let key = Keychain.groqKey, !(Prefs.localOnly && local != nil) {
            let up = Groq.upload(audio)
            // On a piece that's nearly silent, Whisper reads the prompt back, so only send it when there's real talk.
            var words: [String] = []
            if speech >= 3 {
                var chars = 0
                for w in knownNames {
                    chars += w.count + 2
                    if chars > 600 { break }
                    words.append(w)
                }
            }
            do {
                var t = try await Groq.transcribe(wav: up.data, key: key, prompt: words.joined(separator: ", "),
                                                  language: nil, filename: up.filename, timeout: 30)
                // Sometimes Whisper answers a whole piece with a few Dictionary words ("SaaS, Pia, Pia") and drops
                // the speech. Tested on real calls (Nov 2026): about 1 piece in 10. Far too few words for the talking
                // means that happened, so ask again without the words and keep the fuller answer.
                if !words.isEmpty, Double(t.text.split(separator: " ").count) < speech * 1.5,
                   let plain = try? await Groq.transcribe(wav: up.data, key: key, prompt: nil, language: nil,
                                                          filename: up.filename, timeout: 30),
                   plain.text.split(separator: " ").count > t.text.split(separator: " ").count {
                    t = plain
                }
                text = t.text
                segments = t.segments
                if let l = t.language { language = l }
            } catch {
                log.error("meeting piece failed on Groq: \(error.localizedDescription, privacy: .public)")
            }
        }
        if text == nil, let local, !(parakeet && local == .parakeet) {
            do {
                let t = try await LocalSpeech.shared.transcribe(audio, model: local, language: nil, prompt: nil, timed: true)
                text = t.text
                segments = t.segments
            } catch {
                log.error("meeting piece failed on \(local.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if text == nil {
            let lang = language.map { $0 == "it" ? "it-IT" : "en-US" } ?? (Prefs.language == "auto" ? Prefs.offlineLanguage : Prefs.language)
            text = try? await AppleTranscriber.transcribe(samples: audio, languageCode: lang, vocabulary: [])
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !Cleanup.isHallucination(t) else { return }
        let length = Double(samples.count) / AudioRecorder.sampleRate
        let timed = segments.filter { !$0.text.isEmpty && !Cleanup.isHallucination($0.text) }
        if timed.isEmpty {
            lines.append(Line(at: at, end: at + length, them: them, text: t))
        } else {
            // Sentence by sentence, so the two sides interleave and each sentence can get its own voice.
            lines += timed.map { Line(at: at + $0.start, end: at + min($0.end, length), them: them, text: $0.text) }
        }
        write(recap: nil)
    }

    // MARK: Voices

    /// Gives each "Them" sentence the voice that talked most during it: Person 1, Person 2… in the order
    /// they first speak. With only one voice it stays "Them".
    func tellVoicesApart(_ file: URL) async {
        guard lines.contains(where: \.them) else { return }
        let turns: [Voices.Turn]
        do { (turns, prints) = try await Voices.shared.turns(in: file) } catch {
            log.error("couldn't tell the voices apart: \(error.localizedDescription, privacy: .public)")
            return
        }
        var who: [Int: String] = [:]
        for (i, line) in lines.enumerated() where line.them {
            var overlap: [String: Double] = [:]
            for t in turns where t.end > line.at && t.start < line.end {
                overlap[t.speaker, default: 0] += min(t.end, line.end) - max(t.start, line.at)
            }
            if let best = overlap.max(by: { $0.value < $1.value })?.key {
                who[i] = best
            } else if let near = turns.min(by: { distance($0, line) < distance($1, line) }), distance(near, line) < 3 {
                // A short sentence can fall just outside every turn ("Hi both."): the closest voice said it.
                who[i] = near.speaker
            }
        }
        // Voices met in earlier meetings get their name; the rest are numbered in the order they first speak.
        let known = VoiceBook.names(for: prints.filter { who.values.contains($0.key) })
        sureNames.formUnion(known.values)
        var names = known
        var numbered = 0
        for i in who.keys.sorted(by: { lines[$0].at < lines[$1].at }) where names[who[i]!] == nil {
            numbered += 1
            names[who[i]!] = "Person \(numbered)"
        }
        for (i, id) in who { lines[i].voice = id }
        guard names.count > 1 || !known.isEmpty else { return }
        for (i, id) in who { lines[i].speaker = names[id] }
        write(recap: nil)
    }

    /// With Meet's captions on, each "Them" sentence gets the name of whoever's captions moved while it
    /// was said. Captions run about a second behind the voice. A sentence with no captions gets the name
    /// its voice had most often elsewhere.
    func nameFromCaptions() {
        guard !captioned.isEmpty else { return }
        var byLine: [Int: String] = [:]
        var byVoice: [String: [String: Int]] = [:]
        for (i, line) in lines.enumerated() where line.them {
            var count: [String: Int] = [:]
            // A caption moving at c was spoken about a second before.
            for c in captioned where c.at >= line.at + 1 && c.at <= line.end + 1.5 { count[c.name, default: 0] += 1 }
            guard let best = count.max(by: { $0.value < $1.value }) else { continue }
            byLine[i] = best.key
            if let v = line.voice { byVoice[v, default: [:]][best.key, default: 0] += best.value }
        }
        var voiceName: [String: String] = [:]
        for (v, count) in byVoice {
            let total = count.values.reduce(0, +)
            if let best = count.max(by: { $0.value < $1.value }), Double(best.value) >= 0.6 * Double(total) { voiceName[v] = best.key }
        }
        var named = 0
        for i in lines.indices where lines[i].them {
            if let name = byLine[i] ?? lines[i].voice.flatMap({ voiceName[$0] }) {
                lines[i].speaker = name
                sureNames.insert(name)
                named += 1
            }
        }
        log.notice("captions named \(named) of \(self.lines.filter(\.them).count) sentences")
        if named > 0 { write(recap: nil) }
    }

    /// Lines the voices didn't put a name on get this one, if no line has a name yet.
    func nameUnlabelled(_ label: String) {
        guard !lines.contains(where: { $0.speaker != nil }) else { return }
        for i in lines.indices where lines[i].them { lines[i].speaker = label }
        write(recap: nil)
    }

    /// Only one person seen on the call, and the voices weren't split: "Them" is that person.
    func nameThem() {
        guard seen.count == 1, let name = seen.first, lines.contains(where: \.them),
              !lines.contains(where: { $0.speaker != nil }) else { return }
        for i in lines.indices where lines[i].them { lines[i].speaker = name }
        sureNames.insert(name)
        write(recap: nil)
    }

    /// Keeps each voice's print with the meeting (so renaming it later teaches the voice book), and learns the
    /// voices whose name is sure. A voice must have spoken 20 s or more, and nearly all of it under one name.
    func rememberVoices() {
        guard Prefs.rememberVoices, !prints.isEmpty else { return }
        var byVoice: [String: [String: Double]] = [:]
        for l in lines where l.them {
            if let v = l.voice { byVoice[v, default: [:]][l.label, default: 0] += l.end - l.at }
        }
        var keep: [String: [Float]] = [:]
        var learned = 0
        for (id, labels) in byVoice {
            guard let print = prints[id], let best = labels.max(by: { $0.value < $1.value }) else { continue }
            let total = labels.values.reduce(0, +)
            guard best.value >= 0.8 * total, keep[best.key] == nil else { continue }
            keep[best.key] = print
            if sureNames.contains(best.key), best.value >= 20 {
                VoiceBook.learn(best.key, print)
                learned += 1
            }
        }
        VoiceBook.keep(keep, for: file)
        log.notice("kept \(keep.count) voice prints, learned \(learned)")
    }

    private func distance(_ t: Voices.Turn, _ line: Line) -> Double {
        max(0, max(t.start - line.end, line.at - t.end))
    }

    // MARK: Recap

    /// Writes the recap on top of the transcript, with Groq or, for "Only this Mac" or when Groq fails,
    /// with Apple Intelligence on this Mac.
    func finish() async -> Bool {
        let transcript = plainTranscript()
        guard !transcript.isEmpty else { write(recap: "_Nothing was said, or the call couldn't be heard._"); return false }
        // A few words aren't a meeting; a recap of them reads like nonsense.
        if transcript.split(whereSeparator: \.isWhitespace).count < 40 {
            write(recap: "_Too short for a recap. The transcript is below._")
            return true
        }
        await review()
        rememberVoices()
        let key = Keychain.groqKey
        var failure: Error?
        if let key, !(Prefs.localOnly && MacModel.isAvailable) {
            do {
                write(recap: try await groqRecap(transcript, key: key))
                return true
            } catch {
                log.error("recap failed on Groq: \(error.localizedDescription, privacy: .public)")
                failure = error
            }
        }
        if MacModel.isAvailable {
            do {
                let started = Date()
                let people = paragraphs.reduce(into: [String]()) { if !$0.contains($1.label) { $0.append($1.label) } }
                write(recap: try await MacModel.recap(transcript, people: people))
                log.notice("recap on this Mac in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
                return true
            } catch {
                log.error("recap failed on this Mac: \(error.localizedDescription, privacy: .public)")
                failure = error
            }
        }
        let why = failure?.localizedDescription ?? "add a Groq key or turn on Apple Intelligence"
        write(recap: "_The recap couldn't be written (\(why)). The transcript is below._")
        return false
    }

    // MARK: Names

    /// Claude reads the whole transcript, fixes misheard names and says who "Person 1", "Person 2"… are
    /// when the transcript makes it clear. Before the recap is written.
    /// Without a Claude key, with "Only this Mac", or if it fails, the transcript stays as it was.
    @discardableResult
    func review() async -> Claude.Review? {
        guard let key = Keychain.claudeKey, !Prefs.localOnly, !lines.isEmpty else { return nil }
        // Voices still without a name: "Person 1"… (captions or a call of two may have named them already).
        var labels: [String] = []
        for l in lines where l.them {
            if let s = l.speaker, s.hasPrefix("Person "), !labels.contains(s) { labels.append(s) }
        }
        let people = seen + invited.filter { !seen.contains($0) }
        do {
            let review = try await Claude.review(transcript: plainTranscript(), title: title, names: knownNames,
                                                 labels: labels, people: people, key: key)
            for s in review.speakers {
                for i in lines.indices where lines[i].them && lines[i].speaker == s.label { lines[i].speaker = s.name }
            }
            for i in lines.indices { lines[i].text = Claude.apply(review.fixes, to: lines[i].text) }
            if !review.fixes.isEmpty || !review.speakers.isEmpty { write(recap: nil) }
            log.notice("claude fixed \(review.fixes.count) names, named \(review.speakers.count) of \(labels.count) voices")
            return review
        } catch {
            log.error("claude review failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Long calls are summarised in parts first, waiting a minute between parts to stay under Groq's per-minute token cap.
    private func groqRecap(_ transcript: String, key: String) async throws -> String {
        let model = Prefs.cleanupModel
        var parts: [String] = []
        var current = ""
        for line in transcript.split(separator: "\n") {
            if current.count + line.count > 14_000 { parts.append(current); current = "" }
            current += line + "\n"
        }
        if !current.isEmpty { parts.append(current) }

        var source = transcript
        if parts.count > 1 {
            var notes: [String] = []
            for (i, p) in parts.enumerated() {
                if i > 0 { try await Task.sleep(for: .seconds(62)) }
                notes.append(try await Groq.chat([
                    ["role": "system", "content": "You take notes on part of a meeting transcript. Write dense bullet points of everything discussed, decided and assigned, with who said it. Same language as the transcript. No preamble."],
                    ["role": "user", "content": p],
                ], key: key, model: model, maxTokens: 1500, timeout: 60))
            }
            source = notes.enumerated().map { "Part \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n")
            try await Task.sleep(for: .seconds(62))
        }
        let recap = try await Groq.chat([
            ["role": "system", "content": """
            You write the recap of a meeting from its transcript (or from notes on its parts). "You" is the person who \
            recorded it. Everyone else is "Them", or "Person 1", "Person 2" and so on when their voices were told apart; \
            use those labels for who said or will do what. Write in the meeting's language, in Markdown, with exactly these \
            sections, leaving out any that would be empty:
            ### Summary
            3 to 6 bullet points.
            ### Decisions
            ### Action items
            - [ ] who: what
            ### Open questions
            Be specific and short. Don't invent anything that isn't in the text. No preamble.
            """],
            ["role": "user", "content": source],
        ], key: key, model: model, maxTokens: 2000, timeout: 90)
        return recap.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: File

    private func stamp(_ s: Double) -> String {
        let s = Int(s)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Without headphones the mic also hears the others. Drop a "You" sentence that mostly repeats what
    /// the other side said around the same moment.
    private var cleanLines: [Line] {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: .alphanumerics.inverted).filter { $0.count > 2 })
        }
        let them = lines.filter(\.them)
        return lines.filter { line in
            guard !line.them else { return true }
            let mine = words(line.text)
            guard mine.count >= 3 else { return true }
            // Their words from a few seconds either side: one of their sentences may be split differently from ours.
            let near = them.filter { $0.end > line.at - 12 && $0.at < line.end + 12 }
                .reduce(into: Set<String>()) { $0.formUnion(words($1.text)) }
            return Double(mine.intersection(near).count) / Double(mine.count) <= 0.7
        }
        .sorted { $0.at < $1.at }
    }

    /// Back-to-back sentences from the same person, joined into one paragraph of up to a minute.
    private var paragraphs: [(at: Double, label: String, text: String)] {
        var out: [(at: Double, label: String, text: String)] = []
        for line in cleanLines {
            if let last = out.last, last.label == line.label, line.at - last.at < 60 {
                out[out.count - 1].text += " " + line.text
            } else {
                out.append((line.at, line.label, line.text))
            }
        }
        return out
    }

    private func plainTranscript() -> String {
        paragraphs.map { "[\(stamp($0.at))] \($0.label): \($0.text)" }.joined(separator: "\n")
    }

    private var recapText: String?

    private func write(recap: String?) {
        if let recap { recapText = recap }
        let when = started.formatted(date: .complete, time: .shortened)
        var md = "# \(title)\n\n<!-- verbatim app=\(bundleID) service=\(service ?? "") started=\(Int(started.timeIntervalSince1970))\(length.map { " length=\(Int($0))" } ?? "") -->\n\n\(when)\n\n"
        md += "## Recap\n\n" + (recapText ?? "_Written when the call ends._") + "\n\n"
        md += "## Transcript\n\n"
        md += paragraphs.map { "**\(stamp($0.at)) \($0.label):** \($0.text)" }.joined(separator: "\n\n")
        md += "\n"
        try? md.write(to: file, atomically: true, encoding: .utf8)
    }
}
