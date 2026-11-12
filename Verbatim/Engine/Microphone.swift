import CoreAudio
import Foundation

/// Picks which input device to record from.
///
/// Opening a Bluetooth headset's mic (AirPods) makes macOS switch the headset from music mode to call mode,
/// which cuts whatever you're listening to when recording starts and again when it stops. So by default,
/// when the system input is Bluetooth, we record from the Mac's built-in mic and leave the headset alone.
nonisolated enum Microphone {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transport: UInt32
        var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
        var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    }

    /// Prefs value meaning "built-in when the system mic is Bluetooth, otherwise the system mic".
    static let automatic = "auto"

    /// All devices that can record.
    static func inputs() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).compactMap(device)
    }

    static func systemDefault() -> Device? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return device(id)
    }

    /// The device to record from for a saved preference: "auto" or a device UID.
    /// nil means "leave the system default as it is".
    static func choose(_ pref: String) -> Device? {
        let all = inputs()
        if pref != automatic, let picked = all.first(where: { $0.uid == pref }) { return picked }
        // Automatic, or the picked device is unplugged.
        guard let current = systemDefault(), current.isBluetooth else { return nil }
        // With the lid closed there's no built-in mic; then fall back to any wired mic before the headset.
        return all.first(where: \.isBuiltIn) ?? all.first(where: { !$0.isBluetooth })
    }

    #if DEBUG
    /// Every device with whether something is using it and its sample rate, for checking what recording touches.
    static func debugState() -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids.compactMap { id -> String? in
            guard let d = device(id) else { return nil }
            var running: UInt32 = 0, rate: Float64 = 0
            var a1 = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var s1 = UInt32(4); AudioObjectGetPropertyData(id, &a1, 0, nil, &s1, &running)
            var a2 = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var s2 = UInt32(8); AudioObjectGetPropertyData(id, &a2, 0, nil, &s2, &rate)
            return "  \(d.name) [\(hasInput(id) ? "in" : "out")] running=\(running) rate=\(Int(rate))"
        }.joined(separator: "\n")
    }
    #endif

    // MARK: - Core Audio

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func device(_ id: AudioDeviceID) -> Device? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport)
        return Device(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? "Microphone", transport: transport)
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
