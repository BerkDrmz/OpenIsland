import Foundation
import IOKit.ps
import IslandCore

/// Pil ve şarj olayları — **yoklamasız**.
///
/// `IOPSNotificationCreateRunLoopSource`, güç kaynağı bilgisi değiştiğinde (adaptör takıldı/çıkarıldı,
/// yüzde değişti) çekirdek tarafından tetiklenen bir run loop kaynağıdır. Arada hiçbir zamanlayıcı yoktur.
/// Olaylar yalnızca **geçişlerde** üretilir: adaptör bağlandı/kesildi, pilde %20 ve %10 eşiğinin
/// aşağı doğru geçilmesi, %100'e ulaşma. Uygulama açılışında mevcut durum için bildirim gösterilmez.
@MainActor
final class PowerMonitor {
    var onEvent: ((PowerEvent) -> Void)?
    private(set) var snapshot: PowerSnapshot?
    private var source: CFRunLoopSource?

    /// Masaüstü Mac'lerde dahili pil yoktur; izleyici hiç kurulmaz.
    var hasBattery: Bool { Self.read() != nil }

    func start() {
        guard source == nil, let initial = Self.read() else { return }
        snapshot = initial
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            // Kaynak ana run loop'a eklendi: geri çağrı ana iş parçacığındadır.
            MainActor.assumeIsolated { monitor.powerSourcesChanged() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = source
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    private func powerSourcesChanged() {
        guard let new = Self.read() else { return }
        let old = snapshot
        guard new != old else { return }
        snapshot = new
        guard let old, let kind = PowerEvent.Kind.transition(from: old, to: new) else { return }
        onEvent?(PowerEvent(kind: kind, level: new.level, isCharging: new.isCharging))
    }

    private static func read() -> PowerSnapshot? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool ?? true
            else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Double ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Double ?? 100
            return PowerSnapshot(
                level: maximum > 0 ? min(current / maximum, 1) : 0,
                isOnAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false
            )
        }
        return nil
    }
}
