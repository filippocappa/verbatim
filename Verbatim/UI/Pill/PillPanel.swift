import AppKit
import SwiftUI

/// A borderless, non-activating panel at the bottom of the screen. It never takes focus
/// from the app you're typing in, and only accepts clicks when the pill has a button.
final class PillPanel: NSPanel {
    static let size = NSSize(width: 580, height: 96)

    private let controller: DictationController
    private var hideWork: Task<Void, Never>?

    init(controller: DictationController) {
        self.controller = controller
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        ignoresMouseEvents = true
        animationBehavior = .none

        let host = ClickThroughHostingView(rootView: PillView().environment(controller))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.size)
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(for phase: DictationController.Phase) {
        ignoresMouseEvents = !phase.isInteractive
        hideWork?.cancel()
        if phase == .idle {
            // Let the glass dissolve before the window goes.
            hideWork = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                self?.orderOut(nil)
            }
        } else if !isVisible {
            place()
            orderFrontRegardless()
        }
    }

    /// Bottom centre of the screen the mouse is on.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: vf.midX - Self.size.width / 2, y: vf.minY + 8))
    }
}

/// Lets the first click land on a button without activating the app.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
