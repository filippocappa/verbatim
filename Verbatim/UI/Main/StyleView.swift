import AppKit
import SwiftData
import SwiftUI

/// Pick how dictation sounds in each app: formal in Mail, casual in Messages.
struct StyleView: View {
    @Query(sort: \Dictation.date, order: .reverse) private var history: [Dictation]
    @State private var added: [String] = []
    @State private var version = 0
    @State private var examplesRound = 0
    @State private var editingTones = UserDefaults.standard.bool(forKey: "editTones")

    var body: some View {
        let apps = rows
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("How you sound in each app")
                            .font(.pageTitle)
                        Text("Slide to pick a tone. The example shows how the same thing comes out.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit Tones", systemImage: "slider.horizontal.3") { editingTones = true }
                        .buttonStyle(.glass)
                        .help("See and change what each tone tells the AI")
                }
                .padding(.bottom, 4)

                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(Array(stride(from: 0, to: apps.count + 1, by: 2)), id: \.self) { start in
                        GridRow {
                            ForEach(start..<start + 2, id: \.self) { i in
                                if i < apps.count {
                                    AppToneCard(bundleID: apps[i], version: $version)
                                } else if i == apps.count {
                                    addCard
                                } else {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                }
                            }
                        }
                    }
                }

                Text("Apps not listed here use Normal. Chat apps start as Casual and mail apps as Formal. Exact skips cleanup, so you get what was heard, fillers and all. Custom follows instructions you write in Edit Tones.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Style")
        .toolbarTitleDisplayMode(.inline)
        .sheet(isPresented: $editingTones, onDismiss: { version += 1; examplesRound += 1 }) { ToneEditor() }
        // Apps without a tailored example get one from the model, in the background.
        .task(id: "\(apps)\(examplesRound)") {
            if await ToneExamples.fill(apps, name: AppToneRow.name) { version += 1 }
        }
    }

    private var addCard: some View {
        Button(action: pickApp) {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.title2)
                Text("Add App")
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 120)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    /// Chat and mail apps that are installed, apps you've dictated into, and any you added.
    private var rows: [String] {
        _ = version
        var seen = Set<String>()
        var out: [String] = []
        func add(_ id: String) {
            guard !seen.contains(id), id != AppInfo.bundleID,
                  NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else { return }
            seen.insert(id)
            out.append(id)
        }
        let saved = (UserDefaults.standard.dictionary(forKey: Styles.key) as? [String: String])?.keys.sorted() ?? []
        saved.forEach(add)
        added.forEach(add)
        Styles.chatApps.sorted().forEach(add)
        Styles.mailApps.sorted().forEach(add)
        var used: [String: Int] = [:]
        for d in history { if let id = d.appBundleID { used[id, default: 0] += d.words } }
        used.sorted { $0.value > $1.value }.prefix(20).map(\.key).forEach(add)
        return out.sorted { AppToneRow.name($0).localizedCaseInsensitiveCompare(AppToneRow.name($1)) == .orderedAscending }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { added.append(id) }
        }
    }
}

private struct AppToneCard: View {
    let bundleID: String
    @Binding var version: Int

    var body: some View {
        let tone = Binding(
            get: { _ = version; return Styles.tone(for: bundleID) },
            set: { Styles.set($0, for: bundleID); version += 1 }
        )
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: AppToneRow.icon(bundleID))
                    .resizable()
                    .frame(width: 26, height: 26)
                Text(AppToneRow.name(bundleID)).font(.headline)
            }
            ToneSlider(selection: tone)
            let _ = version
            Text(tone.wrappedValue == .custom && Tone.custom.rule == nil
                 ? tone.wrappedValue.example(Styles.kind(bundleID))
                 : ToneExamples.example(tone.wrappedValue, for: bundleID) ?? tone.wrappedValue.example(Styles.kind(bundleID)))
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.tertiary, in: .rect(cornerRadius: 10))
                .id(tone.wrappedValue)
                .transition(.opacity)
                .textSelection(.enabled)
        }
        .padding(16)
        .tile()
    }
}

/// The tones left to right, from most polished to untouched, with a knob that slides between them.
private struct ToneSlider: View {
    @Binding var selection: Tone

    var body: some View {
        let all = Tone.allCases
        let index = all.firstIndex(of: selection) ?? 0
        VStack(spacing: 6) {
            GeometryReader { geo in
                let step = geo.size.width / CGFloat(all.count)
                ZStack(alignment: .leading) {
                    Capsule().fill(.fill.tertiary)
                    Capsule().fill(.primary)
                        .frame(width: step - 6)
                        .padding(.vertical, 3)
                        .offset(x: step * CGFloat(index) + 3)
                    HStack(spacing: 0) {
                        ForEach(all) { t in
                            Image(systemName: t.symbol)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(t == selection ? AnyShapeStyle(.background) : AnyShapeStyle(.secondary))
                                .frame(width: step)
                                .help(t.title)
                        }
                    }
                }
                .contentShape(.capsule)
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let i = min(all.count - 1, max(0, Int(value.location.x / step)))
                    if all[i] != selection {
                        withAnimation(.spring(duration: 0.3, bounce: 0.2)) { selection = all[i] }
                    }
                })
            }
            .frame(height: 34)
            HStack(spacing: 0) {
                ForEach(all) { t in
                    Text(t.title)
                        .font(.caption)
                        .fontWeight(t == selection ? .semibold : .regular)
                        .foregroundStyle(t == selection ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

enum AppToneRow {
    static func name(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ id: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Shows what each tone adds to the cleanup instructions, and lets you change it.
private struct ToneEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [Tone: String] = Dictionary(uniqueKeysWithValues: Tone.allCases.map { ($0, $0.rule ?? "") })
    @State private var showBase = false

    private let editable: [Tone] = [.formal, .normal, .casual, .veryCasual, .custom]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tones").font(.title2.weight(.semibold))
                        Text("Every tone starts from the same cleanup: drop the ums, fix punctuation and capitals, keep your words. The instructions below are added on top. Formal also smooths clumsy sentences. Exact skips the AI, so it has nothing to edit.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(editable) { tone in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Image(systemName: tone.symbol)
                                    .frame(width: 28, height: 28)
                                    .background(.fill.tertiary, in: .rect(cornerRadius: 7))
                                Text(tone.title).font(.headline)
                                Spacer()
                                if rules[tone] != (tone.defaultRule ?? "") {
                                    Button("Reset") { rules[tone] = tone.defaultRule ?? "" }
                                        .buttonStyle(.borderless)
                                        .font(.callout)
                                }
                            }
                            TextField("", text: binding(tone),
                                      prompt: Text(tone == .custom
                                                   ? "For example: Write in short lines. Use British spelling. No exclamation marks."
                                                   : "Nothing added. It gets the plain cleanup."),
                                      axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.callout)
                                .lineLimit(3...12)
                                .padding(10)
                                .background(.fill.quinary, in: .rect(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
                        }
                    }

                    DisclosureGroup("The cleanup instructions every tone starts from", isExpanded: $showBase) {
                        Text(Cleanup.systemPrompt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                    .font(.callout)
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
    }

    private func binding(_ tone: Tone) -> Binding<String> {
        Binding(get: { rules[tone] ?? "" }, set: { rules[tone] = $0 })
    }

    private func save() {
        for tone in editable {
            let text = (rules[tone] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Same as the built-in one: forget the change, so later improvements to it still arrive.
            let before = tone.rule ?? ""
            tone.setRule(text == (tone.defaultRule ?? "") ? nil : text)
            // The tailored examples follow the instructions, so write them again.
            if (tone.rule ?? "") != before { ToneExamples.clear() }
        }
    }
}
