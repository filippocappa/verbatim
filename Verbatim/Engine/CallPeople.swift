import AppKit
import ApplicationServices

/// The names shown on the video tiles of a call in the browser, read through Accessibility (which Verbatim
/// already has). Only Google Meet for now: tested in Safari, Nov 2026. Meet shows each person's name as plain
/// text on their tile; the controls, captions and panels are labelled groups, so they're skipped.
@MainActor
enum CallPeople {
    /// The people on screen in the call, without you. Empty if the window can't be read.
    static func names(in call: MeetingWatcher.Call) -> [String] {
        guard call.service == "meet.google.com" else { return [] }
        var found: [String] = []
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: call.app.bundleID) {
            let app = AXUIElementCreateApplication(running.processIdentifier)
            for window in (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
                guard let title = value(window, kAXTitleAttribute) as? String, title.hasPrefix("Meet") else { continue }
                var budget = 4000
                for area in webAreas(window, budget: &budget) {
                    var texts: [String] = []
                    collect(area, into: &texts, budget: &budget)
                    for t in texts {
                        if let name = clean(t), !found.contains(name) { found.append(name) }
                    }
                }
            }
        }
        return found
    }

    // MARK: Captions

    /// Meet's captions box, when captions are on: "test" then what they said, "You" then what you said…
    /// Found by its label (English and Italian Meet) or its class.
    static func captionsBox(in call: MeetingWatcher.Call) -> AXUIElement? {
        guard call.service == "meet.google.com" else { return nil }
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: call.app.bundleID) {
            let app = AXUIElementCreateApplication(running.processIdentifier)
            for window in (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
                guard let title = value(window, kAXTitleAttribute) as? String, title.hasPrefix("Meet") else { continue }
                var budget = 4000
                for area in webAreas(window, budget: &budget) {
                    if let box = findCaptions(area, budget: &budget) { return box }
                }
            }
        }
        return nil
    }

    private static func findCaptions(_ e: AXUIElement, budget: inout Int) -> AXUIElement? {
        budget -= 1
        guard budget > 0 else { return nil }
        for c in children(e) where value(c, kAXRoleAttribute) as? String == "AXGroup" {
            let label = value(c, kAXDescriptionAttribute) as? String ?? ""
            let classes = value(c, "AXDOMClassList") as? [String] ?? []
            if ["Captions", "Sottotitoli"].contains(label) || classes.contains("vNKgIf") { return c }
            if label.isEmpty, let box = findCaptions(c, budget: &budget) { return box }
        }
        return nil
    }

    /// The last thing each person said in the captions box, by the name Meet shows ("You" for you).
    /// nil when the box is gone.
    static func captions(_ box: AXUIElement) -> [String: String]? {
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(box, kAXChildrenAttribute as CFString, &kids) == .success,
              let list = kids as? [AXUIElement] else { return nil }
        let texts = list.map { group -> String in
            var all: [String] = []
            var budget = 50
            collect(group, into: &all, budget: &budget)
            return all.joined(separator: " ")
        }
        var said: [String: String] = [:]
        var i = 0
        while i + 1 < texts.count {
            if !texts[i].isEmpty { said[texts[i]] = texts[i + 1] }
            i += 2
        }
        return said
    }

    private static func value(_ e: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success ? v : nil
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        value(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func webAreas(_ e: AXUIElement, budget: inout Int) -> [AXUIElement] {
        budget -= 1
        guard budget > 0 else { return [] }
        if value(e, kAXRoleAttribute) as? String == "AXWebArea" { return [e] }
        var out: [AXUIElement] = []
        for c in children(e) { out += webAreas(c, budget: &budget) }
        return out
    }

    /// Plain text that isn't inside a labelled part of the page (call controls, captions, side panel…).
    private static func collect(_ e: AXUIElement, into texts: inout [String], budget: inout Int) {
        budget -= 1
        guard budget > 0 else { return }
        for c in children(e) {
            let role = value(c, kAXRoleAttribute) as? String ?? ""
            if role == "AXStaticText" {
                if let v = value(c, kAXValueAttribute) as? String { texts.append(v) }
                continue
            }
            guard role == "AXGroup" else { continue }
            let label = (value(c, kAXDescriptionAttribute) as? String ?? "") + (value(c, kAXTitleAttribute) as? String ?? "")
            if label.isEmpty { collect(c, into: &texts, budget: &budget) }
        }
    }

    /// "Marco Rossi" from a tile, or nil for anything that isn't a name ("9:50", "Your microphone is off.").
    static func clean(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Marco Rossi (Presentation)" when sharing the screen.
        if let paren = t.firstIndex(of: "(") { t = t[..<paren].trimmingCharacters(in: .whitespaces) }
        let words = t.split(separator: " ")
        guard (1...5).contains(words.count), (2...60).contains(t.count),
              !t.contains(where: { $0.isNumber || ".!?:,;@/|".contains($0) }),
              // "protected by reCAPTCHA": a name of several words starts with a capital.
              words.count == 1 || words[0].first?.isUppercase == true,
              !["you", "am", "pm", "me", "tu", "io"].contains(t.lowercased()),
              !isYou(t)
        else { return nil }
        return t
    }

    /// Your own tile: the Mac's user name ("Filippo Cappa"), or just its first name.
    private static func isYou(_ name: String) -> Bool {
        let full = NSFullUserName().lowercased()
        let n = name.lowercased()
        return n == full || n == full.split(separator: " ").first.map(String.init)
    }
}
