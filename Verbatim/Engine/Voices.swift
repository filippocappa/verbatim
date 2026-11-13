import AVFoundation
import FluidAudio
import Foundation
import os

/// Tells apart the voices on the other side of a call, once it has ended. Runs on this Mac with
/// FluidAudio's speaker models (downloaded the first time, about 30 MB).
actor Voices {
    static let shared = Voices()

    struct Turn: Sendable {
        let start: Double
        let end: Double
        let speaker: String
    }

    private let log = Logger(subsystem: "com.fcappa.Verbatim", category: "meetings")

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Verbatim")/Models/speakers", isDirectory: true)
    }

    /// Who spoke when, in the recording of the other side, and a print of each voice (see VoiceBook).
    /// The models are loaded for this and dropped after.
    func turns(in file: URL) async throws -> (turns: [Turn], prints: [String: [Float]]) {
        let started = Date()
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels(directory: Self.folder)
        let result = try await manager.process(file)
        let turns = result.segments.map { Turn(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId) }
        log.notice("voices: \(Set(turns.map(\.speaker)).count) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
        return (turns, result.speakerDatabase ?? [:])
    }
}

/// The other side of a call, written to a temporary file as it's transcribed, so the voices can be told apart
/// at the end. Deleted as soon as the notes are written.
@MainActor
final class CallAudio {
    let url: URL
    private var file: AVAudioFile?

    static let prefix = "verbatim-call-"

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.prefix)\(UUID().uuidString).caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!
        file = try? AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ samples: [Float]) {
        guard let file, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try? file.write(from: buffer)
    }

    /// Finishes the file. Returns it if there's anything in it.
    func close() -> URL? {
        let frames = file?.length ?? 0
        file?.close()
        file = nil
        return frames > Int64(AudioRecorder.sampleRate) ? url : nil
    }

    func delete() {
        file = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// Leftovers from a call the app didn't finish (it quit or crashed).
    static func deleteLeftovers() {
        let tmp = FileManager.default.temporaryDirectory
        for f in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where f.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(f))
        }
    }
}
