import AppKit
import SwiftUI

/// Meeting messages drop down from the notch: a black shape that grows out of it, so they're noticed
/// without covering the call's own buttons at the bottom of the screen. On a screen without a notch it
/// hangs from the top edge the same way.
final class NotchPanel: NSPanel {
    static let size = NSSize(width: 720, height: 150)
    private let geometry = NotchGeometry()

    init(controller: DictationController) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the menu bar, so it can sit over the notch.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        ignoresMouseEvents = true
        animationBehavior = .none

        let host = NotchHostingView(rootView: NotchView().environment(controller).environment(geometry))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.size)
        contentView = host
        place()
        orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Allowed to cover the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func update(for pill: DictationController.MeetingPill?) {
        if pill != nil { place() }
        ignoresMouseEvents = pill == nil
        orderFrontRegardless()
    }

    /// The screen with the notch if it's in use, else the one with the mouse.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let notch = screen.safeAreaInsets.top
        if notch > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            geometry.top = notch
            geometry.notchWidth = screen.frame.width - l.width - r.width
            geometry.hasNotch = true
        } else {
            geometry.top = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
            geometry.notchWidth = 180
            geometry.hasNotch = false
        }
        setFrame(NSRect(x: screen.frame.midX - Self.size.width / 2, y: screen.frame.maxY - Self.size.height,
                        width: Self.size.width, height: Self.size.height), display: true)
    }
}

@Observable
final class NotchGeometry {
    var top: CGFloat = 32
    var notchWidth: CGFloat = 180
    var hasNotch = false
}

private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct NotchView: View {
    @Environment(DictationController.self) private var controller
    @Environment(NotchGeometry.self) private var geometry
    @State private var shown: DictationController.MeetingPill?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if let shown {
                    MeetingContent(pill: shown)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .frame(height: 40)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .scale(0.85, anchor: .top)).combined(with: .blurReplace))
                        .id(String(describing: shown))
                }
            }
            .padding(.top, geometry.top)
            .frame(minWidth: geometry.notchWidth, minHeight: geometry.top, alignment: .bottom)
            .background(NotchShape(bottomRadius: shown == nil ? 10 : 24).fill(.black))
            .opacity(shown == nil && !geometry.hasNotch ? 0 : 1)
        }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { shown = controller.meetingPill }
        .onChange(of: controller.meetingPill) { _, new in
            withAnimation(.spring(duration: 0.5, bounce: 0.28)) { shown = new }
        }
    }
}

/// The notch's own outline: flares out at the top into the menu bar, rounded at the bottom.
nonisolated private struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat = 8

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius, b = min(bottomRadius, rect.height / 2, rect.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX - t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX + t, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + t), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - b, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - b), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.minX - t, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct MeetingContent: View {
    let pill: DictationController.MeetingPill

    var body: some View {
        switch pill {
        case let .offer(_, title, bundleID):
            HStack(spacing: 9) {
                AppIcon(bundleID: bundleID)
                Text(title)
                Text("Take notes?").foregroundStyle(.secondary)
                PillButton(title: "Take Notes") { MeetingController.shared.start() }
                Button { DictationController.shared.dismissMeeting() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 9)
            .padding(.trailing, 7)

        case let .started(title):
            HStack(spacing: 9) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.red)
                    .shadow(color: .red.opacity(0.7), radius: 4)
                Text("Taking notes")
                Text("\(title) · let the others know").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

        case .stopped:
            HStack(spacing: 9) {
                StatusBadge(symbol: "stop.fill", fill: .secondary)
                Text("Stopped taking notes")
            }
            .padding(.leading, 9)
            .padding(.trailing, 16)

        case .cantHear:
            HStack(spacing: 9) {
                Image(systemName: "speaker.slash").foregroundStyle(.orange)
                Text("Can't hear the call")
                PillButton(title: "Open Settings") { Permissions.openSystemAudioSettings() }
            }
            .padding(.leading, 15)
            .padding(.trailing, 7)

        case .writingNotes:
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Writing your meeting notes")
            }
            .padding(.horizontal, 16)

        case let .saved(file):
            HStack(spacing: 9) {
                StatusBadge(symbol: "checkmark", fill: .green)
                Text("Meeting notes ready")
                PillButton(title: "Open") {
                    NSWorkspace.shared.open(file)
                    DictationController.shared.dismissMeeting()
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 7)

        case let .failed(message):
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(message).truncationMode(.tail).frame(maxWidth: 340, alignment: .leading)
            }
            .padding(.horizontal, 15)
        }
    }
}

/// The meeting app's own icon, small.
struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 22, height: 22)
        } else {
            StatusBadge(symbol: "video.fill", fill: .secondary)
        }
    }
}

