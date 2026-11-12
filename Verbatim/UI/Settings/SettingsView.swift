import ServiceManagement
import SwiftUI

/// The ⌘, window: a sidebar like the main window's, with the pages on the right.
struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general, speech, permissions
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .speech: "waveform"
            case .permissions: "lock.shield"
            }
        }
    }

    // `-settingsTab speech` opens on a given page (handy for screenshots).
    @State private var section = UserDefaults.standard.string(forKey: "settingsTab").flatMap(Section.init(rawValue:)) ?? .general

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(section) }, set: { if let s = $0 { section = s } })) {
                ForEach(Section.allCases) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                }
            }
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch section {
                case .general: GeneralSettings()
                case .speech: SpeechSettings()
                case .permissions: PermissionSettings()
                }
            }
            .navigationTitle(section.title)
        }
        // 16:9, like a small version of the main window. Every page scrolls inside it, so it never resizes.
        .frame(width: 960, height: 540)
    }
}

// MARK: - Building blocks

/// A titled tile of rows with hairlines between them.
private struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows.indices, id: \.self) { i in
                        if i > 0 { Divider().padding(.leading, 52) }
                        rows[i]
                    }
                }
            }
            .background(.fill.quinary, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(.fill.tertiary, in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct Switch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(Prefs.Key.sounds) private var sounds = true
    @AppStorage(Prefs.Key.pillPlace) private var place = "pill"
    @AppStorage(Prefs.Key.keepOnClipboard) private var keepOnClipboard = true
    @AppStorage(Prefs.Key.learnFromCorrections) private var learn = true
    @AppStorage(Prefs.Key.typingWPM) private var typingWPM = 40
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        SettingsPage {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppInfo.name).font(.title2.weight(.semibold))
                    EngineStatus()
                }
                Spacer()
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            SettingsGroup(title: "Shortcuts") {
                SettingsRow(symbol: "mic", title: "Dictate", detail: "Double-tap the right ⌘ to start, tap it once to stop and paste.") {
                    KeyCaps(keys: ["⌘", "⌘"])
                }
                SettingsRow(symbol: "command", title: "Command", detail: "Double-tap the right ⌥. Rewrite the selection, or open and search.") {
                    KeyCaps(keys: ["⌥", "⌥"])
                }
                SettingsRow(symbol: "xmark", title: "Throw it away", detail: "While recording or writing.") {
                    KeyCaps(keys: ["esc"])
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Where it shows").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                PlacePicker(place: $place)
            }

            SettingsGroup(title: "While you dictate") {
                SettingsRow(symbol: "speaker.wave.2", title: "Sounds", detail: "A short sound when it starts and stops.") {
                    Switch(isOn: $sounds)
                }
                SettingsRow(symbol: "doc.on.clipboard", title: "Keep it on the clipboard",
                            detail: "So ⌘V pastes it again. When off, your previous clipboard comes back.") {
                    Switch(isOn: $keepOnClipboard)
                }
                SettingsRow(symbol: "character.book.closed", title: "Learn from my fixes",
                            detail: "Correct a name right after pasting and it goes in your Dictionary.") {
                    Switch(isOn: $learn)
                }
            }

            SettingsGroup(title: "Mac", footer: "Your typing speed is used for “time saved” and “faster than typing”.") {
                SettingsRow(symbol: "power", title: "Open at login") {
                    Switch(isOn: $openAtLogin)
                        .onChange(of: openAtLogin) { _, on in
                            do {
                                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch {
                                openAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
                SettingsRow(symbol: "keyboard", title: "Your typing speed") {
                    HStack(spacing: 6) {
                        Text("\(typingWPM) wpm").monospacedDigit().foregroundStyle(.secondary)
                        Stepper("", value: $typingWPM, in: 10...150, step: 5).labelsHidden()
                    }
                }
            }
        }
    }
}

// MARK: - Speech

private struct SpeechSettings: View {
    @AppStorage(Prefs.Key.language) private var language = "auto"
    @AppStorage(Prefs.Key.offlineLanguage) private var offlineLanguage = "en"
    @AppStorage(Prefs.Key.microphone) private var microphone = Microphone.automatic
    @AppStorage(Prefs.Key.cleanupModel) private var model = Prefs.defaultCleanupModel
    @AppStorage(Prefs.Key.speechEngine) private var engine = "groq"
    @State private var models = LocalModels.shared
    @State private var inputs = Microphone.inputs()
    @State private var advanced = false

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Microphone",
                          footer: "Automatic uses your Mac's microphone when AirPods or another Bluetooth headset is connected, so your music doesn't cut out.") {
                SettingsRow(symbol: "mic", title: "Record from") {
                    Picker("", selection: $microphone) {
                        Text("Automatic").tag(Microphone.automatic)
                        Divider()
                        ForEach(inputs) { d in
                            Text(d.isBluetooth ? "\(d.name) (cuts your audio)" : d.name).tag(d.uid)
                        }
                        if microphone != Microphone.automatic, !inputs.contains(where: { $0.uid == microphone }) {
                            Text("Not connected").tag(microphone)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onAppear { inputs = Microphone.inputs() }
                }
            }

            SettingsGroup(title: "Languages") {
                SettingsRow(symbol: "globe", title: "You speak") {
                    Picker("", selection: $language) {
                        Text("English and Italian").tag("auto")
                        Text("English").tag("en")
                        Text("Italian").tag("it")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if models.active == nil {
                SettingsRow(symbol: "wifi.slash", title: "Offline, listen for",
                            detail: "Apple's on-device engine takes one language at a time.") {
                    Picker("", selection: $offlineLanguage) {
                        Text("English").tag("en")
                        Text("Italian").tag("it")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(language != "auto")
                }
                }
            }

            SettingsGroup(title: "Engines", footer: enginesFooter) {
                SettingsRow(symbol: "arrow.triangle.branch", title: "Speech goes to",
                            detail: engine == "local" ? "A model on this Mac. Your voice never leaves it." : "Groq when you're online, a model on this Mac otherwise.") {
                    Picker("", selection: $engine) {
                        Text("Groq first").tag("groq")
                        Text("Only this Mac").tag("local")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(symbol: "cloud", title: "Groq", detail: "Whisper large v3 turbo in the cloud. The fastest, English and Italian in one go.") {
                    Text(Keychain.groqKey == nil ? "No key" : engine == "local" ? "Off" : "In use").foregroundStyle(.secondary)
                }
                ForEach(LocalModel.allCases) { LocalModelRow(model: $0) }
                SettingsRow(symbol: "apple.logo", title: "Apple", detail: "Built into macOS, nothing to download. One language at a time.") {
                    Text(models.active == nil ? (Keychain.groqKey == nil || engine == "local" ? "In use" : "Backup") : "Last resort")
                        .foregroundStyle(.secondary)
                }
            }

            SettingsGroup(title: "Groq",
                          footer: "Speech goes to Groq's Whisper and comes back in a fraction of a second. Without a key, or offline, \(AppInfo.name) uses Apple's speech engine on this Mac.") {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRow(symbol: "key", title: "API key") { EmptyView() }
                    GroqKeyField()
                        .padding(.leading, 52)
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                }
            }

            GroqUsageGroup()

            SettingsGroup(title: "Advanced") {
                SettingsRow(symbol: "cpu", title: "Cleanup model", detail: "The Groq model that tidies up and rewrites.") {
                    TextField("", text: $model, prompt: Text(Prefs.defaultCleanupModel))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }
        }
    }
}

extension SpeechSettings {
    fileprivate var enginesFooter: String {
        if engine == "local", models.active == nil { return "Download a model above to keep everything on this Mac. Until then, Groq is used." }
        return "Models on this Mac work offline and cost nothing. Cleanup still uses Groq when it's there; it only gets text, never audio."
    }
}

/// One downloadable model: Download, progress, then Use and Delete.
private struct LocalModelRow: View {
    let model: LocalModel
    @State private var models = LocalModels.shared
    @AppStorage(Prefs.Key.localModel) private var chosen = LocalModel.parakeet.rawValue
    @AppStorage(Prefs.Key.speechEngine) private var engine = "groq"
    @State private var confirmDelete = false

    var body: some View {
        SettingsRow(symbol: model == .parakeet ? "bird" : "waveform", title: "\(model.name)  ·  \(model.size)", detail: model.detail) {
            trailing
        }
    }

    @ViewBuilder private var trailing: some View {
        switch models.state(model) {
        case .none:
            Button("Download") { models.download(model) }
        case let .downloading(p):
            HStack(spacing: 8) {
                ProgressView(value: p).frame(width: 90)
                Text(p.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                Button { models.cancel(model) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Stop the download")
            }
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model == .whisper ? "Preparing, ~10 min" : "Preparing…").foregroundStyle(.secondary)
            }
            .help(model == .whisper ? "Getting it ready for this Mac's chip. Only the first time, about 10 minutes."
                                    : "Getting it ready for this Mac's chip. Only the first time, under a minute.")
        case .ready:
            HStack(spacing: 10) {
                if models.active == model {
                    Text(engine == "local" || Keychain.groqKey == nil ? "In use" : "Backup").foregroundStyle(.secondary)
                } else {
                    Button("Use") { chosen = model.rawValue }
                }
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete it to free \(model.size)")
                    .confirmationDialog("Delete \(model.name)?", isPresented: $confirmDelete) {
                        Button("Delete", role: .destructive) { Task { await models.delete(model) } }
                    } message: {
                        Text("Frees \(model.size). You can download it again any time.")
                    }
            }
        case let .failed(message):
            HStack(spacing: 8) {
                Text("Didn't download").foregroundStyle(.orange).help(message)
                Button("Try Again") { models.download(model) }
            }
        }
    }
}

// MARK: - Groq usage

/// How much of the free plan's daily allowance is left. The numbers come from Groq with every dictation;
/// opening this checks again if they're more than a few minutes old.
private struct GroqUsageGroup: View {
    @State private var speech = GroqLimits.load(.speech)
    @State private var cleanup = GroqLimits.load(.cleanup)
    @State private var checking = false

    var body: some View {
        SettingsGroup(title: "Today on Groq's free plan", footer: footer) {
            UsageRow(symbol: "waveform", title: "Transcriptions",
                     detail: "Two per dictation in English and Italian mode, plus one per early part.", usage: speech)
            UsageRow(symbol: "sparkles", title: "Cleanups and commands",
                     detail: "One per dictation over three words, one or two per command.", usage: cleanup)
            if let refusal = GroqLimits.lastRefusal, refusal.date.timeIntervalSinceNow > -86_400 {
                SettingsRow(symbol: "exclamationmark.triangle", title: "Last turned away \(refusal.date.formatted(.relative(presentation: .named)))",
                            detail: refusal.message.components(separatedBy: ". Need more").first) { EmptyView() }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(checking ? "Checking…" : "Check Now") { Task { await check() } }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(checking || Keychain.groqKey == nil)
        }
        .task {
            let newest = [speech?.checked, cleanup?.checked].compactMap { $0 }.max()
            if newest == nil || newest!.timeIntervalSinceNow < -300 { await check() }
        }
    }

    private var footer: String {
        "It isn't a reset at midnight: each one you use comes back on its own, spread over 24 hours. There's also a limit per minute (about 8 dictations in the same minute) and on audio per hour, which Groq doesn't report. When a limit is hit, speech falls back to Apple's engine on this Mac and text pastes without cleanup."
    }

    private func check() async {
        guard let key = Keychain.groqKey else { return }
        checking = true
        await GroqLimits.check(key: key)
        speech = GroqLimits.load(.speech)
        cleanup = GroqLimits.load(.cleanup)
        checking = false
    }
}

private struct UsageRow: View {
    let symbol: String
    let title: String
    let detail: String
    let usage: GroqLimits.Usage?

    var body: some View {
        SettingsRow(symbol: symbol, title: title, detail: detail) {
            if let usage {
                let left = usage.left
                let low = Double(left) < Double(usage.limit) * 0.1
                VStack(alignment: .trailing, spacing: 5) {
                    Text("\(left.formatted()) of \(usage.limit.formatted()) left")
                        .monospacedDigit()
                        .foregroundStyle(low ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                    Capsule().fill(.quaternary)
                        .frame(width: 120, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(low ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                                .frame(width: 120 * CGFloat(left) / CGFloat(max(usage.limit, 1)))
                        }
                    Text(left < usage.limit ? "+1 every \(usage.refillEvery) · full \(usage.fullAt.formatted(.relative(presentation: .named)))"
                                            : "+1 every \(usage.refillEvery) as you use them")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Not checked yet").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionSettings: View {
    @Environment(DictationController.self) private var controller
    @State private var mic = Permissions.microphone

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "\(AppInfo.name) needs", footer: "Nothing is recorded unless you double-tap the right ⌘ or ⌥.") {
                SettingsRow(symbol: "mic", title: "Microphone", detail: "To hear what you say.") {
                    status(mic == .allowed) {
                        if mic == .notAsked {
                            Task { _ = await Permissions.requestMicrophone(); mic = Permissions.microphone }
                        } else {
                            Permissions.openMicrophoneSettings()
                        }
                    }
                }
                SettingsRow(symbol: "accessibility", title: "Accessibility",
                            detail: "To paste, use the shortcuts and notice your fixes.") {
                    status(controller.accessibilityTrusted) { Permissions.requestAccessibility() }
                }
            }
        }
        .onAppear { mic = Permissions.microphone; controller.refreshAccessibility() }
    }

    @ViewBuilder
    private func status(_ allowed: Bool, _ action: @escaping () -> Void) -> some View {
        if allowed {
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        } else {
            Button("Allow…", action: action)
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let allowed: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if allowed {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Allow…", action: action)
            }
        }
    }
}

struct GroqKeyField: View {
    @State private var key = Keychain.groqKey ?? ""
    @State private var status: Status = .idle

    enum Status: Equatable { case idle, testing, ok, failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SecureField("API key", text: $key, prompt: Text("Paste your key, starts with gsk_"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onSubmit(test)
                Button(status == .testing ? "Testing…" : "Save and test", action: test)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || status == .testing)
            }
            HStack(spacing: 6) {
                switch status {
                case .idle:
                    Link(destination: URL(string: "https://console.groq.com/keys")!) {
                        Text("Get a free key at console.groq.com").underline()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                case .testing:
                    ProgressView().controlSize(.mini)
                case .ok:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Works. Saved in your keychain.").font(.caption)
                case let .failed(message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.caption).lineLimit(2)
                }
            }
        }
    }

    private func test() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        status = .testing
        Task {
            switch await Groq.validate(key: k) {
            case .success:
                Keychain.groqKey = k
                status = .ok
            case let .failure(error):
                status = .failed(error.localizedDescription)
            }
        }
    }
}


// MARK: - Pill or Notch

/// Two small screens, each playing what you'd see: a dictation, then a call offer. Click one to pick it.
private struct PlacePicker: View {
    @Binding var place: String
    /// false: dictating. true: a call just started.
    @State private var call = false

    var body: some View {
        HStack(spacing: 12) {
            card("pill", title: "Pill", detail: "Dictation at the bottom. Calls at the top, clear of the call's buttons.")
            card("notch", title: "Notch", detail: "Everything drops down from the notch, small and black.")
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.4))
                withAnimation(.spring(duration: 0.45, bounce: 0.22)) { call.toggle() }
            }
        }
    }

    private func card(_ value: String, title: String, detail: String) -> some View {
        let selected = place == value
        return Button { withAnimation(.snappy) { place = value } } label: {
            VStack(alignment: .leading, spacing: 10) {
                MiniScreen(notch: value == "notch", call: call)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? .primary : .tertiary)
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.callout.weight(.medium))
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .background(.fill.quinary, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.separator.opacity(0.6)), lineWidth: selected ? 1.5 : 0.5))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

/// A tiny Mac screen: menu bar, notch, and the pill or island where it would really be.
private struct MiniScreen: View {
    let notch: Bool
    let call: Bool

    private let menuBar: CGFloat = 11

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.42), Color(white: 0.22)], startPoint: .top, endPoint: .bottom)
            // Menu bar, and the notch in it.
            Rectangle().fill(.black.opacity(0.28)).frame(height: menuBar)

            if notch {
                island
            } else {
                UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4).fill(.black)
                    .frame(width: 42, height: menuBar)
                if call {
                    MiniCall().glassEffect(.regular, in: .capsule)
                        .padding(.top, menuBar + 5)
                        .transition(.opacity.combined(with: .scale(0.8, anchor: .top)))
                } else {
                    MiniDictation().glassEffect(.regular, in: .capsule)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .scale(0.8, anchor: .bottom)))
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .frame(height: 150)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
        .allowsHitTesting(false)
    }

    /// The black island, grown out of the notch.
    private var island: some View {
        ZStack {
            Group {
                if call { MiniCall() } else { MiniDictation() }
            }
            .id(call)
            .transition(.opacity.combined(with: .scale(0.85, anchor: .top)))
        }
        .padding(.top, menuBar)
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
        .frame(minWidth: 42)
        .background(NotchShape(bottomRadius: 9, topRadius: 3).fill(.black))
    }
}

/// The dictation pill, shrunk: record dot, voice bars, time.
private struct MiniDictation: View {
    private let bars: [CGFloat] = [3, 5, 8, 6, 10, 7, 4, 9, 6, 3, 5, 7, 4, 2]

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.red).frame(width: 4, height: 4)
            HStack(spacing: 1.2) {
                ForEach(bars.indices, id: \.self) { i in
                    Capsule().fill(.white).frame(width: 1.5, height: bars[i])
                }
            }
            Text("0:04").font(.system(size: 6.5)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 7)
        .frame(height: 17)
    }
}

/// The call offer, shrunk: logo, name, Take Notes.
private struct MiniCall: View {
    var body: some View {
        HStack(spacing: 4) {
            if let logo = ServiceLogos.shared.image("meet.google.com") {
                Image(nsImage: logo).resizable().frame(width: 8, height: 8)
            } else {
                Image(systemName: "video.fill").font(.system(size: 6))
            }
            Text("Google Meet").font(.system(size: 6.5))
            Text("Take Notes").font(.system(size: 5.5, weight: .medium))
                .padding(.horizontal, 4).frame(height: 10)
                .background(.white.opacity(0.18), in: .capsule)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(height: 17)
    }
}
