import AVFoundation
import Speech
import os

/// Offline fallback: Apple's on-device speech engine (macOS 26+). It runs in a system
/// process, so it costs the app almost no memory. It needs a fixed language (no auto-detect).
enum AppleTranscriber {
    static func transcribe(samples: [Float], languageCode: String, vocabulary: [String]) async throws -> String {
        let wanted = Locale(identifier: languageCode == "it" ? "it-IT" : "en-US")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw NSError(domain: "Verbatim", code: 10, userInfo: [NSLocalizedDescriptionKey: "Offline speech isn't available for \(wanted.identifier)"])
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // Never make a dictation wait on a model download: start it in the background and say so.
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            prepare(languageCode)
            let name = languageCode == "it" ? "Italian" : "English"
            throw NSError(domain: "Verbatim", code: 12, userInfo: [NSLocalizedDescriptionKey: "Offline \(name) is still downloading"])
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(vocabulary.prefix(100))
            try? await analyzer.setContext(context)
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let buffer = makeBuffer(samples, format: format)
        else {
            throw NSError(domain: "Verbatim", code: 11, userInfo: [NSLocalizedDescriptionKey: "Couldn't prepare audio for offline speech"])
        }

        let collector = Task { () throws -> String in
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var downloading: Set<String> = []
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "offline")

    /// Makes sure the on-device model for a language is installed, downloading it in the
    /// background if needed. Safe to call often.
    static func prepare(_ languageCode: String) {
        guard !downloading.contains(languageCode) else { return }
        downloading.insert(languageCode)
        Task {
            defer { downloading.remove(languageCode) }
            let wanted = Locale(identifier: languageCode == "it" ? "it-IT" : "en-US")
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else { return }
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            guard await AssetInventory.status(forModules: [transcriber]) != .installed else { return }
            do {
                _ = try await AssetInventory.reserve(locale: locale)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                log.info("Offline model ready: \(locale.identifier, privacy: .public)")
            } catch {
                log.error("Offline model download failed for \(locale.identifier, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    private static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!
        guard let src = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        src.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if format == srcFormat { return src }

        guard let converter = AVAudioConverter(from: srcFormat, to: format) else { return nil }
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / srcFormat.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        return error == nil ? out : nil
    }
}
