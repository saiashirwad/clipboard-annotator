import CoreAudio
import Foundation
import Observation

/// One microphone the system knows about. The UID survives reboots and
/// unplugging; the numeric ID does not, so only the UID is ever stored.
struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Which microphone to record from, given what the user asked for and what
/// is plugged in right now. Kept free of CoreAudio so it can be tested.
enum InputDeviceChoice {
    /// `nil` means "leave the engine on the system default".
    static func resolve(preferredUID: String?, available: [AudioInputDevice]) -> AudioInputDevice? {
        guard let preferredUID else { return nil }
        return available.first { $0.uid == preferredUID }
    }
}

/// CoreAudio lookups for input devices. Every call is synchronous and cheap.
enum AudioInputDeviceQuery {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func allInputs() -> [AudioInputDevice] {
        deviceIDs().compactMap { id in
            guard inputChannelCount(of: id) > 0,
                  let uid = string(kAudioDevicePropertyDeviceUID, of: id),
                  let name = string(kAudioObjectPropertyName, of: id)
            else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    static func defaultInput() -> AudioInputDevice? {
        var address = globalAddress(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr, id != 0,
              let uid = string(kAudioDevicePropertyDeviceUID, of: id),
              let name = string(kAudioObjectPropertyName, of: id)
        else { return nil }
        return AudioInputDevice(id: id, uid: uid, name: name)
    }

    static func device(forUID uid: String) -> AudioInputDevice? {
        allInputs().first { $0.uid == uid }
    }

    // MARK: - Plumbing

    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = globalAddress(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }
}

/// The live list of microphones, refreshed whenever one is plugged in,
/// removed, or made the system default.
@MainActor
@Observable
final class AudioInputDeviceList {
    private(set) var devices: [AudioInputDevice] = []
    private(set) var systemDefault: AudioInputDevice?

    @ObservationIgnored private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        refresh()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioInputDeviceQuery.globalAddress(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
            listeners.append((address, block))
        }
    }

    deinit {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
        }
    }

    func refresh() {
        devices = AudioInputDeviceQuery.allInputs()
        systemDefault = AudioInputDeviceQuery.defaultInput()
    }
}
