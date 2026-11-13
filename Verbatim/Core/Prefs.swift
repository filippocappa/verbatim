import Foundation
import Security

enum AppInfo {
    /// The name shown everywhere. Set once in project.yml (APP_DISPLAY_NAME).
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Verbatim"
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.fcappa.Verbatim"
}

/// User preferences, backed by UserDefaults. Read from anywhere; views bind via @AppStorage with the same keys.
enum Prefs {
    enum Key {
        static let cleanupStyle = "cleanupStyle"        // CleanupStyle raw value
        static let cleanupModel = "cleanupModel"
        static let language = "language"                // "auto", "en", "it"
        static let offlineLanguage = "offlineLanguage"  // "en", "it"
        static let learnFromCorrections = "learnFromCorrections"
        static let sounds = "sounds"
        static let keepOnClipboard = "keepOnClipboard"
        static let microphone = "microphone"            // "auto" or a device UID
        static let typingWPM = "typingWPM"
        static let didOnboard = "didOnboard"
        static let paused = "paused"
        static let meetingOffer = "meetingOffer"        // offer to take notes when a call starts
        static let pillPlace = "pillPlace"              // "pill" (bottom, calls at the top) or "notch"
        static let speechEngine = "speechEngine"        // "groq" (local model as backup) or "local" (never sends audio)
        static let localModel = "localModel"            // LocalModel raw value
        static let meetingCalendar = "meetingCalendar"  // read the attendees of the call from Calendar
        static let spokenSend = "spokenSend"            // "send" at the end of a dictation presses Return
        static let meetingAutoStart = "meetingAutoStart" // take notes as soon as a call starts, without asking
        static let liveWords = "liveWords"               // show what's heard in the pill while you talk (Parakeet)
        static let rememberVoices = "rememberVoices"     // name voices met in earlier meetings (VoiceBook)
    }

    static let defaultCleanupModel = "qwen/qwen3.8-27b"

    static var keepOnClipboard: Bool { UserDefaults.standard.bool(forKey: Key.keepOnClipboard) }

    static func registerDefaults() {
        let preferredItalian = Locale.preferredLanguages.first?.hasPrefix("it") == true
        UserDefaults.standard.register(defaults: [
            Key.cleanupStyle: CleanupStyle.clean.rawValue,
            Key.cleanupModel: defaultCleanupModel,
            Key.language: "auto",
            Key.offlineLanguage: preferredItalian ? "it" : "en",
            Key.learnFromCorrections: true,
            Key.sounds: true,
            Key.keepOnClipboard: true,
            Key.microphone: "auto",
            Key.typingWPM: 40,
            Key.didOnboard: false,
            Key.paused: false,
            Key.meetingOffer: true,
            Key.speechEngine: "groq",
            Key.localModel: LocalModel.parakeet.rawValue,
            Key.pillPlace: "pill",
            Key.meetingCalendar: false,
            Key.spokenSend: true,
            Key.meetingAutoStart: false,
            Key.rememberVoices: true,
        ])
    }

    private static var d: UserDefaults { .standard }

    static var cleanupStyle: CleanupStyle {
        CleanupStyle(rawValue: d.string(forKey: Key.cleanupStyle) ?? "") ?? .clean
    }
    static var cleanupModel: String {
        let m = d.string(forKey: Key.cleanupModel)?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? defaultCleanupModel : m
    }
    static var language: String { d.string(forKey: Key.language) ?? "auto" }
    static var offlineLanguage: String { d.string(forKey: Key.offlineLanguage) ?? "en" }
    static var learnFromCorrections: Bool { d.bool(forKey: Key.learnFromCorrections) }
    static var sounds: Bool { d.bool(forKey: Key.sounds) }
    static var meetingOffer: Bool { d.bool(forKey: Key.meetingOffer) }
    static var meetingCalendar: Bool { d.bool(forKey: Key.meetingCalendar) }
    static var spokenSend: Bool { d.bool(forKey: Key.spokenSend) }
    static var meetingAutoStart: Bool { d.bool(forKey: Key.meetingAutoStart) }
    static var rememberVoices: Bool { d.bool(forKey: Key.rememberVoices) }
    static var liveWords: Bool { d.bool(forKey: Key.liveWords) }
    static var useNotch: Bool { d.string(forKey: Key.pillPlace) == "notch" }
    /// Audio stays on this Mac: a local model does the speech even when Groq is there.
    static var localOnly: Bool { d.string(forKey: Key.speechEngine) == "local" }
    static var localModel: LocalModel { LocalModel(rawValue: d.string(forKey: Key.localModel) ?? "") ?? .parakeet }
    static var microphone: String { d.string(forKey: Key.microphone) ?? "auto" }
    static var typingWPM: Int { max(10, d.integer(forKey: Key.typingWPM)) }
    static var paused: Bool {
        get { d.bool(forKey: Key.paused) }
        set { d.set(newValue, forKey: Key.paused) }
    }
}

/// API keys live in the login keychain, never in UserDefaults.
enum Keychain {
    static var groqKey: String? {
        get { read("groq-api-key") }
        set { write("groq-api-key", newValue) }
    }

    /// Claude, for fixing names in meeting notes.
    static var claudeKey: String? {
        get { read("anthropic-api-key") }
        set { write("anthropic-api-key", newValue) }
    }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AppInfo.bundleID,
         kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    private static func write(_ account: String, _ value: String?) {
        SecItemDelete(base(account) as CFDictionary)
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
        var add = base(account)
        add[kSecValueData as String] = Data(v.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
