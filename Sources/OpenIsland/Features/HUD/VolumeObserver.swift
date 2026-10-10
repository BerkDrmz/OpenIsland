import AudioToolbox
import CoreAudio
import Foundation
import IslandCore

/// Varsayılan çıkış aygıtının ses seviyesi ve sessiz durumu değiştiğinde haber verir.
///
/// Erişilebilirlik izni gerektirmez (public Core Audio özellik dinleyicisi, olay güdümlü; değişim yokken hiç
/// uyanmaz). Böylece izin yokken veya tuş macOS'a bırakıldığında da ses değişimi adada görünür; Denetim
/// Merkezi kaydırıcısı ve AirPods'un kendi ses kontrolü de aynı yoldan gelir. İzin varsa tuşu event tap
/// karşılar ve HUD'u zaten yayınlar; aynı değer `HUDController` içinde tekilleştirilir.
/// Yalnızca kullanıcı eylemine benzeyen değişimler iletilir (`VolumeChangeRules`): AirPods'un Kişiselleştirilmiş
/// Ses gibi otomatik ayarları adayı durmadan büyütüp küçültmesin.
@MainActor
final class VolumeObserver {
    /// Seviye (0...1) ve sessiz durumu.
    var onChange: ((_ level: Float, _ muted: Bool) -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var listener: AudioObjectPropertyListenerBlock?
    private var observedAddresses: [AudioObjectPropertyAddress] = []
    /// Aygıta bağlandıktan hemen sonraki değişimler kullanıcı eylemi değildir (AirPods bağlanırken macOS
    /// kayıtlı seviyeyi yazar); bu kısa aralıkta yayın yapılmaz, bağlanma bildirimi HUD ile örtülmez.
    private var attachedAt = ContinuousClock.now
    /// Bir önceki okuma: otomatik küçük kaymalar birikerek eşiği aşmasın diye her değişimde güncellenir.
    private var lastReading: VolumeReading?
    private static let settleAfterAttach: Duration = .milliseconds(1_000)

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    var isRunning: Bool { listener != nil }

    func start() {
        guard listener == nil else { return }
        attach()
    }

    func stop() {
        detach()
    }

    /// Varsayılan çıkış değiştiğinde yeni aygıta taşınır.
    func reattach() {
        guard listener != nil else { return }
        let current = (try? CoreAudioDevice.defaultOutputDevice()) ?? AudioObjectID(kAudioObjectUnknown)
        guard current != device else { return }
        detach()
        attach()
    }

    private func attach() {
        device = (try? CoreAudioDevice.defaultOutputDevice()) ?? AudioObjectID(kAudioObjectUnknown)
        attachedAt = .now
        lastReading = read()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.propertyChanged() }
        }
        listener = block
        guard device != kAudioObjectUnknown else { return }
        for var address in [Self.volumeAddress, Self.muteAddress] where AudioObjectHasProperty(device, &address) {
            // Başarısız kayıt çökme değildir: o özellik için HUD yalnızca tuş yakalama yolundan gelir.
            if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
                observedAddresses.append(address)
            }
        }
    }

    private func detach() {
        if let listener {
            for var address in observedAddresses {
                AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener)
            }
        }
        observedAddresses = []
        listener = nil
        lastReading = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func propertyChanged() {
        guard let reading = read() else { return }
        let previous = lastReading
        lastReading = reading
        guard ContinuousClock.now - attachedAt >= Self.settleAfterAttach,
              VolumeChangeRules.isUserVisible(from: previous, to: reading) else { return }
        onChange?(Float(reading.level), reading.muted)
    }

    private func read() -> VolumeReading? {
        guard device != kAudioObjectUnknown else { return nil }
        var volumeAddress = Self.volumeAddress
        var muteAddress = Self.muteAddress
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &level) == noErr else { return nil }
        var mute: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        let muted = AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &mute) == noErr && mute != 0
        return VolumeReading(level: Double(level), muted: muted)
    }
}
