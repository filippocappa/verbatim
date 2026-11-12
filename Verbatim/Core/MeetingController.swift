import AppKit
import Observation
import os

/// Meeting notes: notices calls, offers to take notes, and records both sides while it does.
/// Step 2 of the plan: listening and the start/stop flow. The transcript comes in step 3.
@MainActor
@Observable
final class MeetingController {
    static let shared = MeetingController()

    enum State: Equatable {
        case idle
        case recording(MeetingWatcher.Call, started: Date)
    }

    private(set) var state: State = .idle
    /// Seconds since notes started, ticking once a second for the menu bar.
    private(set) var elapsed = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    var isRecording: Bool { if case .recording = state { true } else { false } }

    @ObservationIgnored private let watcher = MeetingWatcher()
    @ObservationIgnored private var them: SystemAudio?
    @ObservationIgnored private var you: AudioRecorder?
    /// The call already offered, so ignoring the offer doesn't bring it back every 2 s.
    @ObservationIgnored private var offered: MeetingWatcher.Call?
    @ObservationIgnored private var hearingCheck: Task<Void, Never>?
    @ObservationIgnored private var notes: MeetingNotes?
    @ObservationIgnored private var chunker: Task<Void, Never>?
    /// Pieces still being transcribed, so the recap waits for them.
    @ObservationIgnored private var pending: [Task<Void, Never>] = []
    /// Where each side has been cut up to.
    @ObservationIgnored private var cutThem = 0
    @ObservationIgnored private var cutYou = 0
    /// The notes file being written, or the last one.
    private(set) var lastFile: URL?
    @ObservationIgnored private let log = Logger(subsystem: AppInfo.bundleID, category: "meetings")

    func startWatching() {
        watcher.onChange = { [weak self] call in self?.callChanged(call) }
        watcher.start()
        for domain in MeetingWatcher.serviceDomains { ServiceLogos.shared.load(domain) }
    }

    private func callChanged(_ call: MeetingWatcher.Call?) {
        if let call {
            log.notice("call started: \(call.title, privacy: .public)")
            guard !isRecording, Prefs.meetingOffer, offered != call else { return }
            offered = call
            log.notice("offering notes, pill was: \(String(describing: DictationController.shared.phase), privacy: .public)")
            DictationController.shared.showMeeting(.offer(app: call.app.name, title: call.title, bundleID: call.app.bundleID, service: call.service))
            if Prefs.sounds { NSSound(named: "Tink")?.play() }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "autoTakeNotes") { start(call) }
            #endif
        } else {
            log.notice("call ended")
            offered = nil
            DictationController.shared.dismissMeetingOffer()
            if isRecording { stop() }
        }
    }

    /// From the pill's "Take notes", the menu bar, or the Meetings page. With no call noticed it listens to the whole Mac.
    func start(_ call: MeetingWatcher.Call? = nil) {
        log.notice("take notes pressed")
        guard !isRecording else { return }
        let call = call ?? watcher.current ?? watcher.detect()
            ?? MeetingWatcher.Call(app: MeetingWatcher.App(name: "Mac", bundleID: "", prefixes: [], isBrowser: false), title: "Meeting")
        let them = SystemAudio()
        let you = AudioRecorder()
        do {
            try them.start(prefixes: call.app.prefixes)
            // The mic the call uses. Unlike dictation, AirPods are fine here: the call already switched them to call mode.
            try you.start(device: Microphone.systemDefault())
        } catch {
            them.stop()
            _ = you.stop()
            log.error("couldn't start: \(error.localizedDescription, privacy: .public)")
            DictationController.shared.showMeeting(.failed(error.localizedDescription))
            return
        }
        self.them = them
        self.you = you
        let startDate = Date()
        state = .recording(call, started: startDate)
        let notes = MeetingNotes(title: call.title, bundleID: call.app.bundleID, service: call.service, started: startDate)
        self.notes = notes
        lastFile = notes.file
        cutThem = 0; cutYou = 0; pending = []
        chunker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.isRecording else { return }
                self.cut(final: false)
            }
        }
        log.notice("taking notes: \(them.tapped.joined(separator: ", "), privacy: .public)")
        DictationController.shared.showMeeting(.started(title: call.title))
        watchHearing(them)
        elapsed = 0
        let started = Date()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.elapsed = Int(Date().timeIntervalSince(started))
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        hearingCheck?.cancel()
        ticker?.cancel()
        chunker?.cancel()
        cut(final: true)
        them?.stop()
        _ = you?.stop()
        them = nil
        you = nil
        state = .idle
        log.notice("stopped taking notes")
        guard let notes else { DictationController.shared.showMeeting(.stopped); return }
        self.notes = nil
        let waiting = pending
        pending = []
        DictationController.shared.showMeeting(.writingNotes)
        Task {
            for t in waiting { await t.value }
            let ok = await notes.finish()
            self.log.notice("notes written: \(ok)")
            DictationController.shared.showMeeting(.saved(notes.file))
        }
    }

    /// Sends each side's audio off in pieces of about 25 s, cut at a pause, then frees it.
    private func cut(final: Bool) {
        guard let notes, isRecording else { return }
        let rate = Int(AudioRecorder.sampleRate)
        func piece(_ count: Int, _ from: Int, _ read: (Int, Int) -> [Float]) -> (samples: [Float], end: Int)? {
            let available = count - from
            if final { return available > rate / 2 ? (read(from, count), count) : nil }
            guard available >= 25 * rate else { return nil }
            let all = read(from, count)
            // Cut at a pause in the last 10 s; past 40 s, cut anyway.
            if let p = AudioRecorder.pause(in: all, lookback: 10 * rate), p > 15 * rate { return (Array(all[..<p]), from + p) }
            return available >= 40 * rate ? (all, count) : nil
        }
        if let them, let p = piece(them.sampleCount, cutThem, them.samples(from:to:)) {
            let at = Double(cutThem) / Double(rate)
            cutThem = p.end
            them.discard(upTo: p.end)
            pending.append(Task { await notes.transcribe(p.samples, at: at, them: true) })
        }
        if let you, let p = piece(you.sampleCount, cutYou, you.samples(from:to:)) {
            let at = Double(cutYou) / Double(rate)
            cutYou = p.end
            you.discard(upTo: p.end)
            pending.append(Task { await notes.transcribe(p.samples, at: at, them: false) })
        }
    }

    /// A refused System Audio Recording permission gives silence, not an error. If the call stays silent
    /// for 20 s while the other side should be talking, say so.
    private func watchHearing(_ them: SystemAudio) {
        hearingCheck?.cancel()
        hearingCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            if them.peakRMS < 0.0005 { DictationController.shared.showMeeting(.cantHear) }
        }
    }
}
