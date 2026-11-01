import AppKit

/// Aynı paket kimliğiyle tek süreç. LaunchServices aynı yoldaki çalışan uygulamayı yeniden kullanır, ama başka bir
/// yoldaki kopya (yayın klasörü, yedek, eski derleme) yeni bir süreç olarak açılır: iki ada aynı çentikte üst üste
/// çizilir, ikisi de hover'a yanıt verir (açılış takılır gibi görünür) ve Notlar/Pano verisine iki süreç birden yazar.
/// Sonradan açılan süreç, önce açılana "yeniden açıl" der ve hiçbir servis kurmadan çıkar.
enum SingleInstance {
    private static var reopenName: Notification.Name {
        Notification.Name((Bundle.main.bundleIdentifier ?? "io.github.openisland.deney") + ".reopen")
    }

    /// `NSApplication` ve `AppEnvironment` kurulmadan önce çağrılır. true: başka bir kopya çalışıyor, bu süreç çıkmalı.
    /// Eşzamanlı iki açılışta ikisi de birbirini görür; yalnız sonra açılan (eşitlikte büyük pid) çıkar.
    static func handOffToRunningInstance() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        let mine = (me.launchDate ?? .distantFuture, me.processIdentifier)
        let earlier = NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { other in
            guard other.processIdentifier != me.processIdentifier, !other.isTerminated else { return false }
            let theirs = (other.launchDate ?? .distantPast, other.processIdentifier)
            return theirs < mine
        }
        guard earlier else { return false }
        DistributedNotificationCenter.default().postNotificationName(reopenName, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
        return true
    }

    /// Önce açılan süreç: başka bir kopya açılmaya çalışınca (Finder/Spotlight'ta yeniden açma ile aynı karşılık).
    @MainActor
    static func observeReopenRequests(_ handler: @escaping @MainActor () -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: reopenName, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
