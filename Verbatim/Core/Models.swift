import Foundation
import SwiftData

@Model
final class Dictation {
    #Index<Dictation>([\.date])

    var date: Date
    /// What was pasted.
    var text: String
    /// What the speech model heard, before cleanup.
    var raw: String
    var words: Int
    var audioSeconds: Double
    /// Second ⌘ tap to paste.
    var latencyMs: Int
    var appName: String?
    var appBundleID: String?
    /// "groq", "apple", "parakeet" or "whisper".
    var engine: String
    /// "en", "it", ...
    var language: String?

    init(date: Date = .now, text: String, raw: String, audioSeconds: Double, latencyMs: Int,
         appName: String?, appBundleID: String?, engine: String, language: String?) {
        self.date = date
        self.text = text
        self.raw = raw
        self.words = text.split(whereSeparator: \.isWhitespace).count
        self.audioSeconds = audioSeconds
        self.latencyMs = latencyMs
        self.appName = appName
        self.appBundleID = appBundleID
        self.engine = engine
        self.language = language
    }
}

@Model
final class VocabEntry {
    var word: String
    /// Lowercased spellings the speech model produced instead of `word`.
    var heardAs: [String]
    /// Learned from a fix the user made, rather than added by hand.
    var learned: Bool
    /// Swap `heardAs` for `word` without asking the cleanup model.
    var alwaysReplace: Bool
    var added: Date

    init(word: String, heardAs: [String] = [], learned: Bool = false, alwaysReplace: Bool = false, added: Date = .now) {
        self.word = word
        self.heardAs = heardAs
        self.learned = learned
        self.alwaysReplace = alwaysReplace
        self.added = added
    }

    var hint: VocabHint { VocabHint(word: word, heardAs: heardAs) }
}

/// Say the trigger, get the text: "my email" → the full address.
@Model
final class Snippet {
    var trigger: String
    var text: String
    var added: Date
    var uses: Int

    init(trigger: String, text: String, added: Date = .now) {
        self.trigger = trigger
        self.text = text
        self.added = added
        self.uses = 0
    }
}

enum Snippets {
    static func all(_ context: ModelContext = Store.context) -> [Snippet] {
        (try? context.fetch(FetchDescriptor<Snippet>())) ?? []
    }

    /// The dictation was only the trigger ("My email."): returns the snippet as is, so cleanup can't touch it.
    static func whole(_ text: String, _ snippets: [Snippet]) -> Snippet? {
        let said = key(text)
        guard !said.isEmpty else { return nil }
        return snippets.first { key($0.trigger) == said }
    }

    /// Swaps every trigger said inside a longer dictation for its text. Longer triggers go first,
    /// so "my work email" wins over "my email".
    static func expand(_ text: String, _ snippets: [Snippet]) -> (text: String, used: [Snippet]) {
        var result = text
        var used: [Snippet] = []
        for s in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let words = s.trigger.split { !($0.isLetter || $0.isNumber) }.map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { continue }
            // Whole words only, and tolerant of the commas or capitals cleanup may have added in between.
            let pattern = "(?i)(?<![\\p{L}\\p{N}])" + words.joined(separator: "[\\s,.-]+") + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            guard re.firstMatch(in: result, range: range) != nil else { continue }
            result = re.stringByReplacingMatches(in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: s.text))
            used.append(s)
        }
        return (result, used)
    }

    /// Lowercase letters and digits only, single spaces: "My e-mail." → "my e mail".
    static func key(_ s: String) -> String {
        s.lowercased().split { !($0.isLetter || $0.isNumber) }.joined(separator: " ")
    }
}

enum Store {
    static let container: ModelContainer = {
        let dir = URL.applicationSupportDirectory.appending(path: AppInfo.bundleID, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #if DEBUG
        // Sample data for screenshots lives in its own file, never in the real library.
        let file = UserDefaults.standard.bool(forKey: "demoData") ? "Demo.store" : "Library.store"
        #else
        let file = "Library.store"
        #endif
        let config = ModelConfiguration(url: dir.appending(path: file))
        do {
            return try ModelContainer(for: Dictation.self, VocabEntry.self, Snippet.self, configurations: config)
        } catch {
            fatalError("Couldn't open the library: \(error)")
        }
    }()

    static var context: ModelContext { container.mainContext }
}

/// Dictionary operations shared by the controller and the Dictionary screen.
enum Vocabulary {
    static func all(_ context: ModelContext = Store.context) -> [VocabEntry] {
        (try? context.fetch(FetchDescriptor<VocabEntry>(sortBy: [SortDescriptor(\.added, order: .reverse)]))) ?? []
    }

    struct Change {
        let entry: VocabEntry
        let created: Bool
        let addedHeard: String?
    }

    /// Adds a word, or merges a new "heard as" spelling into an existing entry.
    @discardableResult
    static func add(word rawWord: String, heardAs: String? = nil, learned: Bool = false,
                    in context: ModelContext = Store.context) -> Change? {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return nil }
        let heard = heardAs?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let usable = heard.flatMap { $0.isEmpty || $0 == word.lowercased() ? nil : $0 }

        if let existing = all(context).first(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) {
            existing.word = word // keep the newest spelling/casing
            var added: String?
            if let h = usable, !existing.heardAs.contains(h) {
                existing.heardAs.append(h)
                added = h
            }
            try? context.save()
            return Change(entry: existing, created: false, addedHeard: added)
        }
        let e = VocabEntry(word: word, heardAs: usable.map { [$0] } ?? [], learned: learned)
        context.insert(e)
        try? context.save()
        return Change(entry: e, created: true, addedHeard: usable)
    }

    static func undo(_ change: Change, in context: ModelContext = Store.context) {
        if change.created {
            context.delete(change.entry)
        } else if let h = change.addedHeard {
            change.entry.heardAs.removeAll { $0 == h }
        }
        try? context.save()
    }

    /// Words for the speech model prompt. Whisper reads at most ~224 tokens of prompt, so keep it short.
    static func promptWords(_ entries: [VocabEntry]) -> [String] {
        var out: [String] = []
        var chars = 0
        for e in entries {
            chars += e.word.count + 2
            if chars > 600 { break }
            out.append(e.word)
        }
        return out
    }

    /// Deterministic replacements the user opted into ("always replace X with Y").
    static func applyReplacements(_ text: String, _ entries: [VocabEntry]) -> String {
        var result = text
        for e in entries where e.alwaysReplace {
            for heard in e.heardAs where !heard.isEmpty {
                let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: heard) + "\\b"
                result = result.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: e.word),
                                                     options: .regularExpression)
            }
        }
        return result
    }
}
