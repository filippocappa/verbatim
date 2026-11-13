import Accelerate
import Foundation
import os

/// Voices you've put a name on, remembered across meetings, so the next call says "Sara" instead of "Person 2".
///
/// A voice print is 256 numbers the speaker model gives for each voice; it can't be turned back into sound.
/// Prints stay on this Mac, in Application Support, and aren't in backups.
///
/// A name is learned only when it's sure: you renamed the speaker, Meet's captions named them, or the call
/// showed just one other person. Claude's guesses aren't learned, so a wrong guess can't spread.
enum VoiceBook {
    struct Entry: Codable, Identifiable {
        var name: String
        var print: [Float]
        /// How many meetings it was learned from.
        var meetings: Int
        var updated: Date
        var id: String { name }
    }

    private static let log = Logger(subsystem: AppInfo.bundleID, category: "meetings")
    /// Cosine similarity. Within one call the voices are joined at about 0.82; across calls (another mic,
    /// another day) the same person scores lower, so the bar is lower, with a clear gap to the next name.
    static let matchAt: Float = 0.65
    static let gap: Float = 0.08

    private static var folder: URL { Store.url.deletingLastPathComponent() }
    /// Test runs with -demoData keep their own, so test voices never mix with yours.
    private static var prefix: String { Store.url.lastPathComponent == "Demo.store" ? "Demo " : "" }
    private static var bookURL: URL { folder.appending(path: prefix + "Voices.json") }
    /// Each meeting's prints, by speaker label, so a rename later can still teach the voice.
    private static var printsFolder: URL { folder.appending(path: prefix + "Voice Prints") }

    // MARK: The book

    static func all() -> [Entry] {
        guard let data = try? Data(contentsOf: bookURL) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private static func save(_ entries: [Entry]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries.sorted { $0.name < $1.name }) {
            try? data.write(to: bookURL, options: .atomic)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static let changed = Notification.Name("VoiceBookChanged")

    /// Adds a meeting's print to the name, as a running average.
    static func learn(_ name: String, _ print: [Float]) {
        guard Prefs.rememberVoices, !print.isEmpty, isName(name) else { return }
        var entries = all()
        let p = unit(print)
        if let i = entries.firstIndex(where: { $0.name.lowercased() == name.lowercased() }), entries[i].print.count == p.count {
            let n = Float(min(entries[i].meetings, 9))
            entries[i].print = unit(zip(entries[i].print, p).map { ($0 * n + $1) / (n + 1) })
            entries[i].meetings += 1
            entries[i].updated = .now
        } else {
            entries.removeAll { $0.name.lowercased() == name.lowercased() }
            entries.append(Entry(name: name, print: p, meetings: 1, updated: .now))
        }
        save(entries)
        log.notice("learned a voice (\(entries.count) known)")
    }

    static func forget(_ name: String) { save(all().filter { $0.name != name }) }

    static func forgetAll() {
        save([])
        try? FileManager.default.removeItem(at: printsFolder)
    }

    /// Each print's name, when one stands out. Two voices never get the same name: the closer one wins.
    static func names(for prints: [String: [Float]]) -> [String: String] {
        guard Prefs.rememberVoices else { return [:] }
        let entries = all()
        guard !entries.isEmpty else { return [:] }
        var candidates: [(id: String, name: String, score: Float)] = []
        for (id, print) in prints {
            let scores = entries.filter { $0.print.count == print.count }
                .map { ($0.name, similarity($0.print, unit(print))) }
                .sorted { $0.1 > $1.1 }
            guard let best = scores.first, best.1 >= matchAt else { continue }
            if scores.count > 1, best.1 - scores[1].1 < gap { continue }
            candidates.append((id, best.0, best.1))
        }
        var out: [String: String] = [:]
        for c in candidates.sorted(by: { $0.score > $1.score }) where out[c.id] == nil && !out.values.contains(c.name) {
            out[c.id] = c.name
        }
        if !out.isEmpty { log.notice("recognised \(out.count) of \(prints.count) voices") }
        return out
    }

    // MARK: Each meeting's prints

    static func keep(_ prints: [String: [Float]], for meeting: URL) {
        guard Prefs.rememberVoices, !prints.isEmpty else { return }
        try? FileManager.default.createDirectory(at: printsFolder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(prints) {
            try? data.write(to: printsURL(meeting), options: .atomic)
        }
    }

    /// You renamed a speaker in a meeting: that voice is that person from now on.
    static func renamed(_ old: String, to new: String, in meeting: URL) {
        guard let data = try? Data(contentsOf: printsURL(meeting)),
              var prints = try? JSONDecoder().decode([String: [Float]].self, from: data),
              let print = prints.removeValue(forKey: old) else { return }
        learn(new, print)
        // Two voices merged into one person: keep the print it already had.
        prints[new] = prints[new] ?? print
        keep(prints, for: meeting)
    }

    private static func printsURL(_ meeting: URL) -> URL {
        printsFolder.appending(path: meeting.deletingPathExtension().lastPathComponent + ".json")
    }

    /// A person's name, not a placeholder label.
    static func isName(_ label: String) -> Bool {
        !(label.hasPrefix("Person ") && Int(label.dropFirst(7)) != nil) && !["You", "Them", "Speaker"].contains(label)
    }

    // MARK: Maths

    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        return vDSP.dot(a, b) / max(1e-9, sqrt(vDSP.sumOfSquares(a)) * sqrt(vDSP.sumOfSquares(b)))
    }

    private static func unit(_ v: [Float]) -> [Float] {
        let n = sqrt(vDSP.sumOfSquares(v))
        return n > 0 ? vDSP.divide(v, n) : v
    }
}
