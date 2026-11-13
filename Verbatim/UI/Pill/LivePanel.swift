import AppKit
import SwiftUI

/// The live words, in a card on top of the pill (under the notch in notch mode): grey while they may still
/// change, white once they've settled. Nothing goes into the app until you stop; then the cleaned-up text is
/// pasted and this goes away. Clicks pass straight through.
final class LivePanel: NSPanel {
    static let width: CGFloat = 560
    static let height: CGFloat = 280
    static let inset = CGSize(width: 14, height: 10)

    private let controller: DictationController
    private let host: NSHostingView<LiveOverlay>

    init(controller: DictationController) {
        self.controller = controller
        host = NSHostingView(rootView: LiveOverlay(controller: controller))
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        animationBehavior = .none
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(for phase: DictationController.Phase) {
        guard phase == .listening || phase == .writing, controller.liveCard else {
            orderOut(nil)
            return
        }
        if !isVisible {
            place()
            orderFrontRegardless()
        }
    }

    /// On the screen the pill is on (the one with the mouse). Its bottom edge sits just above the pill, which is
    /// 40 points tall and 26 up from the bottom, and it grows upwards. In notch mode it hangs below the menu bar.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let notch = Prefs.useNotch
        let y = notch ? vf.maxY - 10 - Self.height : vf.minY + 8 + 18 + 40 + 8
        host.rootView = LiveOverlay(controller: controller, up: !notch)
        setFrame(NSRect(x: vf.midX - Self.width / 2, y: y, width: Self.width, height: Self.height), display: false)
    }
}

struct LiveOverlay: View {
    let controller: DictationController
    var up = true

    var body: some View {
        VStack(spacing: 0) {
            if up { Spacer(minLength: 0) }
            if !controller.live.isEmpty {
                LiveCard(text: controller.live)
                    .transition(.opacity)
            }
            if !up { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: controller.live.isEmpty)
    }
}

/// The words themselves: white settled, grey guess, and ↵ when the dictation ends in "send".
struct LiveCard: View {
    let text: LiveText
    var fontSize: CGFloat = 14
    /// Where the lines break, in points.
    var wrap: CGFloat = LivePanel.width - LivePanel.inset.width * 2 - 16
    /// Long dictations show their last eight lines or so; the start is already settled and out of mind.
    private var limit: Int { max(120, Int(8 * wrap / (fontSize * 0.5))) }

    var body: some View {
        words
            .font(.system(size: fontSize))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: wrap, alignment: .leading)
            .padding(.horizontal, LivePanel.inset.width)
            .padding(.vertical, LivePanel.inset.height)
            .background(Color(white: 0.08).opacity(0.94), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .environment(\.colorScheme, .dark)
            .animation(.easeOut(duration: 0.12), value: text)
    }

    private var words: Text {
        var settled = text.settled, guess = text.guess
        let over = settled.count + guess.count - limit
        if over > 0 {
            if over < settled.count {
                // Cut at a word, not halfway through one.
                var rest = settled.dropFirst(over)
                if let space = rest.firstIndex(where: \.isWhitespace) { rest = rest[space...].drop(while: \.isWhitespace) }
                settled = "…" + rest
            } else {
                settled = "…"
                guess = String(guess.suffix(limit))
            }
        }
        var t = Text(settled).foregroundStyle(.white) + Text(guess).foregroundStyle(.white.opacity(0.42))
        if text.send {
            t = t + Text("  ") + Text(Image(systemName: "return")).foregroundStyle(.white.opacity(0.55))
        }
        return t
    }
}
