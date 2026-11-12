import AppKit
import SwiftUI

/// The top of the screen. Two looks, picked in Settings → General:
/// - Pill: call messages show as the same glass pill as dictation, but at the top, so they never cover
///   the call's own buttons at the bottom. Dictation stays at the bottom.
/// - Notch: everything, dictation included, drops down from the notch as a small black island.
///   On a screen without a notch it hangs from the top edge.
final class NotchPanel: NSPanel {
    static let size = NSSize(width: 720, height: 130)
    private let geometry = NotchGeometry()
    private let controller: DictationController

    init(controller: DictationController) {
        self.controller = controller
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

        let host = NotchHostingView(rootView: TopView().environment(controller).environment(geometry))
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

    /// Called whenever the dictation phase or the meeting message changes.
    func refresh() {
        let notch = Prefs.useNotch
        let dictating = notch && controller.phase != .idle
        let meeting = controller.meetingPill
        let interactive: Bool = {
            if dictating { return controller.phase.isInteractive }
            switch meeting {
            case .offer, .cantHear, .saved: return true
            default: return false
            }
        }()
        if dictating || meeting != nil { place() }
        ignoresMouseEvents = !interactive
        orderFrontRegardless()
    }

    /// The screen with the mouse.
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
            geometry.notchWidth = 160
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

private struct TopView: View {
    @Environment(DictationController.self) private var controller
    @Environment(NotchGeometry.self) private var geometry
    @AppStorage(Prefs.Key.pillPlace) private var place = "pill"
    @Namespace private var glass

    private enum Shown: Equatable {
        case dictation(DictationController.Phase)
        case meeting(DictationController.MeetingPill)
    }

    /// Dictation wins while it's going on; the meeting message comes back after.
    private var shown: Shown? {
        if place == "notch", controller.phase != .idle { return .dictation(controller.phase) }
        return controller.meetingPill.map(Shown.meeting)
    }

    var body: some View {
        Group {
            if place == "notch" { island } else { pill }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.42, bounce: 0.22), value: shown)
    }

    @ViewBuilder private func content(_ s: Shown, compact: Bool) -> some View {
        switch s {
        case let .dictation(phase):
            PillContent(phase: phase, levels: controller.levels, startedAt: controller.startedAt,
                        command: controller.command, note: controller.writingNote, onUndo: controller.undoLearned,
                        compact: true)
        case let .meeting(m):
            MeetingContent(pill: m)
                .font(.system(size: compact ? 12 : 13))
                .lineLimit(1)
                .frame(height: compact ? 30 : 40)
                .fixedSize()
        }
    }

    /// Black, growing out of the notch.
    private var island: some View {
        ZStack {
            if let shown {
                content(shown, compact: true)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 5)
                    .transition(.opacity.combined(with: .scale(0.9, anchor: .top)))
            }
        }
        .padding(.top, geometry.top)
        .frame(minWidth: geometry.notchWidth, minHeight: geometry.top, alignment: .bottom)
        .background(NotchShape(bottomRadius: shown == nil ? 10 : 17).fill(.black))
        .opacity(shown == nil && !geometry.hasNotch ? 0 : 1)
        .environment(\.colorScheme, .dark)
        .controlSize(.small)
    }

    /// The glass pill, just under the menu bar. Only call messages; dictation stays at the bottom.
    private var pill: some View {
        GlassEffectContainer {
            if case let .meeting(m)? = shown {
                content(.meeting(m), compact: false)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("top", in: glass)
                    .glassEffectTransition(.materialize)
            }
        }
        .padding(.top, geometry.top + 8)
    }
}

/// The notch's own outline: flares out at the top into the menu bar, rounded at the bottom.
nonisolated private struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat = 7

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
        case let .offer(_, title, bundleID, service):
            HStack(spacing: 8) {
                AppIcon(bundleID: bundleID, service: service)
                // "Google Meet", without "in Safari": the logo already says which call it is.
                Text(service == nil ? title : title.components(separatedBy: " in ").first ?? title)
                PillButton(title: "Take Notes") { MeetingController.shared.start() }
                Button { DictationController.shared.dismissMeeting() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 7)
            .padding(.trailing, 5)

        case let .started(title):
            HStack(spacing: 9) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.red)
                    .shadow(color: .red.opacity(0.7), radius: 4)
                Text("Taking notes")
                Text("let the others know").foregroundStyle(.secondary)
            }
            .help(title)
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

/// The call's logo: the web service's (Meet, Teams...) when it's in a browser, else the app's own icon.
struct AppIcon: View {
    let bundleID: String
    var service: String? = nil
    @Environment(\.controlSize) private var controlSize
    private var side: CGFloat { controlSize == .small ? 18 : 22 }

    var body: some View {
        if let service, let logo = ServiceLogos.shared.image(service) {
            Image(nsImage: logo).resizable().interpolation(.high).frame(width: side, height: side)
                .clipShape(.rect(cornerRadius: side * 0.22))
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: side, height: side)
        } else {
            StatusBadge(symbol: "video.fill", fill: .secondary)
        }
    }
}

/// Logos of web call services, fetched once (as the site's icon) and kept in Application Support.
@MainActor
@Observable
final class ServiceLogos {
    static let shared = ServiceLogos()
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("\(AppInfo.name)/Logos", isDirectory: true)
    }

    func image(_ domain: String) -> NSImage? {
        if let image = images[domain] { return image }
        load(domain)
        return nil
    }

    func load(_ domain: String) {
        guard images[domain] == nil, !loading.contains(domain) else { return }
        loading.insert(domain)
        let file = Self.folder.appendingPathComponent("\(domain).png")
        Task {
            if let image = NSImage(contentsOf: file) { images[domain] = image; return }
            // Only the service's domain is sent, nothing about the call.
            guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=64"),
                  let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else {
                loading.remove(domain)
                return
            }
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try? data.write(to: file)
            images[domain] = image
        }
    }
}
