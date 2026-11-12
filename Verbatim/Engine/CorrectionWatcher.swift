import AppKit
import ApplicationServices
import os

/// After a paste, watches the same text field for a little while. If the user fixes a word
/// (e.g. selects "cloud" and types "Claude"), that fix is reported so it can go in the dictionary.
@MainActor
final class CorrectionWatcher {
    struct Fix: Equatable { let heard: String; let word: String }

    var onFixes: (([Fix]) -> Void)?
    private let log = Logger(subsystem: AppInfo.bundleID, category: "learning")

    private var timer: Timer?
    private var element: AXUIElement?
    private var pasted = ""
    private var prefix = ""
    private var suffix = ""
    private var lastRegion = ""
    private var pastedAt = 0
    private var lastChange = Date()
    private var started = Date()
    private var sawEdit = false

    /// Learns from the edit right away if there is one, instead of waiting for the quiet period.
    func flush() {
        guard element != nil else { return }
        if let el = element, let value = FocusedField.readValue(el), let current = region(in: value), Self.looksLikeOurs(current, pasted) {
            lastRegion = current
            sawEdit = Self.normalized(current) != Self.normalized(pasted)
        }
        finish()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        element = nil
    }

    /// `before` is the field as it was just before pasting (to find where our text landed).
    func watch(pasted text: String, in field: FocusedField) {
        cancel()
        guard !field.isSecure, text.split(whereSeparator: \.isWhitespace).count <= 400 else { return }
        element = field.element
        pasted = text
        started = Date()
        sawEdit = false
        let insertAt = field.selection?.location

        // Give the app a moment to apply the paste, then take anchors around our text.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, let el = self.element else { return }
            guard let value = FocusedField.readValue(el), value.count < 300_000 else {
                self.log.notice("not watching: the field's text can't be read"); self.cancel(); return
            }
            guard let range = Self.locate(text, in: value, near: insertAt) else {
                self.log.notice("not watching: pasted text not found in the field (\(value.count) chars)"); self.cancel(); return
            }
            self.log.notice("watching for fixes")
            let ns = value as NSString
            let pStart = max(0, range.location - 32)
            self.prefix = ns.substring(with: NSRange(location: pStart, length: range.location - pStart))
            let sEnd = min(ns.length, range.location + range.length + 32)
            self.suffix = ns.substring(with: NSRange(location: range.location + range.length, length: sEnd - range.location - range.length))
            self.lastRegion = ns.substring(with: range)
            self.pastedAt = range.location
            self.lastChange = Date()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }
    }

    private func poll() {
        guard element != nil else { return cancel() }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed < 120, let el = element, let value = FocusedField.readValue(el) else { return finish() }

        // Only our own sentence counts. Terminals redraw spinners, clocks and output all the time,
        // and treating that as "still editing" meant the fix was never picked up.
        guard let current = region(in: value), Self.looksLikeOurs(current, pasted) else {
            // Our text is gone from the field (sent with Enter, or the field was cleared).
            // If it had been edited, learn from its last state.
            return sawEdit ? finish() : (elapsed > 10 ? cancel() : ())
        }
        if let r = Optional(Self.find(current, in: value, near: pastedAt)), r.location != NSNotFound { pastedAt = r.location }
        if current != lastRegion {
            lastRegion = current
            lastChange = Date()
            sawEdit = Self.normalized(current) != Self.normalized(pasted)
            return
        }
        // Learn once the user has stopped editing for a few seconds, or when time is up.
        if sawEdit && Date().timeIntervalSince(lastChange) > 2 { finish() }
        else if elapsed > 90 { finish() }
    }

    private func finish() {
        defer { cancel() }
        guard sawEdit else { return log.notice("no edits seen") }
        let fixes = Self.fixes(from: pasted, to: lastRegion)
        log.notice("fixes: \(fixes.map { "\($0.heard) -> \($0.word)" }.joined(separator: ", "), privacy: .public)")
        if !fixes.isEmpty { onFixes?(fixes) }
    }

    /// After Enter the anchors can land on unrelated screen text; a fix changes a few words, not the length.
    private static func looksLikeOurs(_ region: String, _ pasted: String) -> Bool {
        let a = region.split(whereSeparator: \.isWhitespace).count, b = pasted.split(whereSeparator: \.isWhitespace).count
        return abs(a - b) <= max(3, b / 4)
    }

    private static func normalized(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Finds our pasted text inside the edited field using the text around it as anchors.
    private func region(in value: String) -> String? {
        let ns = value as NSString
        var start = 0
        if !prefix.isEmpty {
            var r = Self.find(prefix, in: value, near: pastedAt)
            if r.location == NSNotFound, prefix.count > 10 { r = Self.find(String(prefix.suffix(10)), in: value, near: pastedAt) }
            guard r.location != NSNotFound else { return nil }
            start = r.location + r.length
        }
        var end = ns.length
        if !suffix.isEmpty {
            let after = NSRange(location: start, length: ns.length - start)
            var r = Self.find(suffix, in: value, range: after, last: false)
            if r.location == NSNotFound, suffix.count > 10 { r = Self.find(String(suffix.prefix(10)), in: value, range: after, last: false) }
            guard r.location != NSNotFound else { return nil }
            end = r.location
        }
        guard end >= start else { return nil }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    private static func locate(_ text: String, in value: String, near location: Int?) -> NSRange? {
        let ns = value as NSString
        if let loc = location {
            let from = max(0, loc - 2)
            let r = find(text, in: value, range: NSRange(location: from, length: ns.length - from), last: false)
            if r.location != NSNotFound && r.location - loc < 4 { return r }
        }
        let r = find(text, in: value)
        return r.location == NSNotFound ? nil : r
    }

    /// Like `range(of:)`, but any run of whitespace matches any other. Terminals and narrow fields
    /// wrap long text onto several lines (often with indentation), so our sentence is rarely there verbatim.
    /// The match whose end is closest to `location` (where our text started last time we saw it).
    static func find(_ needle: String, in hay: String, near location: Int) -> NSRange {
        let words = needle.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty, let re = try? NSRegularExpression(pattern: words.joined(separator: "\\s+")) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let all = re.matches(in: hay, range: NSRange(location: 0, length: (hay as NSString).length))
        return all.min { abs($0.range.location + $0.range.length - location) < abs($1.range.location + $1.range.length - location) }?.range
            ?? NSRange(location: NSNotFound, length: 0)
    }

    static func find(_ needle: String, in hay: String, range: NSRange? = nil, last: Bool = true) -> NSRange {
        let words = needle.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty, let re = try? NSRegularExpression(pattern: words.joined(separator: "\\s+")) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let r = range ?? NSRange(location: 0, length: (hay as NSString).length)
        let match = last ? re.matches(in: hay, range: r).last : re.firstMatch(in: hay, range: r)
        return match?.range ?? NSRange(location: NSNotFound, length: 0)
    }

    // MARK: Diff

    struct Token { let original: String; let key: String }

    static func tokenize(_ s: String) -> [Token] {
        s.split(whereSeparator: \.isWhitespace).compactMap { part in
            let original = String(part).trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            let key = original.lowercased()
            return key.isEmpty ? nil : Token(original: original, key: key)
        }
    }

    /// Word-level diff. Keeps only small, sound-alike replacements that look like a name or term,
    /// so rewriting a whole sentence doesn't pollute the dictionary.
    static func fixes(from old: String, to new: String) -> [Fix] {
        let a = tokenize(old), b = tokenize(new)
        guard !a.isEmpty, !b.isEmpty, a.count < 600, b.count < 600 else { return [] }

        // LCS table on lowercase keys, but a case-only change still counts as an edit.
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i].original == b[j].original ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var hunks: [([Token], [Token])] = []
        var i = 0, j = 0
        var del: [Token] = [], ins: [Token] = []
        func flush() { if !del.isEmpty || !ins.isEmpty { hunks.append((del, ins)) }; del = []; ins = [] }
        while i < n || j < m {
            if i < n, j < m, a[i].original == b[j].original { flush(); i += 1; j += 1 }
            else if j < m, i == n || dp[i][j + 1] >= dp[i + 1][j] { ins.append(b[j]); j += 1 }
            else { del.append(a[i]); i += 1 }
        }
        flush()

        let replacements = hunks.filter { !$0.0.isEmpty && !$0.1.isEmpty }
        guard !replacements.isEmpty, hunks.count <= 4 else { return [] }

        var out: [Fix] = []
        for (d, ins) in replacements where d.count <= 3 && ins.count <= 3 {
            let heard = d.map(\.original).joined(separator: " ")
            let word = ins.map(\.original).joined(separator: " ")
            guard word.count >= 2, word.rangeOfCharacter(from: .letters) != nil else { continue }
            // Mishearings are about sound, not spelling ("Vani" for Bun, "cloud" for Claude), so take the better of the two.
            let h = heard.lowercased().filter(\.isLetter), w = word.lowercased().filter(\.isLetter)
            let sim = max(similarity(h, w), similarity(soundKey(h), soundKey(w)))
            let caseOnly = heard.lowercased() == word.lowercased()
            guard caseOnly || sim >= 0.4 else { continue }
            guard looksLikeTerm(word) else { continue }
            out.append(Fix(heard: heard, word: word))
        }
        return out
    }

    /// Names, brands and jargon: capitalized/mixed-case words, or words neither English nor Italian spellcheck knows.
    /// Plain fixes like "their" -> "there" are skipped.
    static func looksLikeTerm(_ word: String) -> Bool {
        if word.contains(where: { $0.isUppercase || $0.isNumber }) { return true }
        let checker = NSSpellChecker.shared
        for lang in ["en", "it"] {
            let r = checker.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            if r.location == NSNotFound { return false } // a normal word in this language
        }
        return true
    }

    /// A rough sound key: letters that sound alike are merged, vowels after the first letter dropped.
    static func soundKey(_ s: String) -> String {
        var t = s
        for (a, b) in [("ph", "f"), ("ck", "k"), ("sh", "s"), ("ch", "k"), ("qu", "k"), ("x", "ks")] { t = t.replacingOccurrences(of: a, with: b) }
        let map: [Character: Character] = ["c": "k", "q": "k", "z": "s", "v": "b", "w": "u", "y": "i"]
        let chars = t.map { map[$0] ?? $0 }
        guard let first = chars.first else { return "" }
        var out = [first]
        for c in chars.dropFirst() where !"aeiouh".contains(c) && c != out.last { out.append(c) }
        return String(out)
    }

    static func similarity(_ x: String, _ y: String) -> Double {
        let a = Array(x), b = Array(y)
        if a.isEmpty || b.isEmpty { return 0 }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[b.count]) / Double(max(a.count, b.count))
    }
}
