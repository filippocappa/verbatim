import Foundation
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
    @ObservationIgnored private let log = Logger(subsystem: AppInfo.bundleID, category: "meetings")

    func startWatching() {
        watcher.onChange = { [weak self] call in self?.callChanged(call) }
        watcher.start()
    }

    private func callChanged(_ call: MeetingWatcher.Call?) {
        if let call {
            log.info("call started: \(call.title, privacy: .public)")
            guard !isRecording, Prefs.meetingOffer, offered != call else { return }
            offered = call
            DictationController.shared.showMeeting(.offer(app: call.app.name, title: call.title, bundleID: call.app.bundleID))
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "autoTakeNotes") { start(call) }
            #endif
        } else {
            log.info("call ended")
            offered = nil
            DictationController.shared.dismissMeetingOffer()
            if isRecording { stop() }
        }
    }

    /// From the pill's "Take notes", the menu bar, or the Meetings page. With no call noticed it listens to the whole Mac.
    func start(_ call: MeetingWatcher.Call? = nil) {
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
        state = .recording(call, started: Date())
        log.info("taking notes: \(them.tapped.joined(separator: ", "), privacy: .public)")
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
        them?.stop()
        _ = you?.stop()
        them = nil
        you = nil
        state = .idle
        log.info("stopped taking notes")
        DictationController.shared.showMeeting(.stopped)
    }

    /// A refused System Audio Recording permission gives silence, not an error. If the call stays silent
    /// for 20 s while the other side should be talking, say so.
    private func watchHearing(_ them: SystemAudio) {
        hearingCheck?.cancel()
        hearingCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            if them.peakRMS < 0.0005 { DictationController.shared.showMeeting(.cantHear) }
            // Until step 3 sends audio off to be transcribed, keep memory flat by dropping what's been heard.
            while !Task.isCancelled, self.isRecording {
                them.discard(upTo: them.sampleCount)
                self.you?.discard(upTo: self.you?.sampleCount ?? 0)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}
