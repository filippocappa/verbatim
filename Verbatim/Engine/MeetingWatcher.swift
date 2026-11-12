import AppKit
import ApplicationServices
import os

/// Notices when a call starts and ends, by checking every 2 s which apps are using the microphone.
/// Nothing is recorded here; it only tells `MeetingController` what's going on.
@MainActor
final class MeetingWatcher {
    /// An app that can hold a call.
    struct App: Equatable, Sendable {
        let name: String
        /// The app to show the icon of.
        let bundleID: String
        /// Every process to listen to: the app and its helpers, which are often the ones playing the sound.
        let prefixes: [String]
        let isBrowser: Bool
        /// Only counts while the app itself is open (FaceTime shares its call service with Safari).
        var needsAppOpen = false
    }

    /// The call going on right now: which app, and what it looks like ("Google Meet" in Chrome).
    struct Call: Equatable, Sendable {
        let app: App
        let title: String
        /// The web service in a browser ("meet.google.com"), for its logo. nil for call apps, which show their own icon.
        var service: String? = nil
    }

    static let apps: [App] = {
        #if DEBUG
        // -meetingTestApp com.apple.QuickTimePlayerX makes any app count as a call app, for testing.
        if let id = UserDefaults.standard.string(forKey: "meetingTestApp") {
            return [App(name: "Test", bundleID: id, prefixes: [id], isBrowser: false)] + known
        }
        #endif
        return known
    }()

    private static let known: [App] = [
        App(name: "Zoom", bundleID: "us.zoom.xos", prefixes: ["us.zoom"], isBrowser: false),
        App(name: "Webex", bundleID: "Cisco-Systems.Spark", prefixes: ["Cisco-Systems.Spark", "com.cisco.webex"], isBrowser: false),
        App(name: "Teams", bundleID: "com.microsoft.teams2", prefixes: ["com.microsoft.teams"], isBrowser: false),
        App(name: "FaceTime", bundleID: "com.apple.FaceTime", prefixes: ["com.apple.FaceTime", "com.apple.avconferenced"], isBrowser: false, needsAppOpen: true),
        App(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", prefixes: ["com.tinyspeck.slackmacgap"], isBrowser: false),
        App(name: "Discord", bundleID: "com.hnc.Discord", prefixes: ["com.hnc.Discord"], isBrowser: false),
        App(name: "Chrome", bundleID: "com.google.Chrome", prefixes: ["com.google.Chrome"], isBrowser: true),
        App(name: "Arc", bundleID: "company.thebrowser.Browser", prefixes: ["company.thebrowser.Browser"], isBrowser: true),
        App(name: "Dia", bundleID: "company.thebrowser.dia", prefixes: ["company.thebrowser.dia"], isBrowser: true),
        App(name: "Edge", bundleID: "com.microsoft.edgemac", prefixes: ["com.microsoft.edgemac"], isBrowser: true),
        App(name: "Brave", bundleID: "com.brave.Browser", prefixes: ["com.brave.Browser"], isBrowser: true),
        App(name: "Firefox", bundleID: "org.mozilla.firefox", prefixes: ["org.mozilla"], isBrowser: true),
        // Safari's sound and mic go through WebKit's shared helper.
        App(name: "Safari", bundleID: "com.apple.Safari", prefixes: ["com.apple.Safari", "com.apple.WebKit.GPU", "com.apple.avconferenced"], isBrowser: true),
    ]

    /// Browser window titles that mean a call, and the name to show for it.
    private static let webCalls: [(match: String, name: String, domain: String)] = [
        ("Meet - ", "Google Meet", "meet.google.com"), ("Meet – ", "Google Meet", "meet.google.com"),
        ("Google Meet", "Google Meet", "meet.google.com"), ("meet.google.com", "Google Meet", "meet.google.com"),
        ("Microsoft Teams", "Teams", "teams.microsoft.com"), ("Webex", "Webex", "webex.com"), ("Zoom", "Zoom", "zoom.us"),
        ("Whereby", "Whereby", "whereby.com"), ("Jitsi", "Jitsi", "meet.jit.si"),
    ]

    /// Every service logo that may be needed, so they're ready before the first call.
    static var serviceDomains: [String] { Array(Set(webCalls.map(\.domain))) }

    /// Called on every change: a call started (non-nil) or ended (nil).
    var onChange: ((Call?) -> Void)?
    private(set) var current: Call?
    private var timer: Timer?
    /// When the current call was last seen using the mic. It counts as over after `grace` seconds without.
    private var lastSeen = Date.distantPast
    private let grace: TimeInterval = 20

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Looks once, right now. Also used by "Take notes" when no call was noticed, to pick the app.
    func detect() -> Call? {
        let busy = SystemAudio.processes().filter { $0.input && $0.pid != getpid() }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "meetingTrace") {
            Logger(subsystem: AppInfo.bundleID, category: "meetings").info("mic in use by: \(busy.map(\.description).joined(separator: ", "), privacy: .public)")
        }
        #endif
        let apps = Self.apps.filter { app in
            busy.contains { p in app.prefixes.contains { p.bundleID.hasPrefix($0) } }
                && (!app.needsAppOpen || !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty)
        }
        // A dedicated call app wins over a browser that happens to use the mic.
        if let app = apps.first(where: { !$0.isBrowser }) { return Call(app: app, title: "\(app.name) call") }
        for app in apps {
            if let web = Self.webCall(app) { return Call(app: app, title: "\(web.name) in \(app.name)", service: web.domain) }
        }
        if let app = apps.first { return Call(app: app, title: "Call in \(app.name)") }
        return nil
    }

    private func check() {
        let now = detect()
        if let now {
            lastSeen = Date()
            // A new call, or the same one now with a clearer name ("Call in Safari" → "Google Meet in Safari").
            if current == nil || current?.app != now.app || (current?.title.hasPrefix("Call in") == true && now.title != current?.title) {
                current = now
                onChange?(now)
            }
        } else if let current, Self.stillPlaying(current.app) {
            // Muted mic but the call still playing sound: still on the call.
            lastSeen = Date()
        } else if current != nil, Date().timeIntervalSince(lastSeen) > grace {
            current = nil
            onChange?(nil)
        }
    }

    private static func stillPlaying(_ app: App) -> Bool {
        SystemAudio.processes().contains { p in p.output && app.prefixes.contains { p.bundleID.hasPrefix($0) } }
    }

    /// "Google Meet" when one of the browser's windows shows a call. Needs Accessibility, which Verbatim already has.
    private static func webCall(_ app: App) -> (name: String, domain: String)? {
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) {
            let element = AXUIElementCreateApplication(running.processIdentifier)
            var windows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
                  let list = windows as? [AXUIElement] else { continue }
            for window in list {
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                guard let t = title as? String else { continue }
                if let hit = webCalls.first(where: { t.contains($0.match) }) { return (hit.name, hit.domain) }
                // Meet's waiting room is titled just "Meet".
                if t == "Meet" || t.hasPrefix("Meet ") { return ("Google Meet", "meet.google.com") }
            }
        }
        return nil
    }
}
