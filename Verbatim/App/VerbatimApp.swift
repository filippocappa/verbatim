import SwiftUI
import SwiftData

@main
struct VerbatimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let controller = DictationController.shared

    init() {
        Prefs.registerDefaults()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(controller)
                .modelContainer(Store.container)
        } label: {
            MenuBarLabel()
                .environment(controller)
        }
        .menuBarExtraStyle(.window)

        Window(AppInfo.name, id: WindowID.main) {
            MainView()
                .environment(controller)
                .modelContainer(Store.container)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 1080, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Start Dictation") { controller.toggleFromUI() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        Window("Set Up \(AppInfo.name)", id: WindowID.onboarding) {
            OnboardingView()
                .environment(controller)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(UserDefaults.standard.bool(forKey: Prefs.Key.didOnboard) ? .suppressed : .presented)

        Settings {
            SettingsView()
                .environment(controller)
        }
    }
}

enum WindowID {
    static let main = "main"
    static let onboarding = "onboarding"
}

/// Lets AppKit code (the app delegate, the pill) open SwiftUI windows.
enum WindowRouter {
    static var openWindow: OpenWindowAction?
    static var openSettings: OpenSettingsAction?

    static func show(_ id: String) {
        NSApp.activate()
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == id && $0.isVisible }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: id)
        }
    }
}

/// Shows a Dock icon (and ⌘Tab entry) only while one of the app's windows is open.
enum DockPolicy {
    static func start() {
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { scheduleUpdate() }
            }
        }
    }

    private static func scheduleUpdate() {
        // willClose fires while the window is still on screen; look again on the next turn.
        Task { @MainActor in
            let hasWindow = NSApp.windows.contains {
                $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) && $0.level == .normal
            }
            let want: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
            guard NSApp.activationPolicy() != want else { return }
            NSApp.setActivationPolicy(want)
            if want == .regular { NSApp.activate() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pill: PillPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = DictationController.shared
        let pill = PillPanel(controller: controller)
        self.pill = pill
        controller.onPhaseChange = { [weak pill] phase in pill?.update(for: phase) }
        controller.start()
        MeetingController.shared.startWatching()
        DockPolicy.start()

        #if DEBUG
        Demo.runIfRequested(controller)
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowRouter.show(WindowID.main)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
