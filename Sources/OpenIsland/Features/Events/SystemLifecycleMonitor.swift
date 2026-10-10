import AppKit
import Carbon
import os

/// Kilit/uyku olaylarının zaman damgalı izi: `log show --predicate 'subsystem == "io.github.openisland"' --last 5m`.
/// Olay güdümlü, yalnızca sistem olaylarında birkaç satır yazar; boştayken maliyeti yoktur.
enum LifecycleLog {
    static let logger = Logger(subsystem: "io.github.openisland", category: "lifecycle")
    static func note(_ message: String) { logger.notice("\(message, privacy: .public)") }
}

/// Uyku/uyanma ve ekran kilidi olayları (yalnızca sistem bildirimleri; yoklama yok).
///
/// Uyanmada yeniden kurulması gerekenler (koordinatörde): HUD event tap'i (sistem uykuda devre dışı
/// bırakabilir), ekran geometrisi ve medya adaptörü.
@MainActor
final class SystemLifecycleMonitor {
    var onWake: (() -> Void)?
    var onUnlock: (() -> Void)?
    /// Ekran kilitlendi veya kullanıcı oturumu arka plana alındı (hızlı kullanıcı değiştirme).
    var onLock: (() -> Void)?
    var onClockChange: (() -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sessionInactive = false

    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            LifecycleLog.note("didWake")
            MainActor.assumeIsolated { self?.onWake?() }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            LifecycleLog.note("screensDidWake")
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            LifecycleLog.note("screensDidSleep")
        }))
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClockChange?() }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionLocked() }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionUnlocked() }
        }))
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            LifecycleLog.note("screenIsLocked")
            MainActor.assumeIsolated { self?.sessionLocked() }
        }))
        observers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            LifecycleLog.note("screenIsUnlocked")
            MainActor.assumeIsolated { self?.sessionUnlocked() }
        }))
    }

    func stop() {
        observers.forEach { center, token in center.removeObserver(token) }
        observers.removeAll()
        sessionInactive = false
    }

    private func sessionLocked() {
        guard !sessionInactive else { return }
        sessionInactive = true
        onLock?()
    }

    private func sessionUnlocked() {
        guard sessionInactive else { return }
        sessionInactive = false
        onUnlock?()
    }

    // MARK: - Oturum açılışı

    /// Public launch Apple Event identifies a login-item launch. Manual launches shortly
    /// after boot must not look like authentication success. Call during didFinishLaunching.
    static func launchedRightAfterLogin(within window: TimeInterval = 120) -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
