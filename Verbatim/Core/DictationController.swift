import AppKit
import AVFoundation
import Observation
import os
import SwiftData

/// The whole dictation loop: ⌘⌘ → record → transcribe → clean up → paste → watch for fixes.
/// ⌥⌥ records a command instead: rewrite the selected text, or open / search something.
@Observable
final class DictationController {
    static let shared = DictationController()

    enum Notice: Equatable {
        case nothingHeard
        case micDenied
        case needsAccessibility
        case failed(String)
    }

    enum MeetingPill: Equatable {
        case offer(app: String, title: String, bundleID: String, service: String?)
        case started(title: String)
        case stopped
        /// Recording, but the call is silent: almost always the System Audio Recording permission.
        case cantHear
        case writingNotes
        case saved(URL)
        case failed(String)
    }

    enum Phase: Equatable {
        case idle
        case listening
        case writing
        case pasted(words: Int, latencyMs: Int, offline: Bool)
        /// No text box was focused, so the text went to the clipboard only.
        case copied(words: Int)
        case learned(word: String)
        /// A command ran: "Opened YouTube", "Rewrote", "Searched Google · lo-fi".
        case done(symbol: String, title: String, detail: String?)
        case notice(Notice)

        var isBusy: Bool { self == .listening || self == .writing }
        /// The pill takes clicks only when it has a button.
        var isInteractive: Bool {
            switch self {
            case .learned, .notice(.needsAccessibility), .notice(.micDenied): true
            default: false
            }
        }
    }

    private(set) var phase: Phase = .idle {
        didSet {
            if phase != oldValue { onPhaseChange?(phase) }
            if phase != .listening, liveTask != nil { liveTask?.cancel(); liveTask = nil }
            // The words stay up while the real text is written, and go when it's pasted.
            if phase != .listening, phase != .writing, !live.isEmpty || liveCard {
                live = LiveText()
                liveCard = false
            }
        }
    }
    /// What it's heard so far while you talk, when "Show words as you talk" is on. Only for showing: the text
    /// that's pasted still comes from the usual engine.
    private(set) var live = LiveText()
    /// The live words go in their own card on the pill. False: in the pill itself, for commands and translations.
    private(set) var liveCard = false
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    /// Recent loudness values, oldest first, for the live waveform.
    private(set) var levels: [Float] = Array(repeating: 0, count: DictationController.levelCount)
    private(set) var startedAt: Date?
    /// Set while recording or running a command (⌥⌥), nil for plain dictation.
    private(set) var command: CommandKind?
    /// A second line for the "Writing" pill, e.g. when Groq is slow and the Mac takes over.
    private(set) var writingNote: String?

    enum CommandKind: Equatable {
        case rewrite // text was selected
        case action  // open or search
        case translate // dictation, pasted in the other language (Italian ↔ English)
        case assistant // nothing selected and not open/search: writes at the cursor or answers, using the screen
    }
    private(set) var accessibilityTrusted = AXIsProcessTrusted()
    private(set) var keyRejected = false
    var isPaused = Prefs.paused {
        didSet { Prefs.paused = isPaused; if isPaused { cancel() } }
    }
    let connectivity = Connectivity()

    @ObservationIgnored var onPhaseChange: ((Phase) -> Void)?
    /// The assistant answered a question: what was said, and the answer.
    @ObservationIgnored var onAnswer: ((String, String) -> Void)?

    /// Meeting messages, shown from the notch, separate from the dictation pill so the two never collide.
    private(set) var meetingPill: MeetingPill? {
        didSet { if meetingPill != oldValue { onMeetingChange?(meetingPill) } }
    }
    @ObservationIgnored var onMeetingChange: ((MeetingPill?) -> Void)?
    @ObservationIgnored private var meetingDismiss: Task<Void, Never>?

    static let levelCount = 22

    @ObservationIgnored private let hotkey = ModifierTapMonitor(.command)
    @ObservationIgnored private let commandKey = ModifierTapMonitor(.option)
    @ObservationIgnored private var lastOptionTap: TimeInterval = 0
    @ObservationIgnored private let translateKey = ModifierTapMonitor(.shift)
    @ObservationIgnored private var lastShiftTap: TimeInterval = 0
    @ObservationIgnored private var selection: Task<String?, Never>?
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let watcher = CorrectionWatcher()
    @ObservationIgnored private var lastTap: TimeInterval = 0
    @ObservationIgnored private var field: FocusedField?
    @ObservationIgnored private var targetApp: NSRunningApplication?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    @ObservationIgnored private var trustPoll: Timer?
    @ObservationIgnored private var lastLearned: Vocabulary.Change?
    /// Long dictations: parts already sent to Groq while you keep talking, each ending at a pause.
    /// The task is nil for a part that was only silence.
    @ObservationIgnored private var parts: [(end: Int, task: Task<Groq.Transcript?, Never>?)] = []
    @ObservationIgnored private var partWatcher: Task<Void, Never>?

    private let log = Logger(subsystem: AppInfo.bundleID, category: "dictation")
    private let signposter = OSSignposter(subsystem: AppInfo.bundleID, category: "pipeline")

    private init() {}

    // MARK: Lifecycle

    func start() {
        hotkey.onTap = { [weak self] t in self?.handleTap(t) }
        hotkey.onEscape = { [weak self] in self?.cancel() }
        hotkey.start()
        commandKey.onTap = { [weak self] t in self?.handleOptionTap(t) }
        commandKey.start()
        translateKey.onTap = { [weak self] t in self?.handleShiftTap(t) }
        translateKey.start()

        recorder.onLevel = { [weak self] level in self?.push(level) }

        watcher.onFixes = { [weak self] fixes in self?.learn(fixes) }

        if !accessibilityTrusted { pollAccessibility() }

        // Have the offline model ready before it's needed, and again whenever the language changes.
        AppleTranscriber.prepare(offlineLanguage)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                AppleTranscriber.prepare(self.offlineLanguage)
            }
        }
    }

    /// Global key monitors only start delivering once Accessibility is granted, so re-arm them when it is.
    private func pollAccessibility() {
        trustPoll?.invalidate()
        trustPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.trustPoll?.invalidate()
                self.trustPoll = nil
                self.accessibilityTrusted = true
                self.hotkey.start()
                self.commandKey.start()
                self.translateKey.start()
            }
        }
    }

    func refreshAccessibility() {
        accessibilityTrusted = AXIsProcessTrusted()
        if !accessibilityTrusted { pollAccessibility() }
    }

    // MARK: Hotkey

    private func handleTap(_ t: TimeInterval) {
        guard t >= 0 else { lastTap = 0; return }
        if phase == .listening {
            finish()
            lastTap = 0
            return
        }
        if lastTap > 0, t - lastTap < 0.4 {
            lastTap = 0
            begin()
        } else {
            lastTap = t
        }
    }

    private func handleOptionTap(_ t: TimeInterval) {
        guard t >= 0 else { lastOptionTap = 0; return }
        if phase == .listening {
            finish()
            lastOptionTap = 0
            return
        }
        if lastOptionTap > 0, t - lastOptionTap < 0.4 {
            lastOptionTap = 0
            begin(command: true)
        } else {
            lastOptionTap = t
        }
    }

    private func handleShiftTap(_ t: TimeInterval) {
        guard t >= 0 else { lastShiftTap = 0; return }
        if phase == .listening {
            finish()
            lastShiftTap = 0
            return
        }
        if lastShiftTap > 0, t - lastShiftTap < 0.4 {
            lastShiftTap = 0
            begin(translate: true)
        } else {
            lastShiftTap = t
        }
    }

    /// Start/stop from a button in the app. Our own window is in front, so step aside first
    /// so the text lands where the user was typing.
    func toggleFromUI() {
        if phase == .listening { finish(); return }
        if NSApp.isActive {
            NSApp.hide(nil)
            Task { try? await Task.sleep(for: .milliseconds(220)); begin() }
        } else {
            begin()
        }
    }

    // MARK: Recording

    func begin(command isCommand: Bool = false, translate: Bool = false) {
        guard !isPaused, !phase.isBusy else { return }
        if isCommand || translate, Keychain.groqKey == nil || !connectivity.isOnline {
            let what = isCommand ? "Commands" : "Translating"
            show(.notice(.failed(Keychain.groqKey == nil ? "\(what) needs a Groq key" : "\(what) needs the internet")))
            return
        }
        guard AXIsProcessTrusted() else { show(.notice(.needsAccessibility)); return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .audio) { begin(command: isCommand) } else { show(.notice(.micDenied)) }
            }
            return
        default:
            show(.notice(.micDenied)); return
        }

        dismissTask?.cancel()
        watcher.flush() // a fix made just before this dictation still counts
        do {
            try recorder.start(device: Microphone.choose(Prefs.microphone))
        } catch {
            show(.notice(.failed("Couldn't start the microphone")))
            return
        }
        targetApp = NSWorkspace.shared.frontmostApplication
        field = FocusedField.current()
        selection = nil
        command = translate ? .translate : nil
        if isCommand {
            // Read the selection now, before anything can move it. Accessibility answers instantly;
            // the ⌘C fallback takes a moment, so the pill says "Command" until we know.
            let f = field
            if let text = Commands.selectionViaAccessibility(f) {
                command = text.isEmpty ? .action : .rewrite
                selection = Task { text.isEmpty ? nil : text }
            } else {
                command = .action
                let task = Task { await Commands.copySelection() }
                selection = task
                Task { [weak self] in
                    if await task.value != nil, self?.phase == .listening { self?.command = .rewrite }
                }
            }
        }

        levels = Array(repeating: 0, count: Self.levelCount)
        startedAt = .now
        live = LiveText()
        // Plain dictation shows its words in a card on the pill; commands and translations keep them in the pill.
        liveCard = liveWordsOn && !isCommand && !translate
        phase = .listening
        Sound.play(.start)
        startLiveWords()

        dropParts()
        let local = LocalModels.shared.active
        if !isCommand, Prefs.localOnly || Keychain.groqKey == nil || !connectivity.isOnline { MacModel.prewarm() }
        if let local, Prefs.localOnly || Keychain.groqKey == nil || !connectivity.isOnline {
            // Load the model while you talk, so it's ready when you stop.
            Task { try? await LocalSpeech.shared.warm(local) }
        }
        if let key = Keychain.groqKey, connectivity.isOnline, !(Prefs.localOnly && local != nil) {
            Groq.prewarm(key: key)
            if !isCommand {
                partWatcher = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        self?.sendPartIfPaused(key: key)
                    }
                }
            }
        }

        // Safety net: never record forever if the stop tap gets lost.
        limitTask?.cancel()
        limitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private var liveWordsOn: Bool { Prefs.liveWords && LocalModels.shared.state(.parakeet) == .ready }

    /// A few times a second, Parakeet on this Mac reads what you've said since its last pause (a tenth of a
    /// second or so each time), and LiveTranscript sorts out which words have settled. It never touches
    /// what's pasted.
    private func startLiveWords() {
        liveTask?.cancel()
        liveTask = nil
        guard liveWordsOn else { return }
        let language = Prefs.language == "auto" ? nil : Prefs.language
        liveTask = Task { [weak self] in
            var words = LiveTranscript()
            // Parakeet may have been unloaded since the last dictation: load it now, while you start talking,
            // not on the first read.
            let started = ContinuousClock.now
            try? await LocalSpeech.shared.warm(.parakeet)
            let waited = started.duration(to: .now)
            if waited < .milliseconds(300) { try? await Task.sleep(for: .milliseconds(300) - waited) }
            while !Task.isCancelled {
                guard let self, self.phase == .listening else { return }
                let open = self.recorder.samples(from: words.end, to: self.recorder.sampleCount)
                let changed = await words.advance(open: open, language: language)
                guard !Task.isCancelled, self.phase == .listening else { return }
                if changed { self.live = words.text }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    /// Every second while recording: once there's 15 s of new audio, cut it at the latest pause
    /// and transcribe that part now, so at the end only the last stretch is left to wait for.
    private func sendPartIfPaused(key: String) {
        guard phase == .listening else { return }
        let start = parts.last?.end ?? 0
        let count = recorder.sampleCount
        let rate = Int(AudioRecorder.sampleRate)
        guard count - start >= rate * 15 else { return }
        let pending = recorder.samples(from: start, to: count)
        // The pause must be in the last 4 s and leave a little room before "now", in case it's a word starting.
        guard let at = AudioRecorder.pause(in: Array(pending.dropLast(rate / 5)), lookback: rate * 4) else { return }
        let part = Array(pending[..<at])
        guard AudioRecorder.speechSeconds(part) >= 0.5 else { parts.append((start + at, nil)); return }
        let words = Vocabulary.promptWords(Vocabulary.all())
        let task = Task<Groq.Transcript?, Never> { [weak self] in
            guard let self else { return nil }
            let t = try? await self.cloudTranscript(AudioRecorder.boost(part), key: key, words: words)
            return t.flatMap { Cleanup.isHallucination($0.text) ? Groq.Transcript(text: "", language: $0.language) : $0 }
        }
        parts.append((start + at, task))
        log.info("sent part ending at \(Double(start + at) / Double(rate), format: .fixed(precision: 1)) s")
    }

    private func dropParts() {
        partWatcher?.cancel()
        partWatcher = nil
        for p in parts { p.task?.cancel() }
        parts = []
    }

    private func push(_ level: Float) {
        guard phase == .listening else { return }
        levels.removeFirst()
        levels.append(level)
    }

    /// Esc: drop the recording, or abandon a transcription in flight.
    func cancel() {
        limitTask?.cancel()
        switch phase {
        case .listening:
            _ = recorder.stop()
            dropParts()
            phase = .idle
            command = nil
        case .writing:
            job?.cancel()
            phase = .idle
            command = nil
        default:
            break
        }
    }

    func finish() {
        guard phase == .listening else { return }
        limitTask?.cancel()
        let stoppedAt = ContinuousClock.now
        let (samples, peak) = recorder.stop()
        Sound.play(.stop)
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        // Whisper mode: the floor is low enough for speaking softly; boost() then brings it up to level.
        partWatcher?.cancel()
        let sent = parts
        parts = []
        guard seconds >= 0.3, peak >= 0.0015, AudioRecorder.speechSeconds(samples) >= 0.15 else {
            for p in sent { p.task?.cancel() }
            command = nil
            show(.notice(.nothingHeard)); return
        }
        writingNote = nil
        phase = .writing
        if command == nil || command == .translate {
            // You may have switched apps while talking. ⌘V lands wherever you are now,
            // so that's the app to save in History and to pick the tone for.
            targetApp = NSWorkspace.shared.frontmostApplication
            field = FocusedField.current()
        }
        let field = self.field
        let app = targetApp
        let audio = AudioRecorder.boost(samples)
        if command == .rewrite || command == .action, let selection {
            job = Task { [weak self] in
                await self?.runCommand(samples: audio, selection: await selection.value, field: field, app: app)
            }
        } else {
            job = Task { [weak self] in
                await self?.process(samples: audio, seconds: seconds, stoppedAt: stoppedAt, field: field, app: app, sent: sent)
            }
        }
    }

    // MARK: Pipeline

    private func process(samples: [Float], seconds: Double, stoppedAt: ContinuousClock.Instant,
                         field: FocusedField?, app: NSRunningApplication?,
                         sent: [(end: Int, task: Task<Groq.Transcript?, Never>?)] = []) async {
        let entries = Vocabulary.all()
        let key = Keychain.groqKey
        let translating = command == .translate
        defer { if translating, !phase.isBusy { command = nil } }
        guard let (transcript, engine) = await transcribe(samples, entries, sent: sent) else { return }
        let sttMs = stoppedAt.duration(to: .now).ms
        guard !Task.isCancelled else { return }

        guard !Cleanup.isHallucination(transcript.text) else { show(.notice(.nothingHeard)); return }
        // "…see you tomorrow, send": paste the rest, then press Return.
        var heard = transcript.text
        var send = false
        if Prefs.spokenSend { (heard, send) = SpokenFormat.takeSend(heard) }
        if send, heard.isEmpty {
            if field != nil { Paster.pressReturn() }
            show(.done(symbol: "return", title: "Sent", detail: nil))
            return
        }
        let (lead, said) = SpokenFormat.leadingBreak(heard)
        let raw = Vocabulary.applyReplacements(said, entries)
        var text = raw
        var translatedTo: String?
        let snippets = Snippets.all()
        let tone = Styles.tone(for: app?.bundleIdentifier)

        // The tone sets how much gets fixed too: Formal also polishes grammar, Exact skips cleanup.
        let style: CleanupStyle = tone == .formal ? .polished : .clean
        if let whole = Snippets.whole(raw, snippets) {
            // Just the trigger on its own: paste the snippet exactly as saved.
            text = lead + whole.text
            whole.uses += 1
        } else {
            var formatted = false
            if tone != .exact, raw.split(whereSeparator: \.isWhitespace).count > 3 {
                let cl = signposter.beginInterval("cleanup")
                if let cleaned = await clean(raw, speech: engine, key: key, style: style, tone: tone, entries: entries, app: app) {
                    text = cleaned.text
                    formatted = cleaned.formatted
                }
                signposter.endInterval("cleanup", cl)
            }
            // "new line", "bullet", "comma"…: Groq already did them, so only a safety net after it.
            text = formatted ? SpokenFormat.safetyNet(text) : SpokenFormat.apply(text)
            if translating, let key {
                let target = Groq.italianShare(text) >= 0.5 ? "English" : "Italian"
                do {
                    let translated = try await Commands.translate(text, to: target, key: key)
                    guard !translated.isEmpty else { show(.notice(.failed("Got nothing back, try again"))); return }
                    text = translated
                    translatedTo = target
                } catch {
                    if !Task.isCancelled { show(.notice(.failed("Couldn't translate: \(error.localizedDescription)"))) }
                    return
                }
            }
            text = tone.finish(text)
            let expanded = Snippets.expand(text, snippets)
            text = lead + expanded.text
            for s in expanded.used { s.uses += 1 }
        }
        guard !Task.isCancelled else { return }

        if let c = field?.characterBeforeCursor, !c.isWhitespace, !"([{\"'“‘/`".contains(c),
           let first = text.first, !",.;:!?\n".contains(first) {
            text = " " + text
        }
        // With no text box in focus, ⌘V would go nowhere (or paste into the wrong thing), so just copy.
        if field == nil { Paster.copy(text.trimmingCharacters(in: .whitespaces)) }
        else {
            Paster.paste(text, keep: Prefs.keepOnClipboard)
            if send {
                // After the paste has landed, or some apps send the message before the text is in.
                Task { try? await Task.sleep(for: .milliseconds(150)); Paster.pressReturn() }
            }
        }
        let latency = stoppedAt.duration(to: .now).ms
        log.info("pasted \(text.count) chars: speech \(sttMs) ms, total \(latency) ms, engine \(engine, privacy: .public)")

        let pasted = text.trimmingCharacters(in: .whitespaces)
        let d = Dictation(text: pasted, raw: transcript.text, audioSeconds: seconds, latencyMs: latency,
                          appName: app?.localizedName, appBundleID: app?.bundleIdentifier,
                          engine: engine, language: transcript.language ?? (engine == "apple" ? offlineLanguage : nil))
        Store.context.insert(d)
        try? Store.context.save()

        if let translatedTo {
            show(.done(symbol: "globe", title: field == nil ? "Copied" : "Translated", detail: "in \(translatedTo)"))
        } else {
            show(field == nil ? .copied(words: d.words) : .pasted(words: d.words, latencyMs: latency, offline: engine == "apple"))
        }

        if Prefs.learnFromCorrections, let field, !field.isSecure {
            watcher.watch(pasted: pasted, in: field)
        }
    }

    /// Groq when the speech came from Groq. Apple Intelligence on this Mac when the speech stayed on the Mac
    /// (Only this Mac, offline, or Groq was slow) or when Groq's cleanup fails, e.g. out of free requests.
    /// nil pastes the text as heard. `formatted` is true when Groq did it, which also handles "new line" and
    /// the like; Apple's model only punctuates.
    private func clean(_ raw: String, speech engine: String, key: String?, style: CleanupStyle, tone: Tone,
                       entries: [VocabEntry], app: NSRunningApplication?) async -> (text: String, formatted: Bool)? {
        if engine == "groq", let key {
            do {
                let cleaned = try await Groq.cleanup(raw, key: key, model: Prefs.cleanupModel, style: style, tone: tone,
                                                     vocabulary: entries.map(\.hint), appName: app?.localizedName)
                if let ok = Cleanup.accept(cleaned, raw: raw) { return (ok, true) }
                return nil
            } catch {
                if Task.isCancelled { return nil }
                log.error("Groq cleanup failed, using this Mac: \(error.localizedDescription, privacy: .public)")
            }
        }
        return await MacModel.cleanup(raw).map { ($0, false) }
    }

    /// Speech to text: Groq when there's a key and a connection, Apple's on-device engine otherwise
    /// or if Groq fails. nil means it failed and the pill already says so.
    private func transcribe(_ samples: [Float], _ entries: [VocabEntry],
                            sent: [(end: Int, task: Task<Groq.Transcript?, Never>?)] = []) async -> (Groq.Transcript, String)? {
        let key = Keychain.groqKey
        let local = LocalModels.shared.active
        let useCloud = key != nil && connectivity.isOnline && !(Prefs.localOnly && local != nil)
        var engine = "groq"
        var transcript: Groq.Transcript

        #if DEBUG
        DebugAudio.save(samples)
        #endif

        let stt = signposter.beginInterval("transcribe")
        // If Groq is late it may not come at all: get the Mac's cleanup model ready meanwhile, so falling
        // back doesn't add a cold start on top of the wait.
        let warm = useCloud ? Task { try? await Task.sleep(for: .seconds(1.5)); if !Task.isCancelled { MacModel.prewarm() } } : nil
        defer { warm?.cancel() }
        do {
            if useCloud, let key {
                do {
                    let words = Vocabulary.promptWords(entries)
                    if let joined = await joinParts(sent, samples: samples, key: key, words: words) {
                        transcript = joined
                    } else if sent.isEmpty {
                        transcript = try await cloudTranscript(samples, key: key, words: words)
                    } else {
                        // A part already failed, almost always because Groq is slow or down right now.
                        // Sending the whole clip again would only add another wait, so go to the Mac.
                        throw GroqError(message: "an early part didn't come back", status: 0)
                    }
                    keyRejected = false
                } catch {
                    if let g = error as? GroqError, g.isAuth { keyRejected = true }
                    if Task.isCancelled { return nil }
                    log.error("Groq failed, using this Mac: \(error.localizedDescription, privacy: .public)")
                    writingNote = "Groq is slow, using this Mac"
                    (transcript, engine) = try await transcribeOnDevice(samples, entries)
                }
            } else {
                (transcript, engine) = try await transcribeOnDevice(samples, entries)
            }
        } catch {
            signposter.endInterval("transcribe", stt)
            if !Task.isCancelled { show(.notice(.failed(error.localizedDescription))) }
            return nil
        }
        signposter.endInterval("transcribe", stt)
        return (transcript, engine)
    }

    private func cloudTranscript(_ samples: [Float], key: String, words: [String]) async throws -> Groq.Transcript {
        let language = Prefs.language
        let audio = await Task.detached { Groq.upload(samples) }.value
        // Groq usually answers in under a second, even for a minute of audio. If nothing comes back
        // for a few seconds it's having trouble, and the Mac's own engine will be quicker.
        // With Parakeet ready the Mac is as quick and nearly as good, so give up on Groq sooner.
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        let timeout = LocalModels.shared.state(.parakeet) == .ready ? min(6, 2.5 + seconds * 0.05)
                                                                    : min(12, 5 + seconds * 0.1)
        if language == "auto" {
            return try await Groq.transcribeAuto(wav: audio.data, key: key, words: words, filename: audio.filename,
                                                 timeout: timeout).pick
        }
        return try await Groq.transcribe(wav: audio.data, key: key,
                                         prompt: Groq.whisperPrompt(words: words, language: language),
                                         language: language, filename: audio.filename, timeout: timeout)
    }

    /// The parts sent early plus the rest, as one transcript. nil if there were no parts or one failed,
    /// and then the whole clip goes in one go instead.
    private func joinParts(_ sent: [(end: Int, task: Task<Groq.Transcript?, Never>?)], samples: [Float],
                           key: String, words: [String]) async -> Groq.Transcript? {
        guard let last = sent.last else { return nil }
        let rest = Array(samples[min(last.end, samples.count)...])
        async let tail: Groq.Transcript? = AudioRecorder.speechSeconds(rest) >= 0.15
            ? try? await cloudTranscript(rest, key: key, words: words)
            : Groq.Transcript(text: "", language: nil)
        var texts: [String] = []
        var languages: [String: Int] = [:]
        for p in sent {
            guard let task = p.task else { continue }
            guard let t = await task.value else { _ = await tail; return nil }
            texts.append(t.text)
            if let l = t.language { languages[l, default: 0] += t.text.count }
        }
        guard let end = await tail else { return nil }
        texts.append(end.text)
        if let l = end.language { languages[l, default: 0] += end.text.count }
        let text = texts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        log.info("joined \(sent.count) early parts with the rest")
        return Groq.Transcript(text: text, language: languages.max { $0.value < $1.value }?.key)
    }

    // MARK: Commands

    private func runCommand(samples: [Float], selection: String?, field: FocusedField?, app: NSRunningApplication?) async {
        defer { if !phase.isBusy { command = nil } }
        guard let key = Keychain.groqKey else { return }
        // With nothing selected it may be for the assistant, so read the screen while the speech is transcribed.
        let screen = selection == nil ? Task { await ScreenContext.capture(app: app, field: field) } : nil
        let entries = Vocabulary.all()
        guard let (transcript, _) = await transcribe(samples, entries), !Task.isCancelled else { return }
        guard !Cleanup.isHallucination(transcript.text) else { show(.notice(.nothingHeard)); return }
        let said = Vocabulary.applyReplacements(transcript.text, entries)
        log.info("command: \(said, privacy: .private)")

        do {
            let mine = UserCommands.match(said)
            if let selection {
                command = .rewrite
                let instruction = mine.map { $0.extra.isEmpty ? $0.command.instruction : "\($0.command.instruction)\nAlso: \($0.extra)" } ?? said
                let result = try await Commands.rewrite(selection, instruction: instruction, key: key)
                guard !Task.isCancelled else { return }
                guard !result.isEmpty else { show(.notice(.failed("Got nothing back, try again"))); return }
                if let field, !field.isSecure, Commands.isEditable(field) {
                    Paster.paste(result, keep: Prefs.keepOnClipboard)
                    show(.done(symbol: "checkmark", title: "Rewrote", detail: said), for: 2.4)
                } else {
                    Paster.copy(result)
                    show(.done(symbol: "doc.on.clipboard", title: "Copied", detail: "can't edit here, press ⌘V to paste"), for: 3.5)
                }
            } else {
                var action: Commands.Action
                if let mine { action = .custom(name: mine.command.name, extra: mine.extra) }
                else { action = try await Commands.parse(said, key: key) }
                guard !Task.isCancelled else { return }
                if case let .custom(name, extra) = action, let cmd = UserCommands.find(name) {
                    await write(cmd, extra: extra, key: key, field: field)
                } else if let done = Commands.perform(action) {
                    show(.done(symbol: "arrow.up.right", title: done.title, detail: done.detail), for: 2.4)
                } else if case .none = action, let screen {
                    await assist(said, screen: await screen.value, field: field)
                } else if case let .open(target, _, _) = action {
                    show(.notice(.failed("Couldn't find \(target) on this Mac")))
                } else {
                    show(.notice(.failed("Not sure what to do with “\(said)”")))
                }
            }
        } catch {
            if !Task.isCancelled { show(.notice(.failed(error.localizedDescription))) }
        }
    }

    /// Writes at the cursor ("reply that I'll be there at 5") or answers in a panel ("what does this error mean").
    private func assist(_ said: String, screen: ScreenContext.Snapshot, field: FocusedField?) async {
        command = .assistant
        let canWrite = field.map { !$0.isSecure && Commands.isEditable($0) } ?? false
        do {
            let reply = try await Assistant.run(said, screen: screen, canWrite: canWrite)
            guard !Task.isCancelled else { return }
            guard !reply.text.isEmpty else { show(.notice(.failed("Got nothing back, try again"))); return }
            if reply.writes {
                Paster.paste(reply.text, keep: Prefs.keepOnClipboard)
                show(.done(symbol: "checkmark", title: "Wrote", detail: said), for: 2.4)
            } else {
                dismissTask?.cancel()
                phase = .idle
                onAnswer?(said, reply.text)
            }
        } catch {
            if !Task.isCancelled { show(.notice(.failed(error.localizedDescription))) }
        }
    }

    /// A saved command with nothing selected writes new text at the cursor.
    private func write(_ cmd: UserCommand, extra: String, key: String, field: FocusedField?) async {
        command = .rewrite
        do {
            let text = try await Commands.write(instruction: cmd.instruction, said: extra, key: key)
            guard !Task.isCancelled else { return }
            guard !text.isEmpty else { show(.notice(.failed("Got nothing back, try again"))); return }
            if let field, !field.isSecure, Commands.isEditable(field) {
                Paster.paste(text, keep: Prefs.keepOnClipboard)
                show(.done(symbol: "checkmark", title: "Wrote", detail: cmd.name), for: 2.4)
            } else {
                Paster.copy(text)
                show(.done(symbol: "doc.on.clipboard", title: "Copied", detail: "no text field here, press ⌘V to paste"), for: 3.5)
            }
        } catch {
            if !Task.isCancelled { show(.notice(.failed(error.localizedDescription))) }
        }
    }

    private var offlineLanguage: String {
        let l = Prefs.language
        return l == "auto" ? Prefs.offlineLanguage : l
    }

    /// The downloaded model if there is one, else Apple's engine. Returns the engine used, for History.
    private func transcribeOnDevice(_ samples: [Float], _ entries: [VocabEntry]) async throws -> (Groq.Transcript, String) {
        if let model = LocalModels.shared.active {
            do {
                let language = Prefs.language == "auto" ? nil : Prefs.language
                let prompt = model == .whisper
                    ? Groq.whisperPrompt(words: Vocabulary.promptWords(entries), language: Prefs.language) : nil
                let t = try await LocalSpeech.shared.transcribe(AudioRecorder.boost(samples), model: model,
                                                                language: language, prompt: prompt)
                return (t, model.engine)
            } catch {
                if Task.isCancelled { throw error }
                log.error("\(model.rawValue, privacy: .public) failed, using Apple: \(error.localizedDescription, privacy: .public)")
            }
        }
        let lang = offlineLanguage
        let text = try await AppleTranscriber.transcribe(samples: samples, languageCode: lang,
                                                         vocabulary: entries.map(\.word))
        return (Groq.Transcript(text: text, language: lang), "apple")
    }

    // MARK: Learning

    private func learn(_ fixes: [CorrectionWatcher.Fix]) {
        guard let fix = fixes.first, !phase.isBusy else { return }
        for f in fixes.dropFirst() { Vocabulary.add(word: f.word, heardAs: f.heard, learned: true) }
        guard let change = Vocabulary.add(word: fix.word, heardAs: fix.heard, learned: true) else { return }
        lastLearned = change
        show(.learned(word: change.entry.word), for: 5)
    }

    func undoLearned() {
        if let c = lastLearned { Vocabulary.undo(c) }
        lastLearned = nil
        dismiss()
    }

    // MARK: Pill timing

    private func show(_ p: Phase, for seconds: Double? = nil) {
        phase = p
        dismissTask?.cancel()
        let duration: Double = seconds ?? {
            switch p {
            case .pasted: 1.4
            case .copied: 3
            case .notice(.failed), .notice(.needsAccessibility), .notice(.micDenied): 4
            default: 2.2
            }
        }()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, self.phase == p else { return }
            self.phase = .idle
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        if !phase.isBusy { phase = .idle }
    }

    func showMeeting(_ pill: MeetingPill) {
        let seconds: Double = switch pill {
        // Stays until answered or the call ends: a 12 s offer was easy to miss while talking.
        case .offer: 4 * 3600
        case .started: 4
        case .stopped: 2.5
        case .cantHear: 10
        // Telling voices apart and a recap on this Mac can take a few minutes on a long call.
        case .writingNotes: 900
        case .saved: 10
        case .failed: 5
        }
        meetingPill = pill
        meetingDismiss?.cancel()
        meetingDismiss = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.meetingPill == pill else { return }
            self.meetingPill = nil
        }
    }

    #if DEBUG
    /// For screenshots of a phase without dictating.
    func demoPhase(_ p: Phase) {
        startedAt = Date()
        show(p, for: 30)
    }
    #endif

    func dismissMeeting() {
        meetingDismiss?.cancel()
        meetingPill = nil
    }

    /// The call ended before anyone answered the offer.
    func dismissMeetingOffer() {
        if case .offer = meetingPill { dismissMeeting() }
    }

    // MARK: Other actions

    func pasteLast() {
        var fd = FetchDescriptor<Dictation>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        fd.fetchLimit = 1
        guard let last = try? Store.context.fetch(fd).first else { return }
        let text = last.text
        if NSApp.isActive {
            NSApp.hide(nil)
            Task { try? await Task.sleep(for: .milliseconds(220)); Paster.paste(text) }
        } else {
            Paster.paste(text)
        }
    }

    #if DEBUG
    /// For previews and screenshots.
    func preview(_ p: Phase, levels: [Float]? = nil, command: CommandKind? = nil) {
        phase = p
        self.command = command
        if p == .listening { startedAt = .now.addingTimeInterval(-14) }
        if let levels { self.levels = levels }
    }
    #endif
}

private extension Duration {
    var ms: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}

enum Sound {
    enum Cue { case start, stop }

    static func play(_ cue: Cue) {
        guard Prefs.sounds else { return }
        // Our own soft tones: the system ones (Tink, Pop...) double as alert sounds and read as errors.
        let s = NSSound(named: cue == .start ? "VerbatimStart" : "VerbatimStop")
        s?.volume = 0.6
        s?.play()
    }
}
