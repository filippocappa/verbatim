import SwiftUI
import SwiftData

struct MenuBarLabel: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: symbol)
            .onAppear {
                WindowRouter.openWindow = openWindow
                WindowRouter.openSettings = openSettings
            }
    }

    private var symbol: String {
        // Stays the same while recording: the pill already shows that, and a changing icon
        // makes the menu bar jump.
        controller.isPaused ? "pause.circle" : "quote.closing"
    }
}

struct MenuBarView: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.Key.language) private var language = "auto"
    @Query(sort: \Dictation.date, order: .reverse) private var history: [Dictation]

    var body: some View {
        @Bindable var controller = controller
        let todayWords = history.prefix { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.words }

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Format.number(todayWords)) words today")
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                    EngineStatus()
                }
                Spacer()
            }

            Picker("Language", selection: $language) {
                Text("Auto").tag("auto")
                Text("English").tag("en")
                Text("Italian").tag("it")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let last = history.first {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Last dictation").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(last.date, format: .relative(presentation: .named))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(last.text)
                        .lineLimit(3)
                        .font(.callout)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button("Copy") { Paster.copy(last.text) }
                        Button("Paste again") { dismiss(); controller.pasteLast() }
                    }
                    .controlSize(.small)
                    .buttonStyle(.glass)
                }
                .padding(10)
                .background(.fill.quaternary, in: .rect(cornerRadius: 10))
            }

            Divider()

            VStack(spacing: 2) {
                MenuRow(title: "Open \(AppInfo.name)", shortcut: nil) {
                    dismiss(); NSApp.activate(); openWindow(id: WindowID.main)
                }
                MenuRow(title: "Settings…", shortcut: "⌘,") {
                    dismiss(); NSApp.activate(); openSettings()
                }
                MenuRow(title: controller.isPaused ? "Resume dictation" : "Pause dictation", shortcut: nil) {
                    controller.isPaused.toggle()
                }
                MenuRow(title: "Quit \(AppInfo.name)", shortcut: "⌘Q") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

/// "Ready" with a green dot, plus which engine is in use.
struct EngineStatus: View {
    @Environment(DictationController.self) private var controller

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hasKey: Bool { Keychain.groqKey != nil }

    private var color: Color {
        if controller.phase == .listening { return .red }
        if controller.isPaused || !controller.accessibilityTrusted { return .orange }
        return .green
    }

    private var label: String {
        if controller.phase == .listening { return "Listening" }
        if controller.isPaused { return "Paused" }
        if !controller.accessibilityTrusted { return "Needs Accessibility" }
        if !controller.connectivity.isOnline || !hasKey { return "Ready, on this Mac" }
        if controller.keyRejected { return "Ready, Groq key rejected" }
        return "Ready, Groq cloud"
    }
}

private struct MenuRow: View {
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(hover ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct KeyCaps: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k)
                    .font(.system(size: 11, weight: .medium))
                    .frame(minWidth: 18, minHeight: 18)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 4))
            }
        }
        .foregroundStyle(.secondary)
    }
}
