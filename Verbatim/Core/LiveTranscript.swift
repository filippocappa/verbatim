import Foundation

/// What the live words show while you talk: the part that's settled, in white, and the newest words, which
/// may still change, in grey. Formatted the way the paste will be ("new line" breaks the line), with "send"
/// taken off the end and shown as ↵ instead.
nonisolated struct LiveText: Equatable {
    var settled = ""
    var guess = ""
    var send = false

    var isEmpty: Bool { settled.isEmpty && guess.isEmpty }
    /// On one line, for the pill.
    var flatSettled: String { settled.replacingOccurrences(of: "\n", with: " ") }
    var flatGuess: String { guess.replacingOccurrences(of: "\n", with: " ") }
}

/// Keeps the live words steady. Parakeet re-reads the audio since the last pause it's finished with, a few
/// times a second. A word is settled once two reads in a row agree on it and on everything before it.
/// After 8 s the stretch is closed at its latest pause: read once more on its own and kept, so a long
/// dictation never means re-reading more than a few seconds.
struct LiveTranscript {
    /// The text of everything before `end`, finished with.
    private(set) var done = ""
    /// Where the open stretch starts, in samples.
    private(set) var end = 0
    private var words: [String] = []
    private var stable = 0

    /// A new read of the open stretch.
    mutating func read(_ text: String) {
        let next = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var agree = 0
        while agree < min(next.count, words.count), Self.same(next[agree], words[agree]) { agree += 1 }
        // Once white, a word stays white even if one read wobbles; it just shows the newer spelling.
        stable = min(next.count, max(agree, stable))
        words = next
    }

    /// The open stretch up to `sample` was read in one go: it's finished with.
    mutating func close(_ text: String, at sample: Int) {
        let closed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        done = Self.join(done, closed)
        end = sample
        // The words after the pause were already on screen: keep them, white where they were, so the next read
        // can agree with them instead of starting grey again.
        let n = closed.split(whereSeparator: \.isWhitespace).count
        words = Array(words.dropFirst(n))
        stable = max(0, stable - n)
    }

    var text: LiveText {
        let settledRaw = Self.join(done, words.prefix(stable).joined(separator: " "))
        let allRaw = Self.join(settledRaw, words.dropFirst(stable).joined(separator: " "))
        let (all, send) = SpokenFormat.takeSend(SpokenFormat.apply(allRaw))
        let settled = SpokenFormat.apply(settledRaw)
        // Formatting can reach back into the settled part ("…new" + "line"), so white is only what both agree on.
        let common = all.hasPrefix(settled) ? settled : all.commonPrefix(with: settled)
        return LiveText(settled: common, guess: String(all.dropFirst(common.count)), send: send)
    }

    /// One pass of the live loop. `open` is the audio from `end` to now. Past 8 s the stretch is closed at its
    /// latest pause (never in the last second, a word may be starting there), or cut anyway at 20 s.
    /// Returns false when there was nothing new to show.
    mutating func advance(open: [Float], language: String?) async -> Bool {
        let rate = Int(AudioRecorder.sampleRate)
        if open.count >= rate * 8,
           let cut = AudioRecorder.pause(in: Array(open.dropLast(rate)), lookback: open.count - rate)
               ?? (open.count >= rate * 20 ? open.count - rate : nil) {
            let piece = Array(open[..<cut])
            if AudioRecorder.speechSeconds(piece) < 0.2 {
                close("", at: end + cut)
            } else {
                guard let heard = await Self.hear(piece, language) else { return false }
                close(heard, at: end + cut)
            }
            // Read what comes after the pause straight away, or those words would vanish for a moment.
            _ = await advance(open: Array(open[cut...]), language: language)
            return true
        }
        guard open.count >= rate / 2, AudioRecorder.speechSeconds(open) >= 0.2,
              let heard = await Self.hear(open, language),
              !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        read(heard)
        return true
    }

    private static func hear(_ audio: [Float], _ language: String?) async -> String? {
        try? await LocalSpeech.shared.transcribe(AudioRecorder.boost(audio), model: .parakeet,
                                                 language: language, prompt: nil).text
    }

    /// "Today." and "today," are the same word.
    private static func same(_ a: String, _ b: String) -> Bool {
        let key = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return key(a) == key(b)
    }

    private static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }
}
