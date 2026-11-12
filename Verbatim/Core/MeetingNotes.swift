import AppKit
import os

/// Quick version of meeting notes (before the Meetings page exists): while the call runs, both sides are
/// transcribed in ~25 s pieces and written to a Markdown file in ~/Documents/Verbatim Meetings.
/// When the call ends, a recap goes on top. No audio is kept.
@MainActor
final class MeetingNotes {
    struct Line { let at: Double; let them: Bool; let text: String }

    let file: URL

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Verbatim Meetings", isDirectory: true)
    }
    private let title: String
    private let started: Date
    private(set) var lines: [Line] = []
    private var language: String?
    private let log = Logger(subsystem: AppInfo.bundleID, category: "meetings")

    private let bundleID: String
    private let service: String?

    init(title: String, bundleID: String, service: String?, started: Date) {
        self.title = title
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
    }

    // MARK: Transcribing a piece

    /// One piece of one side. `at` is seconds from the start of the call.
    func transcribe(_ samples: [Float], at: Double, them: Bool) async {
        let speech = AudioRecorder.speechSeconds(samples)
        guard speech >= 0.8 else { return }
        let audio = AudioRecorder.boost(samples)
        var text: String?
        if let key = Keychain.groqKey {
            let up = Groq.upload(audio)
            // On a piece that's nearly silent, Whisper reads the prompt back, so only send it when there's real talk.
            let words = speech >= 3 ? Vocabulary.promptWords(Vocabulary.all()) : []
            do {
                let t = try await Groq.transcribe(wav: up.data, key: key, prompt: words.joined(separator: ", "),
                                                  language: nil, filename: up.filename, timeout: 30)
                text = t.text
                if let l = t.language { language = l }
            } catch {
                log.error("meeting piece failed on Groq: \(error.localizedDescription, privacy: .public)")
            }
        }
        if text == nil {
            let lang = language.map { $0 == "it" ? "it-IT" : "en-US" } ?? (Prefs.language == "auto" ? Prefs.offlineLanguage : Prefs.language)
            text = try? await AppleTranscriber.transcribe(samples: audio, languageCode: lang, vocabulary: [])
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !Cleanup.isHallucination(t) else { return }
        lines.append(Line(at: at, them: them, text: t))
        write(recap: nil)
    }

    // MARK: Recap

    /// Writes the recap on top of the transcript. Long calls are summarised in parts first, waiting a minute
    /// between parts to stay under Groq's per-minute token cap.
    func finish() async -> Bool {
        let transcript = plainTranscript()
        guard !transcript.isEmpty else { write(recap: "_Nothing was said, or the call couldn't be heard._"); return false }
        // A few words aren't a meeting; a recap of them reads like nonsense.
        if transcript.split(whereSeparator: \.isWhitespace).count < 40 {
            write(recap: "_Too short for a recap. The transcript is below._")
            return true
        }
        guard let key = Keychain.groqKey else { return false }
        let model = Prefs.cleanupModel
        var parts: [String] = []
        var current = ""
        for line in transcript.split(separator: "\n") {
            if current.count + line.count > 14_000 { parts.append(current); current = "" }
            current += line + "\n"
        }
        if !current.isEmpty { parts.append(current) }

        do {
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
                recorded it; "Them" is everyone else on the call. Write in the meeting's language, in Markdown, with exactly these \
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
            write(recap: recap.trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        } catch {
            log.error("recap failed: \(error.localizedDescription, privacy: .public)")
            write(recap: "_The recap couldn't be written (\(error.localizedDescription)). The transcript is below._")
            return false
        }
    }

    // MARK: File

    private func stamp(_ s: Double) -> String {
        let s = Int(s)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Without headphones the mic also hears the others. Drop a "You" line that mostly repeats a "Them" line from the same moment.
    private var cleanLines: [Line] {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: .alphanumerics.inverted).filter { $0.count > 2 })
        }
        let them = lines.filter(\.them)
        return lines.filter { line in
            guard !line.them else { return true }
            let mine = words(line.text)
            guard mine.count >= 3 else { return true }
            return !them.contains { t in
                abs(t.at - line.at) < 40 && Double(mine.intersection(words(t.text)).count) / Double(mine.count) > 0.6
            }
        }
        .sorted { $0.at < $1.at }
    }

    private func plainTranscript() -> String {
        cleanLines.map { "[\(stamp($0.at))] \($0.them ? "Them" : "You"): \($0.text)" }.joined(separator: "\n")
    }

    private var recapText: String?

    private func write(recap: String?) {
        if let recap { recapText = recap }
        let when = started.formatted(date: .complete, time: .shortened)
        var md = "# \(title)\n\n<!-- verbatim app=\(bundleID) service=\(service ?? "") started=\(Int(started.timeIntervalSince1970)) -->\n\n\(when)\n\n"
        md += "## Recap\n\n" + (recapText ?? "_Written when the call ends._") + "\n\n"
        md += "## Transcript\n\n"
        md += cleanLines.map { "**\(stamp($0.at)) \($0.them ? "Them" : "You"):** \($0.text)" }.joined(separator: "\n\n")
        md += "\n"
        try? md.write(to: file, atomically: true, encoding: .utf8)
    }
}
