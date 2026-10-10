import AppKit
import AudioToolbox
import CoreAudio
import IslandCore

// Ses seviyesi arka ucu (yalnızca public Core Audio). Başarısızlık ve beklenmeyen değer politikası
// `ManagedLevelControl` (IslandCore, birim testli) içindedir. Ekran parlaklığı ve klavye ışığı için private
// çerçeve (DisplayServices, CoreBrightness) kullanılmaz: o tuşlar her zaman macOS'un kendi göstergesine kalır.

// MARK: - Ses (public CoreAudio)

/// Varsayılan çıkış aygıtının sesi ve sessiz durumu. Tüm yazımlar `OSStatus` ile doğrulanır.
@MainActor
final class VolumeService {
    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private var device: AudioObjectID {
        (try? CoreAudioDevice.defaultOutputDevice()) ?? AudioObjectID(kAudioObjectUnknown)
    }

    /// HDMI/DisplayPort gibi bazı aygıtlarda yazılımsal ses yoktur; o zaman tuş sisteme bırakılır.
    var canSetVolume: Bool {
        let device = device
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &volumeAddress) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &volumeAddress, &settable) == noErr && settable.boolValue
    }

    var volume: Float? {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    func setVolume(_ value: Float) -> Bool {
        var value = Float32(min(max(value, 0), 1))
        return AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    var isMuted: Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &value)
        return value != 0
    }

    var canMute: Bool {
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &muteAddress)
            && AudioObjectIsPropertySettable(device, &muteAddress, &settable) == noErr && settable.boolValue
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    var backend: LevelControlBackend {
        LevelControlBackend(read: { [weak self] in self?.volume }, write: { [weak self] in self?.setVolume($0) ?? false })
    }
}
