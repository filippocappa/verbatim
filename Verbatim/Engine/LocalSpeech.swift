import FluidAudio
import Foundation
import WhisperKit
import os

/// Speech models that run on this Mac, downloaded from Settings → Speech.
enum LocalModel: String, CaseIterable, Identifiable, Sendable {
    case parakeet
    case whisper

    var id: String { rawValue }

    var name: String {
        switch self {
        case .parakeet: "Parakeet"
        case .whisper: "Whisper large v3 turbo"
        }
    }

    var detail: String {
        switch self {
        case .parakeet: "Recommended. About a tenth of a second per sentence, English, Italian and 23 more."
        case .whisper: "The model Groq runs, here 1–3 s per sentence. Takes your Dictionary words as hints."
        }
    }

    var size: String {
        switch self {
        case .parakeet: "630 MB"
        case .whisper: "630 MB"
        }
    }

    /// What History shows and stores as the engine.
    var engine: String { rawValue }

    // Where the files live: ~/Library/Application Support/Verbatim/Models.
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("\(AppInfo.name)/Models", isDirectory: true)
    }

    nonisolated private static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Verbatim"

    nonisolated static let parakeetVersion = AsrModelVersion.ultra
    nonisolated static let whisperVariant = "large-v3-v20240930_626MB"

    /// Parakeet's own folder, named the way FluidAudio expects.
    nonisolated static var parakeetFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(appName)/Models", isDirectory: true)
        return base.appendingPathComponent(AsrModels.defaultCacheDirectory(for: parakeetVersion).lastPathComponent,
                                           isDirectory: true)
    }

    /// Whisper's files go under here (WhisperKit adds models/argmaxinc/whisperkit-coreml/...).
    nonisolated static var whisperBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(appName)/Models/whisper", isDirectory: true)
    }

    /// The small CTC model that checks names from the Dictionary and the calendar against the audio
    /// (about 100 MB, fetched the first time a meeting runs on Parakeet).
    nonisolated static var ctcFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(appName)/Models", isDirectory: true)
            .appendingPathComponent(CtcModels.defaultCacheDirectory(for: .ctc110m).lastPathComponent, isDirectory: true)
    }

    nonisolated static var whisperFolder: URL {
        whisperBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(whisperVariant)",
                                           isDirectory: true)
    }

    nonisolated var isOnDisk: Bool {
        switch self {
        case .parakeet:
            return AsrModels.modelsExist(at: Self.parakeetFolder, version: Self.parakeetVersion)
        case .whisper:
            let fm = FileManager.default
            return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
                fm.fileExists(atPath: Self.whisperFolder.appendingPathComponent($0).path)
            }
        }
    }
}

/// Download state of each model, for Settings and for picking an engine.
@Observable
final class LocalModels {
    static let shared = LocalModels()

    enum State: Equatable {
        case none
        case downloading(Double)
        /// Compiling for the Neural Engine, once after a download.
        case preparing
        case ready
        case failed(String)
    }

    private(set) var states: [LocalModel: State] = [:]
    @ObservationIgnored private var jobs: [LocalModel: Task<Void, Never>] = [:]
    private let log = Logger(subsystem: "com.fcappa.Verbatim", category: "local")

    private init() {
        for m in LocalModel.allCases { states[m] = m.isOnDisk ? .ready : .none }
    }

    func state(_ m: LocalModel) -> State { states[m] ?? .none }

    /// The model dictation should use on this Mac: the chosen one if it's ready, else any ready one.
    var active: LocalModel? {
        let chosen = Prefs.localModel
        if state(chosen) == .ready { return chosen }
        return LocalModel.allCases.first { state($0) == .ready }
    }

    func download(_ m: LocalModel) {
        guard jobs[m] == nil else { return }
        states[m] = .downloading(0)
        log.notice("downloading \(m.rawValue, privacy: .public)")
        jobs[m] = Task {
            do {
                try await LocalSpeech.shared.download(m) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self else { return }
                        if fraction >= 1 { self.states[m] = .preparing } else { self.states[m] = .downloading(fraction) }
                    }
                }
                states[m] = .preparing
                // Load it once now: the first load compiles it for this Mac, which can take a minute.
                try await LocalSpeech.shared.warm(m)
                states[m] = .ready
                log.notice("\(m.rawValue, privacy: .public) ready")
            } catch {
                if !Task.isCancelled {
                    states[m] = .failed(error.localizedDescription)
                    log.error("\(m.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    states[m] = m.isOnDisk ? .ready : .none
                }
            }
            jobs[m] = nil
        }
    }

    func cancel(_ m: LocalModel) {
        jobs[m]?.cancel()
        jobs[m] = nil
        Task { await delete(m) }
    }

    func delete(_ m: LocalModel) async {
        await LocalSpeech.shared.unload(m)
        let folder = m == .parakeet ? LocalModel.parakeetFolder : LocalModel.whisperBase
        try? FileManager.default.removeItem(at: folder)
        if m == .parakeet { try? FileManager.default.removeItem(at: LocalModel.ctcFolder) }
        states[m] = .none
        log.notice("deleted \(m.rawValue, privacy: .public)")
    }
}

/// Runs the local models. One model stays loaded at a time and is dropped after 10 idle minutes,
/// so it doesn't sit in memory when you're not dictating.
actor LocalSpeech {
    static let shared = LocalSpeech()

    private var parakeet: AsrManager?
    /// Names Parakeet should listen for in this meeting, checked against the audio after each piece.
    private var boost: (words: [String], session: VocabularyBoostingSession)?
    private var wantedNames: [String] = []
    private var whisper: WhisperKit?
    private var loading: Task<Void, Error>?
    private var loadingModel: LocalModel?
    private var idle: Task<Void, Never>?
    private let log = Logger(subsystem: "com.fcappa.Verbatim", category: "local")

    // MARK: Download

    func download(_ m: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch m {
        case .parakeet:
            try await AsrModels.download(to: LocalModel.parakeetFolder, version: LocalModel.parakeetVersion) { p in
                // FluidAudio counts the download as the first half and compiling for this Mac as the second.
                progress(min(p.fractionCompleted, 0.99))
            }
        case .whisper:
            try FileManager.default.createDirectory(at: LocalModel.whisperBase, withIntermediateDirectories: true)
            _ = try await WhisperKit.download(variant: LocalModel.whisperVariant, downloadBase: LocalModel.whisperBase) { p in
                progress(min(p.fractionCompleted, 0.99))
            }
        }
    }

    // MARK: Loading

    /// Loads the model if it isn't already. Called when recording starts, so it's ready by the time you stop.
    func warm(_ m: LocalModel) async throws {
        if isLoaded(m) { touch(); return }
        if let loading, loadingModel == m { try await loading.value; return }
        unloadAll()
        loadingModel = m
        let task = Task<Void, Error> {
            let started = Date()
            switch m {
            case .parakeet:
                let models = try await AsrModels.load(from: LocalModel.parakeetFolder, version: LocalModel.parakeetVersion)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                self.setParakeet(manager)
            case .whisper:
                let config = WhisperKitConfig(model: LocalModel.whisperVariant,
                                              downloadBase: LocalModel.whisperBase,
                                              modelFolder: LocalModel.whisperFolder.path,
                                              verbose: false, logLevel: .error,
                                              prewarm: true, load: true, download: false)
                let kit = try await WhisperKit(config)
                self.setWhisper(kit)
            }
            self.log.notice("loaded \(m.rawValue, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
        }
        loading = task
        defer { loading = nil; loadingModel = nil }
        try await task.value
        touch()
    }

    private func setParakeet(_ m: AsrManager) { parakeet = m }
    private func setWhisper(_ k: WhisperKit) { whisper = k }

    private func isLoaded(_ m: LocalModel) -> Bool {
        m == .parakeet ? parakeet != nil : whisper != nil
    }

    func unload(_ m: LocalModel) {
        if m == .parakeet { parakeet = nil } else { whisper = nil }
    }

    private func unloadAll() {
        parakeet = nil
        whisper = nil
        boost = nil
    }

    /// Restarts the 10-minute countdown to unloading.
    private func touch() {
        idle?.cancel()
        idle = Task {
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            self.dropIdle()
        }
    }

    private func dropIdle() {
        guard parakeet != nil || whisper != nil else { return }
        unloadAll()
        log.notice("unloaded the local model after 10 idle minutes")
    }

    // MARK: Names

    /// Makes Parakeet listen for these words (names, Dictionary) until it's called again. Empty turns it off.
    /// Downloads the checking model the first time. On failure, transcription just goes on without it.
    func listen(for words: [String]) async {
        let words = Array(Set(words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 })).sorted()
        wantedNames = words
        guard !words.isEmpty else { boost = nil; return }
        if boost?.words == words { return }
        do {
            let started = Date()
            let ctc = try await CtcModels.load(from: LocalModel.ctcFolder, variant: .ctc110m)
            let vocabulary = CustomVocabularyContext(terms: words.map { CustomVocabularyTerm(text: $0) })
            // Tuned on a recorded call (Nov 2026). The defaults swapped "market" for "Parakeet" (similarity 0.62)
            // and "Paolo mentioned" for "Paolo Enoizi" (0.60), and the acoustic rescue put names over unrelated
            // words ("TFPEs. Whether we" → "Chris Wetherbee").
            let d = UserDefaults.standard
            let config = VocabularyRescorer.Config(shortTermCbwTaperPivot: d.object(forKey: "namesTaper") as? Int ?? 5,
                                                   spotterRescueEnabled: d.bool(forKey: "namesRescue"))
            let thresholds = VocabularyBoostingSession.Thresholds(minSimilarity: d.object(forKey: "namesMinSim") as? Float ?? 0.65)
            boost = (words, try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: ctc, config: config,
                                                                 thresholds: thresholds))
            log.notice("listening for \(words.count) names, ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
        } catch {
            boost = nil
            log.error("couldn't load the names model: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Puts each name where the names model found it ("Givens" → "Giveans"): the first match after the
    /// previous one, so the same word elsewhere in the piece stays as it is. Keeps punctuation.
    private static func applyNames(_ fixes: [VocabularyRescorer.RescoringResult], to segments: [Groq.Segment]) -> [Groq.Segment] {
        func plain(_ w: String) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        var words: [(seg: Int, word: String)] = segments.enumerated().flatMap { i, s in
            s.text.split(separator: " ").map { (i, String($0)) }
        }
        var cursor = 0
        for r in fixes {
            guard let new = r.replacementWord?.split(separator: " ").map(String.init), !new.isEmpty else { continue }
            let old = r.originalWord.split(separator: " ").map { plain(String($0)) }.filter { !$0.isEmpty }
            guard !old.isEmpty, words.count >= old.count else { continue }
            func find(from: Int) -> Int? {
                guard from <= words.count - old.count else { return nil }
                return (from...(words.count - old.count)).first { i in old.indices.allSatisfy { plain(words[i + $0].word) == old[$0] } }
            }
            guard let at = find(from: cursor) ?? find(from: 0) else { continue }
            let last = words[at + old.count - 1].word
            let tail = String(last.reversed().prefix { $0.isPunctuation }.reversed())
            var put = new.map { (seg: words[at].seg, word: $0) }
            put[put.count - 1].word += tail
            words.replaceSubrange(at..<(at + old.count), with: put)
            cursor = at + put.count
        }
        return segments.enumerated().map { i, s in
            Groq.Segment(start: s.start, end: s.end, text: words.filter { $0.seg == i }.map(\.word).joined(separator: " "))
        }
    }

    // MARK: Transcribing

    /// 16 kHz mono samples to text. `language` is "en", "it" or nil for auto. `prompt` only helps Whisper.
    /// `timed` also returns sentences with their times, for meetings. `names` checks the words from `listen(for:)`.
    func transcribe(_ samples: [Float], model: LocalModel, language: String?, prompt: String?,
                    timed: Bool = false, names: Bool = false) async throws -> Groq.Transcript {
        try await warm(model)
        let started = Date()
        defer {
            touch()
            log.notice("\(model.rawValue, privacy: .public): \(Double(samples.count) / 16_000, format: .fixed(precision: 1)) s of audio in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
        }
        switch model {
        case .parakeet:
            guard let parakeet else { throw Self.error("Parakeet isn't loaded") }
            // Parakeet needs at least a second of audio.
            var audio = samples
            if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
            var state = TdtDecoderState.make()
            let hint = language.flatMap { Language(rawValue: $0) }
            let result = try await parakeet.transcribe(audio, decoderState: &state, language: hint)
            var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var segments = timed ? Self.sentences(buildWordTimings(from: result.tokenTimings ?? []).map { ($0.word, $0.startTime, $0.endTime) }) : []
            // Unloaded since (idle, or dictation switched to Whisper): load the names again.
            if names, boost == nil, !wantedNames.isEmpty { await listen(for: wantedNames) }
            if names, let boost, let rescored = await boost.session.rescore(text: result.text, tokenTimings: result.tokenTimings ?? [],
                                                                      audioSamples: audio), rescored.wasModified {
                let fixes = rescored.replacements.filter(\.shouldReplace)
                log.notice("names: \(fixes.map { "\($0.originalWord) → \($0.replacementWord ?? "")" }.joined(separator: ", "), privacy: .public)")
                if segments.isEmpty {
                    text = Self.applyNames(fixes, to: [Groq.Segment(start: 0, end: 0, text: text)])[0].text
                } else {
                    segments = Self.applyNames(fixes, to: segments)
                    text = segments.map(\.text).joined(separator: " ")
                }
            }
            // Parakeet doesn't say which language it heard; the text does.
            return Groq.Transcript(text: text, language: language ?? (Groq.italianShare(text) > 0.5 ? "it" : "en"),
                                   segments: segments)
        case .whisper:
            guard let whisper else { throw Self.error("Whisper isn't loaded") }
            var options = DecodingOptions(verbose: false, task: .transcribe, language: language,
                                          temperatureFallbackCount: 3, detectLanguage: language == nil,
                                          skipSpecialTokens: true, withoutTimestamps: !timed)
            if let prompt, !prompt.isEmpty, let tokenizer = whisper.tokenizer {
                options.promptTokens = tokenizer.encode(text: " " + prompt)
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            }
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let segments = results.flatMap(\.segments).map {
                Groq.Segment(start: Double($0.start), end: Double($0.end),
                             text: $0.text.replacing(/<\|[^|]*\|>/, with: "").trimmingCharacters(in: .whitespaces))
            }.filter { !$0.text.isEmpty }
            return Groq.Transcript(text: text, language: results.first?.language ?? language, segments: timed ? segments : [])
        }
    }

    /// Words into sentences: a new one after . ? ! or a pause of more than 0.8 s.
    private static func sentences(_ words: [(word: String, start: Double, end: Double)]) -> [Groq.Segment] {
        var out: [Groq.Segment] = []
        var current: [(word: String, start: Double, end: Double)] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(Groq.Segment(start: first.start, end: last.end, text: current.map(\.word).joined(separator: " ")))
            current = []
        }
        for w in words {
            if let last = current.last, w.start - last.end > 0.8 { flush() }
            current.append(w)
            if let c = w.word.last, ".?!".contains(c) { flush() }
        }
        flush()
        return out
    }

    private static func error(_ text: String) -> NSError {
        NSError(domain: "Verbatim", code: 30, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
