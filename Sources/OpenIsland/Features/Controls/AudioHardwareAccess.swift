import AppKit
import CoreAudio
import AudioToolbox

/// Kayıt yapmadan, Core Audio özelliklerini yalnızca çağrıldığında okur/yazar.
enum AudioHardwareAccess {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> T? {
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        var property = address(selector, scope: scope, element: element)
        let status = withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return nil }
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let result = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!) }
        return result == noErr ? values : []
    }

    static func write<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var property = address(selector, scope: scope, element: element)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &property, &settable) == noErr, settable.boolValue else { return false }
        var value = value
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(object, &property, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        } == noErr
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        scalar(system, selector, initial: AudioObjectID(0)) ?? 0
    }

    static func level(_ device: AudioObjectID, input: Bool) -> Float? {
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        for element: UInt32 in [0, 1] {
            if let value: Float = scalar(device, kAudioDevicePropertyVolumeScalar, initial: Float(0), scope: scope, element: element) {
                return min(max(value, 0), 1)
            }
        }
        if !input {
            return scalar(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, initial: Float(0), scope: scope)
        }
        return nil
    }

    static func setLevel(_ device: AudioObjectID, input: Bool, level: Float) -> Bool {
        let value = min(max(level, 0), 1)
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        if write(device, kAudioDevicePropertyVolumeScalar, value, scope: scope) { return true }
        if !input, write(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, value, scope: scope) { return true }
        var succeeded = false
        for channel: UInt32 in [1, 2] {
            if write(device, kAudioDevicePropertyVolumeScalar, value, scope: scope, element: channel) { succeeded = true }
        }
        return succeeded
    }
}

struct MixerDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let input: Bool
    let output: Bool

    static func read() -> [Self] {
        AudioHardwareAccess.objects(AudioHardwareAccess.system, kAudioHardwarePropertyDevices).compactMap { id in
            let input = !AudioHardwareAccess.objects(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput).isEmpty
            let output = !AudioHardwareAccess.objects(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput).isEmpty
            guard input || output, let uid = AudioHardwareAccess.string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("OpenIsland.Mixer.") else { return nil }
            return Self(id: id, uid: uid, name: AudioHardwareAccess.string(id, kAudioObjectPropertyName) ?? "Ses aygıtı", input: input, output: output)
        }
    }
}
