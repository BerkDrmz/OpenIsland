import AppKit
import IslandCore

/// Hangi ekranda tam ekran bir uygulama olduğunu **olay güdümlü** izler.
///
/// Tetikleyiciler yalnızca sistem bildirimleri: Space değişimi (tam ekrana girme/çıkma yeni bir Space
/// demektir), uygulama öne gelmesi ve uygulama kapanması. Her olayda pencere listesi bir kez okunur
/// (`CGWindowListCopyWindowInfo`; sınır ve katman bilgisi ekran kaydı izni gerektirmez).
/// Space geçiş animasyonu sürerken iki gecikmeli kontrol yapılır. Son ölçüm bir çıkışı henüz
/// doğrulamamışsa ek kontrol tamamlanır; bekleyen çıkış olmadığında sürekli tarama yapılmaz.
@MainActor
final class FullscreenMonitor {
    var onChange: (([CGDirectDisplayID: Bool]) -> Void)?
    private(set) var state: [CGDirectDisplayID: Bool] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pending: Task<Void, Never>?
    private var exitConfirmation = FullscreenExitConfirmation(settleDelay: 1.0)

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification]
        observers = names.map { name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleEvaluation() }
            })
        }
        let applicationCenter = NotificationCenter.default
        observers.append((applicationCenter, applicationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleEvaluation() }
        }))
        evaluate()
    }

    func stop() {
        observers.forEach { center, token in center.removeObserver(token) }
        observers.removeAll()
        pending?.cancel()
        pending = nil
        exitConfirmation.reset()
        if state.values.contains(true) {
            state = [:]
            onChange?(state)
        }
    }

    private func scheduleEvaluation() {
        pending?.cancel()
        pending = Task { [weak self] in
            for delay in [0.35, 0.9] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.evaluate()
            }
            // A slow exit may produce its first safe snapshot only in the last scheduled poll.
            // Finish the two-snapshot confirmation instead of waiting for an unrelated event.
            while self?.exitConfirmation.needsConfirmation == true {
                try? await Task.sleep(for: .seconds(0.35))
                guard !Task.isCancelled else { return }
                self?.evaluate()
            }
        }
    }

    private func evaluate() {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = raw.compactMap { entry -> WindowSnapshot? in
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
            return WindowSnapshot(ownerPID: pid, layer: layer, bounds: bounds)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var result: [CGDirectDisplayID: Bool] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            // AppKit (sol-alt) → CG global (sol-üst) koordinatı.
            let display = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                                 width: screen.frame.width, height: screen.frame.height)
            result[id] = FullscreenDetector.isFullscreen(display: display, safeTopInset: screen.safeAreaInsets.top,
                                                         windows: windows, ownPID: ownPID)
        }
        let stable = exitConfirmation.apply(current: state, detected: result)
        guard stable != state else { return }
        state = stable
        onChange?(stable)
    }
}
