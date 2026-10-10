import AppKit
import IslandCore

/// Ses göstergesi: jest ve UI üzerinden yapılan ses ayarlarını uygular ve `onHUD` ile adaya bildirir.
///
/// Klavye tuşları yakalanmaz (event tap yok): ses, parlaklık ve klavye ışığı tuşları macOS'un kendi göstergesine
/// kalır. Parlaklık/klavye ışığı için gereken private çerçeveler (DisplayServices, CoreBrightness) güncellemelerde
/// kırılma riski taşıdığı için kaldırıldı; böylece HUD için Erişilebilirlik izni de gerekmez.
@MainActor
final class HUDController {
    let volume = VolumeService()
    var onHUD: ((HUDPayload) -> Void)?

    /// Politika: başarısız/eksik arka uçta ayar yapılmaz, art arda hatada kontrol devre dışı kalır.
    private lazy var volumeControl = ManagedLevelControl(backend: volume.backend)
    /// Ses başka yerden değiştiğinde de HUD gösterebilir (varsayılan olarak kapalı).
    private let volumeObserver = VolumeObserver()
    /// Son yayınlanan ses HUD'u: jest yolunun yazdığı değer, ardından gelen Core Audio bildiriminde tekrar
    /// yayınlanmaz (aynı hareket iki kez başlamasın).
    private var lastVolume: (level: Float, muted: Bool, at: ContinuousClock.Instant)?

    init() {
        volumeObserver.onChange = { [weak self] level, muted in self?.systemVolumeChanged(level: level, muted: muted) }
    }

    var isObservingVolume: Bool { volumeObserver.isRunning }

    /// Ses değişimini Core Audio'dan dinler (izin gerektirmez); normal kullanımda kapalıdır.
    func setObservesVolume(_ enabled: Bool) {
        enabled ? volumeObserver.start() : volumeObserver.stop()
    }

    /// Uyanma veya ses aygıtı değişiminde: devre dışı kalmış kontrole tek bir yeni hak tanınır.
    func recover() {
        volumeControl.reset()
        volumeObserver.reattach()
    }

    // MARK: - Doğrudan ayar (jestler ve UI kaydırıcıları için)

    @discardableResult
    func adjustVolume(by delta: Float) -> Bool {
        guard volume.canSetVolume else { return false }
        if volume.isMuted, delta > 0 { volume.setMuted(false) }
        guard let value = volumeControl.adjust(by: delta) else { return false }
        publish(.volume(muted: value == 0 || volume.isMuted), level: value)
        return true
    }

    @discardableResult
    func toggleMute() -> Bool {
        guard volume.canMute else { return false }
        let muted = !volume.isMuted
        guard volume.setMuted(muted) else { return false }
        publish(.volume(muted: muted), level: volume.volume ?? 0)
        return true
    }

    private func publish(_ kind: HUDKind, level: Float) {
        if case .volume(let muted) = kind { lastVolume = (level, muted, .now) }
        onHUD?(HUDPayload(kind: kind, level: Double(level)))
    }

    private func systemVolumeChanged(level: Float, muted: Bool) {
        guard volumeObserver.isRunning else { return }
        let muted = muted || level == 0
        if let last = lastVolume, last.muted == muted, abs(last.level - level) < 0.01,
           ContinuousClock.now - last.at < .milliseconds(1_500) {
            return
        }
        publish(.volume(muted: muted), level: level)
    }
}
