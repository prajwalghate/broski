import AudioToolbox
import BroskiCore
import CoreAudio
import Foundation

/// The Mac's microphones, and the one Broski listens to. The choice is this Mac's own (UserDefaults), not synced.
enum Microphones {
    private static let choiceKey = "BroskiMicrophone"

    /// The chosen mic's UID; nil follows the system's input (System Settings › Sound).
    static var chosen: String? {
        get { UserDefaults.standard.string(forKey: choiceKey) }
        set { UserDefaults.standard.set(newValue, forKey: choiceKey) }
    }

    /// Every device that can record, by name.
    static func all() -> [MicDevice] {
        deviceIDs().filter(hasInput).compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return MicDevice(uid: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The chosen mic's device while it's connected; nil means the system's.
    static var chosenDevice: AudioDeviceID? {
        guard let mic = MicChoice.resolve(saved: chosen, devices: all()) else { return nil }
        return deviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == mic.uid }
    }

    static var systemDefault: AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    static var systemDefaultName: String? { systemDefault.flatMap { string($0, kAudioObjectPropertyName) } }

    /// The name of the mic Broski listens to now.
    static var current: String { MicChoice.label(saved: chosen, devices: all(), systemDefault: systemDefaultName) }

    static func name(of id: AudioDeviceID) -> String? { string(id, kAudioObjectPropertyName) }

    // MARK: Core Audio

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
