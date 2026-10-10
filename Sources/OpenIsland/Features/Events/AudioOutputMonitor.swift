import CoreAudio
import Foundation
import IslandCore

/// Ses çıkış aygıtı olayları: AirPods/Bluetooth kulaklık bağlandı veya bağlantısı kesildi, HDMI'ya geçildi.
///
/// Yalnızca public Core Audio kullanır: aygıt listesi (`kAudioHardwarePropertyDevices`) ve varsayılan çıkış
/// (`kAudioHardwarePropertyDefaultOutputDevice`) özellik dinleyicileri. Olay güdümlüdür, Bluetooth izni
/// gerektirmez. **Pil yüzdesi gösterilmez**: AirPods pil bilgisinin public ve güvenilir bir API'si yoktur;
/// kırılgan private API'ye bağımlılık yerine "Bağlandı" ile yetinilir.
///
/// Neyin duyurulacağı `AudioOutputRules` (IslandCore, birim testli) içindedir. Aygıt listesi de dinlenir,
/// çünkü AirPods bağlandığında macOS çıkışı her zaman ona geçirmez; bağlanmanın asıl işareti listeye
/// yeni bir Bluetooth aygıtının eklenmesidir.
@MainActor
final class AudioOutputMonitor {
    typealias Device = AudioDeviceInfo

    /// Kullanıcıya gösterilecek değişim (bildirim ayarı kapalıysa koordinatör göstermez).
    var onNotice: ((_ device: Device, _ connected: Bool) -> Void)?
    /// Her varsayılan çıkış değişiminde (ses kontrolü yeni aygıta göre yenilenir).
    var onDefaultOutputChange: (() -> Void)?

    private var listener: AudioObjectPropertyListenerBlock?
    private var devices: [Device] = []
    private var defaultDevice: AudioObjectID?
    private var hasInitialSnapshot = false
    /// Liste ve varsayılan çıkış değişimi art arda gelir; aynı bağlanma bir kez duyurulur.
    private var announced: [AudioObjectID: ContinuousClock.Instant] = [:]
    private static let announcementMemory: Duration = .seconds(5)

    private static let observedAddresses = [
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
    ]

    func start() {
        guard listener == nil else { return }
        let initial = Self.outputDevices()
        devices = initial ?? []
        hasInitialSnapshot = initial != nil
        defaultDevice = try? CoreAudioDevice.defaultOutputDevice()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
        for var address in Self.observedAddresses {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        listener = block
    }

    func stop() {
        guard let listener else { return }
        for var address in Self.observedAddresses {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        self.listener = nil
        devices.removeAll()
        announced.removeAll()
        defaultDevice = nil
        hasInitialSnapshot = false
    }

    private func devicesChanged() {
        guard let current = Self.outputDevices() else { return }
        let currentDefault = try? CoreAudioDevice.defaultOutputDevice()
        guard hasInitialSnapshot else {
            devices = current
            defaultDevice = currentDefault
            hasInitialSnapshot = true
            onDefaultOutputChange?()
            return
        }
        let now = ContinuousClock.now
        let currentIDs = Set(current.map(\.id))
        announced = announced.filter { currentIDs.contains($0.key) && now - $0.value < Self.announcementMemory }

        let notice = AudioOutputRules.notice(previous: devices, current: current,
                                             previousDefault: defaultDevice, currentDefault: currentDefault,
                                             recentlyAnnounced: Set(announced.keys))
        let defaultChanged = currentDefault != defaultDevice
        devices = current
        defaultDevice = currentDefault

        if defaultChanged { onDefaultOutputChange?() }
        guard let notice else { return }
        if notice.connected { announced[notice.device.id] = now }
        onNotice?(notice.device, notice.connected)
    }

    // MARK: - Aygıt okuma

    /// Çıkış akışı olan aygıtlar (mikrofonlar ve yalnızca girişli aygıtlar sayılmaz).
    private static func outputDevices() -> [Device]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.compactMap { id in hasOutputStreams(id) ? describe(id) : nil }
    }

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func describe(_ device: AudioObjectID) -> Device? {
        guard device != kAudioObjectUnknown else { return nil }
        let name = BluetoothConnectionState.displayName(name(of: device))
        let transport = transportType(of: device)
        return Device(id: device, name: name, kind: kind(transport: transport, name: name),
                      isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                          || transport == kAudioDeviceTransportTypeBluetoothLE,
                      isBluetoothLE: transport == kAudioDeviceTransportTypeBluetoothLE)
    }

    private static func transportType(of device: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return transport
    }

    private static func name(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func kind(transport: UInt32, name: String) -> AudioOutputKind {
        let lowered = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return AudioOutputRules.bluetoothKind(named: name)
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .display
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        default:
            if lowered.contains("airpods") { return AudioOutputRules.bluetoothKind(named: name) }
            return lowered.contains("headphone") || lowered.contains("kulaklık") ? .headphones : .external
        }
    }
}
