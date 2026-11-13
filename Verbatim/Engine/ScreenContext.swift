import AppKit
import ApplicationServices
import ScreenCaptureKit

/// What's on screen, for the assistant (⌥⌥ with nothing selected): the text of the front window, read through
/// Accessibility, and a picture of the window when Screen Recording is already allowed. It never asks for
/// Screen Recording itself; without it the text is enough for most apps.
enum ScreenContext {
    struct Snapshot {
        let app: String
        let window: String
        let text: String
        /// What's already typed in the text box in focus, e.g. a half-written reply.
        let draft: String?
        /// JPEG.
        let image: Data?
    }

    static func capture(app: NSRunningApplication?, field: FocusedField?) async -> Snapshot {
        let pid = app?.processIdentifier ?? 0
        let (window, text) = await Task.detached { read(pid: pid) }.value
        let draft = field?.isSecure == false ? field?.value?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let image = CGPreflightScreenCaptureAccess() ? await picture(pid: pid) : nil
        return Snapshot(app: app?.localizedName ?? "", window: window, text: text,
                        draft: draft?.isEmpty == false ? draft : nil, image: image)
    }

    // MARK: Text

    /// The window's title and its text, top to bottom. Long pages keep their start and their end: a chat's
    /// newest messages are at the bottom.
    nonisolated private static func read(pid: pid_t) -> (window: String, text: String) {
        guard pid > 0 else { return ("", "") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        // Chromium and Electron apps hide their text until asked.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var w: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w) != .success {
            AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &w)
        }
        guard let w, CFGetTypeID(w) == AXUIElementGetTypeID() else { return ("", "") }
        let window = w as! AXUIElement
        let title = string(window, kAXTitleAttribute) ?? ""

        var pieces: [String] = []
        var visited = 0
        let started = Date()
        func walk(_ e: AXUIElement, depth: Int) {
            guard depth < 60, visited < 6000, Date().timeIntervalSince(started) < 1.5 else { return }
            visited += 1
            let role = string(e, kAXRoleAttribute) ?? ""
            if role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField" || role == "AXHeading" {
                if let v = string(e, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty,
                   pieces.last != v {
                    pieces.append(v)
                }
                if role == "AXStaticText" || role == "AXTextArea" { return }
            }
            if role == "AXImage", let d = string(e, kAXDescriptionAttribute), !d.isEmpty { pieces.append("[image: \(d)]") }
            var kids: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success,
                  let children = kids as? [AXUIElement] else { return }
            for c in children { walk(c, depth: depth + 1) }
        }
        walk(window, depth: 0)

        var text = pieces.joined(separator: "\n")
        if text.count > 24_000 {
            text = String(text.prefix(10_000)) + "\n[…]\n" + String(text.suffix(14_000))
        }
        return (title, text)
    }

    nonisolated private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    // MARK: Picture

    /// The app's front window, at most 1600 px wide.
    private static func picture(pid: pid_t) async -> Data? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows
                .filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 100 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }
        let config = SCStreamConfiguration()
        let scale = min(1, 1600 / window.frame.width)
        config.width = Int(window.frame.width * scale * 2) / 2
        config.height = Int(window.frame.height * scale * 2) / 2
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                    configuration: config) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
