import SwiftUI

/// The floating pill. One Liquid Glass capsule that reshapes itself as the dictation moves along.
struct PillView: View {
    @Environment(DictationController.self) private var controller
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer {
            if controller.phase != .idle {
                PillContent(phase: controller.phase, levels: controller.levels, startedAt: controller.startedAt,
                            command: controller.command, note: controller.writingNote, onUndo: controller.undoLearned)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("pill", in: glass)
                    .glassEffectTransition(.materialize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 18)
        .animation(.spring(duration: 0.38, bounce: 0.16), value: controller.phase)
    }
}

/// What's inside the capsule for each phase. Kept separate so previews can show every state.
struct PillContent: View {
    let phase: DictationController.Phase
    var levels: [Float] = []
    var startedAt: Date?
    var command: DictationController.CommandKind?
    var note: String?
    var onUndo: () -> Void = {}

    private var tag: String? {
        switch command {
        case .rewrite: "Edit selection"
        case .action: "Command"
        case nil: language == "auto" ? nil : language.uppercased()
        }
    }

    @AppStorage(Prefs.Key.language) private var language = "auto"

    var body: some View {
        Group {
            switch phase {
            case .idle:
                EmptyView()

            case .listening:
                HStack(spacing: 12) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.red)
                        .shadow(color: .red.opacity(0.7), radius: 4)
                        .symbolEffect(.pulse, options: .repeating)
                    Waveform(levels: levels)
                    Elapsed(since: startedAt ?? .now)
                    if let tag {
                        Text(tag)
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: .capsule)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, tag != nil ? 9 : 16)

            case .writing:
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(command == .rewrite ? "Rewriting" : command == .action ? "Working" : "Writing")
                    if let note {
                        Text(note).foregroundStyle(.secondary).transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)

            case let .pasted(words, latencyMs, offline):
                HStack(spacing: 9) {
                    StatusBadge(symbol: "checkmark", fill: offline ? Color.secondary : Color.green)
                    Text(words == 1 ? "1 word" : "\(words) words")
                    Text(offline ? "offline, on this Mac" : Format.seconds(latencyMs))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.leading, 9)
                .padding(.trailing, 16)

            case .copied:
                HStack(spacing: 9) {
                    StatusBadge(symbol: "doc.on.clipboard", fill: .secondary)
                    Text("Copied")
                    Text("no text box here, press ⌘V to paste").foregroundStyle(.secondary)
                }
                .padding(.leading, 9)
                .padding(.trailing, 16)

            case let .learned(word):
                HStack(spacing: 9) {
                    Image(systemName: "character.book.closed")
                    Text("Learned \(Text(word).fontWeight(.semibold))")
                    PillButton(title: "Undo", action: onUndo)
                }
                .padding(.leading, 15)
                .padding(.trailing, 7)

            case let .done(symbol, title, detail):
                HStack(spacing: 9) {
                    StatusBadge(symbol: symbol, fill: symbol == "doc.on.clipboard" ? Color.secondary : Color.green)
                    Text(title)
                    if let detail {
                        Text(detail).foregroundStyle(.secondary)
                            .truncationMode(.tail).frame(maxWidth: 300, alignment: .leading)
                    }
                }
                .padding(.leading, 9)
                .padding(.trailing, 16)

            case let .notice(notice):
                NoticeContent(notice: notice)

            case let .meeting(pill):
                MeetingContent(pill: pill)
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .frame(height: 40)
        .fixedSize()
    }
}

private struct NoticeContent: View {
    let notice: DictationController.Notice

    var body: some View {
        HStack(spacing: 9) {
            switch notice {
            case .nothingHeard:
                Image(systemName: "mic.slash").foregroundStyle(.secondary)
                Text("Didn't catch anything")
            case .micDenied:
                Image(systemName: "mic.slash").foregroundStyle(.orange)
                Text("Microphone is off for \(AppInfo.name)")
                PillButton(title: "Open Settings") { Permissions.openMicrophoneSettings() }
            case .needsAccessibility:
                Image(systemName: "lock").foregroundStyle(.orange)
                Text("Allow Accessibility to paste")
                PillButton(title: "Open Settings") { Permissions.requestAccessibility() }
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(message).truncationMode(.tail).frame(maxWidth: 340, alignment: .leading)
            }
        }
        .padding(.leading, 15)
        .padding(.trailing, notice == .micDenied || notice == .needsAccessibility ? 7 : 16)
    }
}

private struct MeetingContent: View {
    let pill: DictationController.MeetingPill

    var body: some View {
        switch pill {
        case let .offer(_, title, bundleID):
            HStack(spacing: 9) {
                AppIcon(bundleID: bundleID)
                Text(title)
                Text("Take notes?").foregroundStyle(.secondary)
                PillButton(title: "Take Notes") { MeetingController.shared.start() }
                Button { DictationController.shared.dismiss() } label: {
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
                    DictationController.shared.dismiss()
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
private struct AppIcon: View {
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

private struct StatusBadge: View {
    let symbol: String
    let fill: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(fill, in: .circle)
    }
}

private struct PillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(.quaternary, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Bars that follow the voice, newest on the right.
struct Waveform: View {
    let levels: [Float]
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 22

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.primary)
                    .frame(width: barWidth, height: 3 + CGFloat(levels[i]) * (maxHeight - 3))
                    .opacity(i < 3 ? 0.35 + Double(i) * 0.2 : 1)
            }
        }
        .frame(height: maxHeight)
        .animation(.linear(duration: 0.07), value: levels)
    }
}

private struct Elapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(since)))
            Text("\(s / 60):\(String(format: "%02d", s % 60))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

#if DEBUG
extension DictationController.Phase {
    static let gallery: [DictationController.Phase] = [
        .listening, .writing, .pasted(words: 38, latencyMs: 412, offline: false),
        .learned(word: "Supabase"), .pasted(words: 38, latencyMs: 1630, offline: true), .notice(.nothingHeard),
    ]
}

let sampleLevels: [Float] = [0.1, 0.2, 0.35, 0.6, 0.45, 0.8, 0.55, 0.3, 0.7, 0.9, 0.5, 0.35, 0.6, 0.75, 0.4, 0.25, 0.5, 0.65, 0.3, 0.2, 0.15, 0.1]

#Preview("Pill states") {
    VStack(spacing: 18) {
        ForEach(Array(DictationController.Phase.gallery.enumerated()), id: \.offset) { _, phase in
            PillContent(phase: phase, levels: sampleLevels, startedAt: .now.addingTimeInterval(-14))
                .glassEffect(.regular, in: .capsule)
        }
    }
    .padding(40)
    .frame(width: 520)
}
#endif
