import AppKit

/// Adadan gerçek uygulamaya geçiş (Takvim, Anımsatıcılar, çalan müzik uygulaması, Sistem Ayarları): tek yerde
/// `activates` ile açma ve bağlantı açılamazsa uygulamanın kendisine geri dönüş.
///
/// Ölçüldü (macOS 27): etkinleşmeyen panelden `activates` ile açılan uygulama öne geliyor (Takvim hem kapalıyken
/// hem arka plandayken 0,8 sn içinde öndeydi); bu yüzden ek bir etkinleştirme adımı gerekmiyor.
@MainActor
enum AppHandoff {
    static let calendarBundleID = "com.apple.iCal"
    static let remindersBundleID = "com.apple.reminders"

    /// Belirli içeriği açar (ör. `ical://ekevent/…`). Bağlantı açılamazsa `fallbackBundleID` uygulaması açılır.
    static func open(_ url: URL?, fallbackBundleID: String? = nil) {
        guard let url else {
            if let fallbackBundleID { openApplication(bundleID: fallbackBundleID) }
            return
        }
        NSWorkspace.shared.open(url, configuration: activating) { _, error in
            guard error != nil, let fallbackBundleID else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { openApplication(bundleID: fallbackBundleID) } }
        }
    }

    /// Uygulamayı açar veya zaten çalışıyorsa öne getirir.
    static func openApplication(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: activating)
    }

    /// Çalışan bir uygulamayı öne getirir; kapalıysa başlatmaz (çağıran bunu garanti eder).
    static func reveal(_ application: NSRunningApplication) {
        guard let url = application.bundleURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: activating)
    }

    private static var activating: NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return configuration
    }
}
