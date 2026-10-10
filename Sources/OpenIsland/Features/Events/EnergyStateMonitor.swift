import Foundation
import IslandCore

/// Düşük Güç Modu ve ısı durumu. Yalnızca sistem bildirimleri (`NSProcessInfoPowerStateDidChange`,
/// `thermalStateDidChangeNotification`); yoklama yok. Kural `EnergyRules` içindedir.
@MainActor
final class EnergyStateMonitor {
    var onChange: (() -> Void)?
    private(set) var isLowPowerMode = false
    private(set) var thermal = ThermalLevel.nominal
    private var observers: [NSObjectProtocol] = []
    /// Geliştirici ölçümü için: `OPENISLAND_FORCE_LOW_POWER=1` ile başlatılan süreç Düşük Güç Modu'nu açık sayar.
    /// Sistem ayarına dokunmadan tasarruf yolunu doğrulamayı sağlar; normal açılışta etkisizdir.
    private let forcesLowPower = ProcessInfo.processInfo.environment["OPENISLAND_FORCE_LOW_POWER"] == "1"

    func start() {
        guard observers.isEmpty else { return }
        read()
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            // Bildirimler herhangi bir iş parçacığında gelebilir; ana kuyruğa alınır.
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func refresh() {
        let previous = (isLowPowerMode, thermal)
        read()
        if previous != (isLowPowerMode, thermal) { onChange?() }
    }

    private func read() {
        let info = ProcessInfo.processInfo
        isLowPowerMode = forcesLowPower || info.isLowPowerModeEnabled
        thermal = switch info.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }
}
