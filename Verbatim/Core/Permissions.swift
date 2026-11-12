import AppKit
import ApplicationServices
import AVFoundation

enum Permissions {
    enum State { case allowed, notAsked, denied }

    static var microphone: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Adds the app to the Accessibility list and opens System Settings at that page.
    static func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
        DictationController.shared.refreshAccessibility()
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
