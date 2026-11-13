import AppKit
import Observation
import os
import UniformTypeIdentifiers

/// A recording dropped on Meetings, or picked with Transcribe a Recording…, made into a meeting the same way
/// a call is: transcript in pieces, voices told apart, Claude's review, recap. One file at a time.
@Observable
final class MeetingImport {
    static let shared = MeetingImport()
    static let types: [UTType] = [.audio, .movie, .audiovisualContent]

    /// The notes being written now, and how far along.
    private(set) var file: URL?
    private(set) var status = ""
    var lastError: String?
    @ObservationIgnored private(set) var lastFile: URL?

    @ObservationIgnored private var queue: [URL] = []
    @ObservationIgnored private(set) var running = false
    @ObservationIgnored private var job: Task<Void, Never>?
    private let log = Logger(subsystem: AppInfo.bundleID, category: "meetings")

    private init() {}

    func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.types
        panel.allowsMultipleSelection = true
        panel.message = "Pick a recording of a meeting, a voice memo or a video. \(AppInfo.name) writes the transcript and a recap."
        panel.prompt = "Transcribe"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func add(_ urls: [URL]) {
        let usable = urls.filter { url in Self.types.contains { UTType(filenameExtension: url.pathExtension)?.conforms(to: $0) == true } }
        lastError = usable.isEmpty && !urls.isEmpty ? "That isn't an audio or video file." : nil
        queue += usable
        guard !running else { return }
        running = true
        job = Task {
            while !queue.isEmpty { await run(queue.removeFirst()) }
            running = false
        }
    }

    func cancel() {
        queue = []
        job?.cancel()
    }

    private func run(_ url: URL) async {
        let name = url.deletingPathExtension().lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        status = "Opening"
        let samples: [Float]
        do {
            samples = try await Task.detached { try await AudioFile.load16k(url) }.value
        } catch {
            fail("Couldn't open “\(name)”: \(error.localizedDescription)")
            return
        }
        let rate = AudioRecorder.sampleRate
        guard AudioRecorder.speechSeconds(samples) >= 1 else { fail("Nothing is said in “\(name)”."); return }
        let seconds = Double(samples.count) / rate
        let notes = MeetingNotes(title: name, bundleID: "", service: MeetingNotes.recordingService,
                                 started: await AudioFile.recordedAt(url), length: seconds)
        file = notes.file
        log.notice("transcribing a recording: \(Int(seconds)) s")

        // Groq takes 20 requests a minute; a call sends one every 25 s, this would send them back to back.
        let paced = LocalModels.shared.state(.parakeet) != .ready && Keychain.groqKey != nil && !Prefs.localOnly
        let audio = CallAudio()
        let piece = 25 * Int(rate)
        for start in stride(from: 0, to: samples.count, by: piece) {
            if Task.isCancelled { break }
            status = "Transcribing, \(Int(Double(start) / Double(samples.count) * 100))%"
            let began = ContinuousClock.now
            let p = Array(samples[start..<min(start + piece, samples.count)])
            audio.append(p)
            await notes.transcribe(p, at: Double(start) / rate, them: true)
            if paced { try? await Task.sleep(until: began + .seconds(3.2)) }
        }
        status = "Telling voices apart"
        if let f = audio.close() { await notes.tellVoicesApart(f) }
        audio.delete()
        // One voice all the way through: still give it a label Claude can put a name on.
        notes.nameUnlabelled("Person 1")
        status = "Writing the recap"
        let ok = await notes.finish()
        await LocalSpeech.shared.listen(for: [])
        log.notice("recording transcribed, recap written: \(ok)")
        file = nil
        status = ""
        lastFile = notes.file
        DictationController.shared.showMeeting(.saved(notes.file))
    }

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        lastError = message
        file = nil
        status = ""
    }
}
