import AVFoundation
import AudioToolbox

/// Captures the microphone as 16 kHz mono Float32, which is what Whisper wants.
/// The mic is only open while recording, so the mic indicator is off the rest of the time.
/// The tap runs on a Core Audio thread, so this class is not main-actor bound; shared state sits behind `lock`.
nonisolated final class AudioRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    /// Called on the main actor ~30 times a second with a 0...1 loudness value.
    var onLevel: (@MainActor @Sendable (Float) -> Void)?

    private var unit: AudioUnit?
    private var renderBuffer: AVAudioPCMBuffer?
    private let lock = NSLock()
    private var samples: [Float] = []
    /// Samples dropped from the front with `discard(upTo:)`. Positions keep counting from the start.
    private var base = 0
    private var peakRMS: Float = 0
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var lastLevelPost: TimeInterval = 0
    private(set) var isRunning = false

    /// Records from one input device through a bare Core Audio input unit.
    ///
    /// Not AVAudioEngine: the engine builds a hidden aggregate of the default input *and output* devices,
    /// and setting that up interrupts whatever AirPods are playing, even when we record from another mic.
    /// - Parameter device: the mic to use, or nil for the system default.
    func start(device: Microphone.Device? = nil) throws {
        guard !isRunning else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); base = 0; peakRMS = 0; lock.unlock()

        func fail(_ what: String, _ status: OSStatus) -> NSError {
            NSError(domain: "Verbatim", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(what) (\(status))"])
        }
        guard let deviceID = device?.id ?? Microphone.systemDefault()?.id else {
            throw NSError(domain: "Verbatim", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone found"])
        }

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw fail("No audio input unit", -1) }
        var newUnit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &newUnit)
        guard status == noErr, let au = newUnit else { throw fail("Couldn't create the audio unit", status) }

        let u32 = UInt32(MemoryLayout<UInt32>.size)
        var on: UInt32 = 1, off: UInt32 = 0
        // Input only: bus 1 is the mic side, bus 0 the speaker side, which stays off.
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, u32)
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, u32)
        var id = deviceID
        status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { AudioComponentInstanceDispose(au); throw fail("Couldn't open the microphone", status) }

        // Ask for mono Float32 at the device's own rate; the converter does the resampling to 16 kHz.
        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &size)
        let rate = deviceFormat.mSampleRate > 0 ? deviceFormat.mSampleRate : 48_000
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 8192) else {
            AudioComponentInstanceDispose(au); throw fail("Unsupported microphone format", -1)
        }
        var clientFormat = inFormat.streamDescription.pointee
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientFormat, size)
        var maxFrames: UInt32 = 8192
        AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, u32)

        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, timeStamp, bus, frames, _ in
            let recorder = Unmanaged<AudioRecorder>.fromOpaque(refCon).takeUnretainedValue()
            return recorder.render(flags, timeStamp, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        converter = AVAudioConverter(from: inFormat, to: outFormat)
        renderBuffer = buffer
        unit = au
        status = AudioUnitInitialize(au)
        if status == noErr { status = AudioOutputUnitStart(au) }
        guard status == noErr else {
            AudioComponentInstanceDispose(au); unit = nil
            throw fail("Couldn't start the microphone", status)
        }
        isRunning = true
    }

    /// How many samples are recorded so far.
    var sampleCount: Int { lock.lock(); defer { lock.unlock() }; return base + samples.count }

    /// A copy of part of the recording so far, for sending the start of a long dictation early.
    /// Positions count from the start of the recording; anything already discarded is skipped.
    func samples(from start: Int, to end: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let s = max(start - base, 0), e = min(end - base, samples.count)
        return s < e ? Array(samples[s..<e]) : []
    }

    /// Frees everything before `position`. Meetings call this once a stretch is transcribed,
    /// so an hour-long call stays small. Dictation never does.
    func discard(upTo position: Int) {
        lock.lock(); defer { lock.unlock() }
        let n = min(max(position - base, 0), samples.count)
        guard n > 0 else { return }
        samples.removeFirst(n)
        base += n
    }

    /// Stops capture and returns everything recorded.
    func stop() -> (samples: [Float], peakRMS: Float) {
        guard isRunning, let au = unit else { return ([], 0) }
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
        unit = nil
        isRunning = false
        lock.lock(); defer { lock.unlock() }
        let out = (samples, peakRMS)
        samples = []
        return out
    }

    /// Called on the audio thread whenever the mic has new frames: pull them out of the unit and process them.
    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timeStamp: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let au = unit, let buffer = renderBuffer, frames <= buffer.frameCapacity else { return noErr }
        let list = buffer.mutableAudioBufferList
        list.pointee.mBuffers.mDataByteSize = frames * 4
        let status = AudioUnitRender(au, flags, timeStamp, bus, frames, list)
        guard status == noErr else { return status }
        buffer.frameLength = frames
        process(buffer)
        return noErr
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let n = Int(out.frameLength)
        let chunk = UnsafeBufferPointer(start: ch, count: n)

        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = sqrt(sum / Float(n))

        lock.lock()
        samples.append(contentsOf: chunk)
        if rms > peakRMS { peakRMS = rms }
        lock.unlock()

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelPost > 0.033, let onLevel {
            lastLevelPost = now
            // Map speech loudness (roughly 0.005...0.2 RMS) onto 0...1 on a log scale.
            let db = 20 * log10(max(rms, 1e-6))
            let level = Float(min(1, max(0, (db + 50) / 40)))
            Task { @MainActor in onLevel(level) }
        }
    }
}

extension AudioRecorder {
    /// Whisper mode: brings quiet speech up to a normal level before it's transcribed,
    /// so talking softly works. Loud recordings pass through untouched.
    /// Roughly how many seconds of the clip sound like a voice: 20 ms frames well above the room's
    /// background noise. The first and last moments are skipped because they hold the click of the
    /// ⌘ taps, which on an otherwise silent clip is enough for Whisper to invent "Thank you".
    static func speechSeconds(_ samples: [Float]) -> Double {
        let frame = Int(sampleRate * 0.02)
        let start = Int(sampleRate * 0.15), end = samples.count - Int(sampleRate * 0.25)
        guard end - start >= frame else { return 0 }
        var rms: [Float] = []
        var i = start
        while i + frame <= end {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            rms.append((sum / Float(frame)).squareRoot())
            i += frame
        }
        let floor = rms.sorted()[rms.count / 5]
        let threshold = max(floor * 4, 0.0012)
        return Double(rms.filter { $0 > threshold }.count) * 0.02
    }

    /// Where to split a long recording: the middle of the latest pause of at least 0.45 s in the last
    /// `lookback` samples, as an index into `samples`. nil if there's no pause there.
    /// "Pause" uses the same idea of quiet as speechSeconds: well under the room's background level times four.
    static func pause(in samples: [Float], lookback: Int) -> Int? {
        let frame = Int(sampleRate * 0.02)
        let count = samples.count / frame
        guard count > 50 else { return nil }
        var rms = [Float](repeating: 0, count: count)
        for f in 0..<count {
            var sum: Float = 0
            for j in (f * frame)..<((f + 1) * frame) { sum += samples[j] * samples[j] }
            rms[f] = (sum / Float(frame)).squareRoot()
        }
        let threshold = max(rms.sorted()[count / 5] * 4, 0.0012)
        let first = max(0, count - lookback / frame)
        var f = count - 1, runEnd = -1
        while f >= first {
            if rms[f] <= threshold {
                if runEnd < 0 { runEnd = f }
                if runEnd - f + 1 >= 23 { return (f + runEnd) / 2 * frame + frame / 2 }
            } else {
                runEnd = -1
            }
            f -= 1
        }
        return nil
    }

    static func boost(_ samples: [Float]) -> [Float] {
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        guard peak > 0, peak < 0.25 else { return samples }
        let gain = min(12, 0.5 / peak)
        return samples.map { $0 * gain }
    }
}

nonisolated enum Compressed {
    /// The clip as a small compressed file, for uploading. kind is "m4a" (AAC) or "flac". nil if encoding fails.
    static func encode(_ samples: [Float], kind: String, bitRate: Int = 32_000) -> Data? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).\(kind)")
        defer { try? FileManager.default.removeItem(at: url) }
        var settings: [String: Any] = [AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1]
        if kind == "flac" {
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVLinearPCMBitDepthKey] = 16
        } else {
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = bitRate
        }
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buf)
        } catch { return nil }
        return try? Data(contentsOf: url)
    }
}

nonisolated enum WAV {
    /// 16-bit PCM mono WAV, small enough to upload fast (32 KB per second).
    static func encode(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(byteCount)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices { pcm[i] = Int16(max(-1, min(1, samples[i])) * 32767) }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
