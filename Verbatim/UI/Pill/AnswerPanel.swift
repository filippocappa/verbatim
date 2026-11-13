import AppKit
import SwiftUI

/// The assistant's answer (⌥⌥ and a question), in a panel at the bottom of the screen. It takes the keyboard
/// without bringing Verbatim forward, so Esc closes it, and it goes away when you click anywhere else.
final class AnswerPanel: NSPanel {
    static let width: CGFloat = 560

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    func show(question: String, answer: String) {
        let host = NSHostingView(rootView: AnswerView(question: question, answer: answer) { [weak self] in self?.orderOut(nil) })
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: Self.width, height: 100)
        let size = NSSize(width: Self.width, height: min(host.fittingSize.height, 520))
        host.frame = NSRect(origin: .zero, size: size)
        contentView = host
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + 24, width: size.width, height: size.height), display: true)
        }
        makeKeyAndOrderFront(nil)
    }
}

private struct AnswerView: View {
    let question: String
    let answer: String
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(question)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button(copied ? "Copied" : "Copy") {
                    Paster.copy(answer)
                    copied = true
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                Button(action: close) {
                    Image(systemName: "xmark").font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(styled)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: AnswerPanel.width)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .environment(\.colorScheme, .dark)
    }

    /// Bold and links, with list dashes shown as bullets.
    private var styled: AttributedString {
        let text = answer.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- ") || t.hasPrefix("* ") ? "•  " + t.dropFirst(2) : line
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
