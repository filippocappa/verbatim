import AVFoundation
import AudioToolbox
import CoreAudio

/// The sound other apps are playing (the other people on a call), through a Core Audio process tap.
/// Nothing joins the call: macOS hands us a copy of what the meeting app sends to the speakers.
///
/// Needs the "System Audio Recording" permission (`NSAudioCaptureUsageDescription`). When it's refused,
/// the tap still runs but delivers silence, so callers watch `peakRMS` rather than waiting for an error.
/// Audio comes in on a Core Audio thread, so shared state sits behind `lock`, like `AudioRecorder`.
nonisolated final class SystemAudio: @unchecked Sendable {
    /// An app process Core Audio knows about.
    struct Process: Sendable, CustomStringConvertible {
        let object: AudioObjectID
        let pid: pid_t
        let bundleID: String
        /// Using a microphone right now.
        let input: Bool
        /// Playing sound right now.
        let output: Bool

        var description: String { "\(bundleID) pid \(pid)\(input ? " mic" : "")\(output ? " sound" : "")" }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                          channels: 1, interleaved: false)!
    private let queue = DispatchQueue(label: "verbatim.systemaudio", qos: .userInitiated)

    private let lock = NSLock()
    private var samples: [Float] = []
    /// How many samples were dropped from the front, so indexes stay the same for the whole call.
    private var base = 0
    private var peak: Float = 0
    private(set) var isRunning = false
    /// What's being tapped, for logs.
    private(set) var tapped: [String] = []

    deinit { stop() }

    // MARK: Start and stop

    /// Starts listening to every process whose bundle ID starts with one of `prefixes`
    /// ("com.google.Chrome" also covers its helper processes, which are the ones that play the sound).
    /// With no prefixes, or no matching process, it listens to the whole Mac except Verbatim.
    func start(prefixes: [String]) throws {
        guard !isRunning else { return }
        lock.lock(); samples.removeAll(); base = 0; peak = 0; lock.unlock()

        let all = Self.processes()
        let matching = all.filter { p in prefixes.contains { p.bundleID.hasPrefix($0) } }
        let description: CATapDescription
        if matching.isEmpty {
            let me = all.filter { $0.pid == getpid() }.map(\.object)
            description = CATapDescription(monoGlobalTapButExcludeProcesses: me)
            tapped = ["everything except Verbatim"]
        } else {
            description = CATapDescription(monoMixdownOfProcesses: matching.map(\.object))
            tapped = matching.map(\.description)
        }
        description.name = "Verbatim meeting"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        // Picks the app back up if it restarts its audio process mid-call (macOS 26).
        description.isProcessRestoreEnabled = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "Couldn't start listening to the call")
        tapID = tap

        // A tap can only be read through an aggregate device. It sits on the current speakers so the clock matches.
        guard let outputUID = Self.defaultOutputUID() else { stop(); throw Self.error("No sound output found", 0) }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Verbatim meeting",
            kAudioAggregateDeviceUIDKey: "verbatim.meeting.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        do { try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg), "Couldn't set up the call audio") }
        catch { stop(); throw error }
        aggregateID = agg

        guard var asbd = Self.tapFormat(tap), let inFormat = AVAudioFormat(streamDescription: &asbd) else {
            stop(); throw Self.error("Couldn't read the call's audio format", 0)
        }
        converter = AVAudioConverter(from: inFormat, to: outFormat)

        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { [weak self] _, input, _, _, _ in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, bufferListNoCopy: input, deallocator: nil) else { return }
            self.receive(buffer)
        }
        do { try check(status, "Couldn't read the call audio") } catch { stop(); throw error }
        procID = proc
        do { try check(AudioDeviceStart(agg, proc), "Couldn't start the call audio") } catch { stop(); throw error }
        isRunning = true
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        converter = nil
        isRunning = false
    }

    // MARK: Reading

    /// Total samples heard since start, including ones already dropped.
    var sampleCount: Int { lock.lock(); defer { lock.unlock() }; return base + samples.count }

    /// The loudest moment so far. Stays at zero when the permission is missing.
    var peakRMS: Float { lock.lock(); defer { lock.unlock() }; return peak }

    /// Samples between two positions counted from the start; anything already dropped is skipped.
    func samples(from start: Int, to end: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let s = max(start - base, 0), e = min(end - base, samples.count)
        return s < e ? Array(samples[s..<e]) : []
    }

    /// Frees everything before `position` once it has been transcribed, so an hour-long call stays small.
    func discard(upTo position: Int) {
        lock.lock(); defer { lock.unlock() }
        let n = min(max(position - base, 0), samples.count)
        guard n > 0 else { return }
        samples.removeFirst(n)
        base += n
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        guard let converter, buffer.frameLength > 0 else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat,
                                         frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: ch, count: Int(out.frameLength))
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = sqrt(sum / Float(chunk.count))
        lock.lock()
        samples.append(contentsOf: chunk)
        if rms > peak { peak = rms }
        lock.unlock()
    }

    // MARK: Core Audio lookups

    /// Every process that has used audio since it started, with what it's doing now.
    static func processes() -> [Process] {
        let objects: [AudioObjectID] = array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return objects.compactMap { object in
            let pid: pid_t = value(object, kAudioProcessPropertyPID) ?? -1
            let bundle = string(object, kAudioProcessPropertyBundleID) ?? ""
            let input: UInt32 = value(object, kAudioProcessPropertyIsRunningInput) ?? 0
            let output: UInt32 = value(object, kAudioProcessPropertyIsRunningOutput) ?? 0
            return Process(object: object, pid: pid, bundleID: bundle, input: input != 0, output: output != 0)
        }
    }

    private static func defaultOutputUID() -> String? {
        guard let device: AudioObjectID = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice)
        else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    private static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        value(tap, kAudioTapPropertyFormat)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw) == noErr else { return nil }
        return raw.load(as: T.self)
    }

    private static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw) == noErr else { return [] }
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw Self.error(what, status) }
    }

    private static func error(_ what: String, _ status: OSStatus) -> NSError {
        NSError(domain: "Verbatim", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(what) (\(status))"])
    }
}
