import AppKit
import ApplicationServices

/// Command mode (⌥⌥): rewrite the selected text, or with nothing selected, open an app or a site, or search.
enum Commands {
    // MARK: Selection

    /// The selected text, read through Accessibility. "" means the app answered and nothing is selected;
    /// nil means the app doesn't say, so try ⌘C.
    static func selectionViaAccessibility(_ field: FocusedField?) -> String? {
        guard let field else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field.element, kAXSelectedTextAttribute as CFString, &v) == .success,
              let s = v as? String else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : s
    }

    /// Whether pasting over the selection will actually replace it. Text selected on a web page can be
    /// read but not edited, and ⌘V there would quietly do nothing.
    static func isEditable(_ field: FocusedField) -> Bool {
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(field.element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue { return true }
        if AXUIElementIsAttributeSettable(field.element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue { return true }
        return false
    }

    /// Apps that don't expose the selection (most web pages, some Electron apps) get a ⌘C, and the
    /// clipboard is put back right after. nil when nothing was selected.
    static func copySelection() async -> String? {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            var any = false
            for type in item.types { if let d = item.data(forType: type) { copy.setData(d, forType: type); any = true } }
            return any ? copy : nil
        }
        let before = pb.changeCount
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true) // C
        let up = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(25))
            if pb.changeCount != before { break }
        }
        guard pb.changeCount != before else { return nil } // nothing was selected
        let text = pb.string(forType: .string)
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    // MARK: Rewrite

    static let rewritePrompt = """
    You edit text for the user. You get a piece of text and a spoken instruction, in English or Italian. Apply the instruction to the text and reply with the result only: no quotes, no tags, no explanation.
    - Keep the text's language unless the instruction asks for a translation.
    - Keep line breaks, lists and formatting unless the instruction asks to change them.
    - If the instruction is a question about the text, reply with the answer only.
    """

    static func rewrite(_ text: String, instruction: String, key: String) async throws -> String {
        let saved = UserCommands.promptLines()
        let system = saved.isEmpty ? rewritePrompt : rewritePrompt + """

        The user has saved commands. If the instruction is one of these names, or sounds like one, follow the saved instruction instead (plus anything said after the name):
        \(saved)
        """
        let messages = [
            ["role": "system", "content": system],
            ["role": "user", "content": "<text>\n\(text)\n</text>\n<instruction>\n\(instruction)\n</instruction>"],
        ]
        var out = try await Groq.chat(messages, key: key, model: Prefs.cleanupModel,
                                      maxTokens: text.count + 1200, timeout: 20)
        out = out.replacingOccurrences(of: "<text>", with: "").replacingOccurrences(of: "</text>", with: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Actions

    enum Action: Equatable {
        case custom(name: String, extra: String)
        case open(target: String, kind: String, domain: String?)
        case search(site: String, query: String, domain: String?)
        case none
    }

    static let actionPrompt = """
    You turn a spoken command for a Mac into one action. The command is in English or Italian and came from speech-to-text, so names may be misspelled: fix them ("you tube" is YouTube, "get hub" is GitHub). Reply with one JSON object only.

    {"action": "open", "target": "<name>", "kind": "app" or "site", "domain": "<its website's domain, also for apps that have one (Slack: slack.com), else empty>"}
    {"action": "search", "site": "<where to search, lowercase, e.g. google, youtube, amazon, github, maps>", "query": "<what to search, in the language spoken>", "domain": "<the site's domain>"}
    {"action": "none"}

    - "open X", "go to X", "apri X", "vai su X": open. Use kind "site" for websites and web services (YouTube, Gmail, Google Docs, Reddit) and kind "app" for Mac apps (Slack, Notes, Xcode, Spotify, Finder).
    - "search X on Y", "look up X on Y", "play X on YouTube", "cerca X su Y": search on Y. "google X", or "search X" with no site: search on google.
    - A question with no other command ("what's the weather in Milan"): search on google with the question as the query.
    - Anything else (write, delete, send, change settings): {"action": "none"}.
    """

    static func parse(_ command: String, key: String) async throws -> Action {
        let messages = [
            ["role": "system", "content": actionPrompt + UserSites.promptLine() + customLine()],
            ["role": "user", "content": "open you tube"],
            ["role": "assistant", "content": #"{"action": "open", "target": "YouTube", "kind": "site", "domain": "youtube.com"}"#],
            ["role": "user", "content": "cerca ricetta carbonara su youtube"],
            ["role": "assistant", "content": #"{"action": "search", "site": "youtube", "query": "ricetta carbonara", "domain": "youtube.com"}"#],
            ["role": "user", "content": command],
        ]
        let json = try await Groq.chat(messages, key: key, model: Prefs.cleanupModel, maxTokens: 400, timeout: 8, json: true)
        struct R: Decodable { let action: String; let name: String?; let extra: String?; let target: String?; let kind: String?; let site: String?; let query: String?; let domain: String? }
        guard let data = json.data(using: .utf8), let r = try? JSONDecoder().decode(R.self, from: data) else { return .none }
        let domain = r.domain.flatMap { cleanDomain($0) }
        switch r.action {
        case "custom":
            guard let n = r.name, UserCommands.find(n) != nil else { return .none }
            return .custom(name: n, extra: r.extra ?? "")
        case "open":
            guard let t = r.target?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return .none }
            return .open(target: t, kind: r.kind ?? "app", domain: domain)
        case "search":
            guard let q = r.query?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return .none }
            return .search(site: (r.site ?? "google").lowercased(), query: q, domain: domain)
        default:
            return .none
        }
    }

    private static func customLine() -> String {
        let saved = UserCommands.promptLines()
        guard !saved.isEmpty else { return "" }
        return """

        - The user's own saved commands. If the command is one of these names, or sounds like one, reply {"action": "custom", "name": "<the saved name, exactly>", "extra": "<anything said after the name>"}:
        \(saved)
        """
    }

    /// Runs the action. Returns what to show in the pill, or nil if it couldn't.
    static func perform(_ action: Action) -> (title: String, detail: String?)? {
        switch action {
        case .none, .custom:
            return nil

        case let .open(target, kind, domain):
            if let mine = UserSites.find(target), let url = mine.openURL {
                NSWorkspace.shared.open(url)
                return ("Opened \(mine.name)", url.host())
            }
            // An installed app with exactly that name wins: "open Slack" means the app, not slack.com.
            if let app = Apps.find(target, exactOnly: true) ?? (kind == "app" ? Apps.find(target, exactOnly: false) : nil) {
                NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
                return ("Opened \(app.name)", nil)
            }
            if let url = siteURL(target, domain: domain) {
                NSWorkspace.shared.open(url)
                return ("Opened \(target)", url.host())
            }
            return nil

        case let .search(site, query, domain):
            guard let url = searchURL(site: site, query: query, domain: domain) else { return nil }
            NSWorkspace.shared.open(url)
            let name = UserSites.find(site)?.name
                ?? (site == "google" ? "Google" : (knownSearch[site] != nil ? site.capitalized : domain ?? site))
            return ("Searched \(name)", query)
        }
    }

    // MARK: URLs

    private static let knownSites: [String: String] = [
        "youtube": "youtube.com", "google": "google.com", "gmail": "mail.google.com", "google docs": "docs.google.com",
        "google drive": "drive.google.com", "google calendar": "calendar.google.com", "google maps": "maps.google.com",
        "maps": "maps.google.com", "github": "github.com", "reddit": "reddit.com", "x": "x.com", "twitter": "x.com",
        "linkedin": "linkedin.com", "instagram": "instagram.com", "facebook": "facebook.com", "netflix": "netflix.com",
        "amazon": "amazon.it", "wikipedia": "wikipedia.org", "chatgpt": "chatgpt.com", "claude": "claude.ai",
        "perplexity": "perplexity.ai", "notion": "notion.so", "figma": "figma.com", "vercel": "vercel.com",
        "supabase": "supabase.com", "translate": "translate.google.com", "google translate": "translate.google.com",
    ]

    /// Search URL templates; %@ is the query.
    /// The sites search works on without setting anything up, for the Commands page.
    static let searchableSites = ["Google", "YouTube", "Amazon", "GitHub", "Reddit", "Wikipedia", "Google Maps", "Google Images",
                                  "X", "LinkedIn", "Perplexity", "ChatGPT", "Claude", "Spotify", "Netflix", "npm", "Stack Overflow"]

    private static let knownSearch: [String: String] = [
        "google": "https://www.google.com/search?q=%@",
        "youtube": "https://www.youtube.com/results?search_query=%@",
        "github": "https://github.com/search?q=%@",
        "amazon": "https://www.amazon.it/s?k=%@",
        "reddit": "https://www.reddit.com/search/?q=%@",
        "wikipedia": "https://en.wikipedia.org/w/index.php?search=%@",
        "maps": "https://www.google.com/maps/search/%@",
        "google maps": "https://www.google.com/maps/search/%@",
        "x": "https://x.com/search?q=%@",
        "twitter": "https://x.com/search?q=%@",
        "linkedin": "https://www.linkedin.com/search/results/all/?keywords=%@",
        "perplexity": "https://www.perplexity.ai/search?q=%@",
        "chatgpt": "https://chatgpt.com/?q=%@",
        "claude": "https://claude.ai/new?q=%@",
        "spotify": "https://open.spotify.com/search/%@",
        "netflix": "https://www.netflix.com/search?q=%@",
        "images": "https://www.google.com/search?tbm=isch&q=%@",
        "google images": "https://www.google.com/search?tbm=isch&q=%@",
        "npm": "https://www.npmjs.com/search?q=%@",
        "stack overflow": "https://stackoverflow.com/search?q=%@",
    ]

    static func siteURL(_ name: String, domain: String?) -> URL? {
        let host = knownSites[name.lowercased()] ?? domain
        guard let host else { return nil }
        return URL(string: "https://\(host)")
    }

    static func searchURL(site: String, query: String, domain: String?) -> URL? {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#/")))
        else { return nil }
        if let mine = UserSites.find(site) {
            if let template = mine.search { return URL(string: template.replacingOccurrences(of: "%@", with: q)) }
            if let host = mine.openURL?.host() { return URL(string: "https://www.google.com/search?q=site%3A\(host)+\(q)") }
        }
        if let template = knownSearch[site] { return URL(string: template.replacingOccurrences(of: "%@", with: q)) }
        // A site we don't know: let Google search inside it.
        if let domain { return URL(string: "https://www.google.com/search?q=site%3A\(domain)+\(q)") }
        return URL(string: "https://www.google.com/search?q=\(q)")
    }

    /// Only a bare host like "youtube.com", never a full URL or anything with a scheme.
    private static func cleanDomain(_ s: String) -> String? {
        var d = s.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["https://", "http://", "www."] where d.hasPrefix(prefix) { d.removeFirst(prefix.count) }
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        let ok = d.contains(".") && d.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        return ok ? d : nil
    }
}

/// Apps installed on this Mac, found by name.
enum Apps {
    struct App { let name: String; let url: URL }

    private static var cache: [App]?

    static func all() -> [App] {
        if let cache { return cache }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     home.appending(path: "Applications").path, home.appending(path: "Applications/Chrome Apps.localized").path]
        var out: [App] = []
        for root in roots {
            for item in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: root).appending(path: item)
                let file = String(item.dropLast(4))
                let shown = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                out.append(App(name: shown, url: url))
                if shown != file { out.append(App(name: file, url: url)) } // "Notes" as well as "Note" in Italian
            }
        }
        cache = out
        return out
    }

    static func find(_ name: String, exactOnly: Bool) -> App? {
        let want = normal(name)
        guard !want.isEmpty else { return nil }
        let apps = all()
        if let exact = apps.first(where: { normal($0.name) == want }) { return exact }
        guard !exactOnly else { return nil }
        return apps.filter { normal($0.name).hasPrefix(want) }.min { $0.name.count < $1.name.count }
    }

    private static func normal(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// Sites you add on the Commands page, so "open Linear" or "search the wiki for onboarding" work.
nonisolated struct UserSite: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// What "open <name>" goes to: a host or a full address.
    var address: String
    /// Search address with %@ where the query goes. nil searches the site through Google.
    var search: String?

    var openURL: URL? {
        let a = address.trimmingCharacters(in: .whitespaces)
        return URL(string: a.contains("://") ? a : "https://\(a)")
    }
}

enum UserSites {
    static let key = "userSites"

    static func all() -> [UserSite] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([UserSite].self, from: data)) ?? []
    }

    static func save(_ sites: [UserSite]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(sites), forKey: key)
    }

    /// By name, ignoring case and spaces: "Company Wiki" matches "company wiki" and "companywiki".
    static func find(_ name: String) -> UserSite? {
        let k = squash(name)
        return all().first { squash($0.name) == k }
    }

    /// Tells the command model about your sites so it uses their names.
    static func promptLine() -> String {
        let names = all().map(\.name)
        guard !names.isEmpty else { return "" }
        return "\n- The user's own sites, use these exact names as the target or site: " + names.joined(separator: ", ") + "."
    }

    /// From an address you got by searching the site for TEST: the same address with %@ where TEST was.
    static func template(fromExample example: String) -> String? {
        let e = example.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty, let r = e.range(of: "test", options: .caseInsensitive) else { return nil }
        let t = e.replacingCharacters(in: r, with: "%@")
        return t.contains("://") ? t : "https://\(t)"
    }

    private static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
}

// MARK: - Your own commands

/// A short name you say after ⌥⌥, and the instruction it stands for.
nonisolated struct UserCommand: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var instruction: String
}

enum UserCommands {
    static let key = "userCommands"

    static func all() -> [UserCommand] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([UserCommand].self, from: data)) ?? []
    }

    static func save(_ commands: [UserCommand]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(commands), forKey: key)
    }

    /// "Bullets, keep it to three." → (bullets, "keep it to three"). The name has to come first.
    /// Spoken names often split or join words ("tl dr", "standup"), so spaces and case don't count.
    static func match(_ said: String, in commands: [UserCommand] = all()) -> (command: UserCommand, extra: String)? {
        let words = said.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        for cmd in commands.sorted(by: { $0.name.count > $1.name.count }) {
            let name = squash(cmd.name)
            guard !name.isEmpty else { continue }
            for n in 1...min(4, words.count) where squash(words.prefix(n).joined()) == name {
                let rest = words.dropFirst(n).joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!-—").union(.whitespaces))
                return (cmd, rest)
            }
        }
        return nil
    }

    /// For the models, so a misheard name ("bullet", "bullets please") still finds the saved command.
    static func promptLines(_ commands: [UserCommand] = all()) -> String {
        commands.map { "- \"\($0.name)\": \($0.instruction)" }.joined(separator: "\n")
    }

    static func find(_ name: String) -> UserCommand? {
        let k = squash(name)
        return all().first { squash($0.name) == k }
    }

    /// Ready-made ones to start from on the Commands page.
    static let ideas: [UserCommand] = [
        UserCommand(name: "bullets", instruction: "Turn it into a bullet list. One short line per point, no full stops."),
        UserCommand(name: "tldr", instruction: "Summarise it in one or two plain sentences."),
        UserCommand(name: "reply", instruction: "Write a short, friendly reply to this message. Use what I say after the name as the gist."),
        UserCommand(name: "translate", instruction: "Translate it to English, or to Italian if it's already in English. Keep the tone."),
        UserCommand(name: "standup", instruction: "Write my standup from what I say after the name: three bullets starting with Done, Doing and Blocked."),
    ]

    private static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
}

extension Commands {
    /// A saved command with nothing selected: write new text to paste at the cursor.
    static let writePrompt = """
    You write text for the user, to be pasted where their cursor is. You get the instruction to follow and what they said, in English or Italian. Reply with the text only: no quotes, no tags, no preamble, no explanation.
    - Write in the language they spoke, unless the instruction says otherwise.
    - Use only what they said. Don't invent facts, names or numbers.
    """

    static func write(instruction: String, said: String, key: String) async throws -> String {
        let messages = [
            ["role": "system", "content": writePrompt],
            ["role": "user", "content": "<instruction>\n\(instruction)\n</instruction>\n<said>\n\(said.isEmpty ? "(nothing more)" : said)\n</said>"],
        ]
        let out = try await Groq.chat(messages, key: key, model: Prefs.cleanupModel, maxTokens: 2000, timeout: 20)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
