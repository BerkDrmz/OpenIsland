import CoreAudio
import Foundation

// Varsayılan ses çıkış aygıtını okuyan küçük Core Audio yardımcıları (ses aygıtı bildirimleri ve HUD ses
// kontrolü kullanır). Ses kaydı veya analiz yapılmaz.

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let operation: String
    var description: String { "\(operation) başarısız (OSStatus \(status))" }
}

func caCheck(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
}

enum CoreAudioDevice {
    static func defaultOutputDevice() throws -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try caCheck(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
            "DefaultOutputDevice"
        )
        return deviceID
    }

    static func defaultOutputUID() throws -> String {
        let device = try defaultOutputDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try withUnsafeMutablePointer(to: &uid) { pointer in
            try caCheck(AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer), "DeviceUID")
        }
        guard let uid else { throw CoreAudioError(status: -1, operation: "DeviceUID boş") }
        return uid.takeRetainedValue() as String
    }
}
