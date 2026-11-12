import AppKit

/// How dictated text should sound in a given app: formal in Mail, casual in Messages.
nonisolated enum Tone: String, CaseIterable, Identifiable, Sendable {
    case formal, normal, casual, veryCasual, exact, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .formal: "Formal"
        case .normal: "Normal"
        case .casual: "Casual"
        case .veryCasual: "Very casual"
        case .exact: "Exact"
        case .custom: "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .formal: "briefcase"
        case .normal: "text.alignleft"
        case .casual: "bubble.left"
        case .veryCasual: "face.smiling"
        case .exact: "waveform"
        case .custom: "pencil.line"
        }
    }

    /// The same message in each tone, written for the kind of app, so the differences are easy to spot.
    func example(_ kind: Styles.Kind) -> String {
        if self == .custom {
            return rule.map { "Follows your instructions: \($0)" } ?? "Write your own instructions with Edit tones, at the top of this page."
        }
        return switch kind {
        case .chat: example
        case .mail:
            switch self {
            case .formal: "Hi Marco, could we move the call to Thursday? I will send the deck beforehand."
            case .normal: "Hi Marco, can we move the call to Thursday? I'll send the deck before."
            case .casual: "hey Marco, can we move the call to Thursday? I'll send the deck before"
            case .veryCasual: "hi Marco, can we move the call to Thursday? i'll send the deck before"
            case .exact, .custom: "hi Marco uh can we move the call to Thursday I'll send the deck before"
            }
        case .other:
            switch self {
            case .formal: "The login page fails when the password is empty. It should display an error instead."
            case .normal: "The login page breaks when the password is empty. It should show an error."
            case .casual: "login page breaks when the password's empty, it should just show an error"
            case .veryCasual: "login page breaks w/ empty password, should just show an error"
            case .exact, .custom: "so the login page uh breaks when the password is empty it should like show an error"
            }
        }
    }

    /// One sentence, the same in every example, so the differences are easy to spot.
    var example: String {
        switch self {
        case .formal: "Are we still meeting tomorrow? I will bring the demo."
        case .normal: "Are we still on for tomorrow? I'll bring the demo."
        case .casual: "Still on for tomorrow? I'll bring the demo"
        case .veryCasual: "still on for tmrw? i'll bring the demo"
        case .exact, .custom: "um are we still on for tomorrow I'll bring the demo"
        }
    }

    /// What this tone adds to the cleanup instructions. You can change it on the Style page;
    /// an empty one adds nothing.
    var rule: String? {
        let saved = (UserDefaults.standard.dictionary(forKey: Self.rulesKey) as? [String: String])?[rawValue]
        let r = (saved ?? defaultRule ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty || self == .exact ? nil : r
    }

    var hasCustomRule: Bool {
        (UserDefaults.standard.dictionary(forKey: Self.rulesKey) as? [String: String])?[rawValue] != nil
    }

    func setRule(_ text: String?) {
        var all = UserDefaults.standard.dictionary(forKey: Self.rulesKey) as? [String: String] ?? [:]
        all[rawValue] = text
        UserDefaults.standard.set(all, forKey: Self.rulesKey)
    }

    static let rulesKey = "toneRules"

    /// The instruction each tone ships with.
    var defaultRule: String? {
        switch self {
        case .normal, .exact, .custom: nil
        case .formal:
            "For this one, write it formally, as in a work email: complete sentences, full punctuation, no slang or filler phrases (\"so\", \"like\", \"hey\" become proper wording). This overrides the rule about not making the text more formal. Keep every point the speaker made and don't add a greeting or sign-off that wasn't said. Keep the language it was spoken in: Italian stays Italian, never translate."
        case .casual:
            "For this one, write it like a chat message to a colleague, not like an email. Use contractions (I'll, it's, don't). Drop words a texter would skip at the start (\"Are we still on\" becomes \"Still on\", \"I think it's fine\" can stay). Join short sentences with commas instead of full stops, and never end with a full stop. Keep ? and !. Keep the speaker's relaxed words, and don't add any."
        case .veryCasual:
            "For this one, write it like a quick text to a friend. All lowercase, but names of people, places and products keep their capital (Marco, Milan, Slack). Contractions everywhere, drop words a texter would skip, almost no commas, no full stops at all. Keep ? and !. Short forms are fine where people use them (tmrw, pls, btw, w/). Keep the speaker's meaning, and don't add anything."
        }
    }

    /// The bits that don't need the model, so they also apply to short dictations that skip cleanup.
    func finish(_ text: String) -> String {
        guard self == .casual || self == .veryCasual else { return text }
        var t = text
        if t.hasSuffix("."), !t.hasSuffix("..") { t.removeLast() }
        if self == .veryCasual { t = Self.lowercaseStarts(t) }
        return t
    }

    /// "Hey, so I'll bring it. Ok?" → "hey, so i'll bring it. ok?" Only common words lose their capital,
    /// so a name at the start of a sentence (Marco, Milan) keeps it.
    static func lowercaseStarts(_ text: String) -> String {
        var out = ""
        var atStart = true
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            let lower = word.lowercased()
            let pronoun = ["i", "i'm", "i'll", "i've", "i'd", "i’m", "i’ll", "i’ve", "i’d"].contains(lower)
            if pronoun || (atStart && (Insights.stopWords.contains(lower) || casualStarts.contains(lower))) {
                out += lower
            } else {
                out += word
            }
            atStart = false
            word = ""
        }
        for ch in text {
            if ch.isLetter || ch == "'" || ch == "’" {
                word.append(ch)
            } else {
                flush()
                out.append(ch)
                if ".?!\n".contains(ch) { atStart = true }
            }
        }
        flush()
        return out
    }

    private static let casualStarts: Set<String> = [
        "hey", "hi", "hello", "ok", "okay", "so", "yeah", "yes", "no", "sure", "thanks", "sorry", "lol", "oh", "ah",
        "well", "also", "btw", "and", "but", "or", "if", "we", "it", "my", "is", "do", "did", "can", "should", "let's",
        "ciao", "si", "sì", "grazie", "ok", "va", "dai", "boh", "comunque", "ma", "e", "poi", "domani", "oggi", "stasera",
    ]
}

/// Which tone each app gets. Stored as bundle ID → tone in UserDefaults; apps not listed use the defaults below.
enum Styles {
    static let key = "appTones"

    static let chatApps: Set<String> = [
        "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "ru.keepcoder.Telegram", "org.telegram.desktop", "com.facebook.archon",
        "com.facebook.archon.developerID", "org.whispersystems.signal-desktop",
    ]
    static let mailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron",
        "it.bloop.airmail2", "com.mimestream.Mimestream",
    ]

    nonisolated enum Kind: Sendable { case chat, mail, other }

    static func kind(_ bundleID: String) -> Kind {
        chatApps.contains(bundleID) ? .chat : mailApps.contains(bundleID) ? .mail : .other
    }

    static func defaultTone(_ bundleID: String) -> Tone {
        if chatApps.contains(bundleID) { return .casual }
        if mailApps.contains(bundleID) { return .formal }
        return .normal
    }

    static func tone(for bundleID: String?) -> Tone {
        guard let bundleID else { return .normal }
        let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
        return saved?[bundleID].flatMap(Tone.init(rawValue:)) ?? defaultTone(bundleID)
    }

    static func set(_ tone: Tone, for bundleID: String) {
        var saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        saved[bundleID] = tone.rawValue
        UserDefaults.standard.set(saved, forKey: key)
    }
}

/// Examples written for each app by the model, so Cursor shows a commit message and Slack a message to a
/// colleague. Saved per app; cleared when the tone instructions change.
enum ToneExamples {
    static let key = "toneExamples"
    /// Apps tried this session, so a failure (offline, rate limit) doesn't retry on every redraw.
    private static var tried = Set<String>()

    static func saved(_ bundleID: String) -> [String: String]? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]])?[bundleID]
    }

    static func example(_ tone: Tone, for bundleID: String) -> String? {
        saved(bundleID)?[tone.rawValue]
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        tried.removeAll()
    }

    /// Writes examples for the apps that don't have them yet, a few apps per request.
    /// Returns true if anything new was saved.
    @discardableResult
    static func fill(_ bundleIDs: [String], name: (String) -> String) async -> Bool {
        guard let groqKey = Keychain.groqKey else { return false }
        let missing = bundleIDs.filter { saved($0) == nil && !tried.contains($0) }
        guard !missing.isEmpty else { return false }
        missing.forEach { tried.insert($0) }
        var any = false
        for start in stride(from: 0, to: missing.count, by: 8) {
            let chunk = Array(missing[start..<min(start + 8, missing.count)])
            guard let made = try? await generate(chunk.map { ($0, name($0)) }, key: groqKey) else { continue }
            var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
            for (id, tones) in made where chunk.contains(id) { all[id] = tones; any = true }
            UserDefaults.standard.set(all, forKey: key)
        }
        return any
    }

    private static func generate(_ apps: [(id: String, name: String)], key: String) async throws -> [String: [String: String]] {
        let italian = Prefs.language == "it"
        var tones: [String] = [
            "formal: \(Tone.formal.rule ?? "formal, complete sentences")",
            "normal: cleaned up with normal punctuation and capitals, the speaker's own words.",
            "casual: \(Tone.casual.rule ?? "relaxed, like a chat message")",
            "veryCasual: \(Tone.veryCasual.rule ?? "very relaxed, like a text to a friend")",
            "exact: the raw speech-to-text: all lowercase, no punctuation, with one or two fillers (um, uh, like) left in.",
        ]
        if let custom = Tone.custom.rule { tones.append("custom: \(custom)") }
        let system = """
        You write the examples for a dictation app's settings, where each app gets its own tone. For each app below, think of one short, typical thing a person would dictate into that app: a message to a colleague in a chat app, an email line in a mail app, a commit message or code comment in a code editor, a prompt in an AI chat, a note in a notes app, a search in a browser, and so on. Then write that same message in each tone, so the differences are easy to see. Same content in every tone, at most 20 words each, \(italian ? "in Italian" : "in English").

        The tones (the "For this one" instructions are what the app's cleanup follows):
        \(tones.map { "- " + $0 }.joined(separator: "\n"))

        Reply with JSON only: {"apps": [{"id": "<the app's id>", "formal": "...", "normal": "...", "casual": "...", "veryCasual": "...", "exact": "..."\(Tone.custom.rule == nil ? "" : ", \"custom\": \"...\"")}]}
        """
        let list = apps.map { "- id: \($0.id), name: \($0.name)" }.joined(separator: "\n")
        let json = try await Groq.chat([["role": "system", "content": system], ["role": "user", "content": "Apps:\n" + list]],
                                       key: key, model: Prefs.cleanupModel, maxTokens: 400 * apps.count + 400,
                                       timeout: 30, json: true)
        struct R: Decodable { let apps: [[String: String]] }
        guard let data = json.data(using: .utf8) else { return [:] }
        let r = try JSONDecoder().decode(R.self, from: data)
        var out: [String: [String: String]] = [:]
        for app in r.apps {
            guard let id = app["id"] else { continue }
            var tones = app
            tones["id"] = nil
            // Only keep a set that covers every tone, or the slider would mix tailored and generic lines.
            guard Tone.allCases.filter({ $0 != .custom }).allSatisfy({ !(tones[$0.rawValue] ?? "").isEmpty }) else { continue }
            out[id] = tones
        }
        return out
    }
}
