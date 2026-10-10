import AppKit
import ApplicationServices
import IslandCore

/// Polling yok: yalnızca global sol-tuş tıklamasında AXCloseButton aranır. Mouse-up sonrasında
/// tek, iptal edilebilir doğrulama yapılır. Programatik kapama, Cmd-W, minimize, gizleme ve Spaces
/// değişimleri çıkış isteği oluşturmaz. terminate() uygulamanın kaydetme/veto davranışını korur.
@MainActor
final class QuitOnCloseService {
    private var monitor: Any?
    private var pending: Task<Void, Never>?
    private var windowObserver: AXObserver?
    private var released = false
    private var candidate: (app: NSRunningApplication, window: AXUIElement)?
    private(set) var isMonitoring = false
    private(set) var requestCount = 0
    private var enabled = false

    func configure(enabled: Bool) {
        self.enabled = enabled
        let shouldMonitor = enabled && AXIsProcessTrusted()
        if !shouldMonitor { stop(); return }
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        isMonitoring = monitor != nil
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        clearCandidate()
        pending?.cancel()
        pending = nil
        isMonitoring = false
    }

    private func handle(_ event: NSEvent) {
        guard enabled else { return }
        if event.type == .leftMouseDown {
            pending?.cancel()
            pending = nil
            clearCandidate()
            let point = event.cgEvent?.location ?? CGPoint(x: NSEvent.mouseLocation.x,
                         y: (NSScreen.screens.first?.frame.height ?? 0) - NSEvent.mouseLocation.y)
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.15)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { return }
            AXUIElementSetMessagingTimeout(hit, 0.15)
            guard attribute(hit, kAXSubroleAttribute) as? String == kAXCloseButtonSubrole else { return }
            var pid: pid_t = 0
            guard AXUIElementGetPid(hit, &pid) == .success,
                  let app = NSRunningApplication(processIdentifier: pid), !isProtected(app) else { return }
            var parent = hit
            for _ in 0..<8 {
                if attribute(parent, kAXRoleAttribute) as? String == kAXWindowRole {
                    candidate = (app, parent)
                    observeDestruction(pid: pid, window: parent)
                    return
                }
                guard let value = attribute(parent, kAXParentAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
                parent = unsafeDowncast(value, to: AXUIElement.self)
            }
        } else if event.type == .leftMouseUp, candidate != nil {
            released = true
            scheduleVerification(after: .milliseconds(220))
        }
    }

    private func observeDestruction(pid: pid_t, window: AXUIElement) {
        var observer: AXObserver?
        let status = AXObserverCreate(pid, { _, element, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let service = Unmanaged<QuitOnCloseService>.fromOpaque(context).takeUnretainedValue()
                guard let candidate = service.candidate, CFEqual(candidate.window, element) else { return }
                if service.released { service.scheduleVerification(after: .milliseconds(50)) }
            }
        }, &observer)
        guard status == .success, let observer else { return }
        if AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString,
                                     Unmanaged.passUnretained(self).toOpaque()) == .success {
            windowObserver = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    private func scheduleVerification(after delay: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let candidate = self.candidate, !Task.isCancelled, self.enabled else { return }
            if self.verify(candidate) { self.clearCandidate(); self.pending = nil; return }
            // AX can deliver destruction before its window list has settled, and some apps
            // retain closed window objects. Finish only this close gesture with two bounded
            // follow-ups; no idle polling or background window scanning.
            for retry in [Duration.milliseconds(350), .milliseconds(650)] {
                do { try await Task.sleep(for: retry) } catch { return }
                guard !Task.isCancelled else { return }
                if self.verify(candidate) { self.clearCandidate(); self.pending = nil; return }
            }
            // Keep the destruction observer briefly for an outstanding save dialog.
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self.clearCandidate()
            self.pending = nil
        }
    }

    private func clearCandidate() {
        if let observer = windowObserver {
            if let candidate { AXObserverRemoveNotification(observer, candidate.window, kAXUIElementDestroyedNotification as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        windowObserver = nil
        candidate = nil
        released = false
    }

    private func verify(_ candidate: (app: NSRunningApplication, window: AXUIElement)) -> Bool {
        guard !candidate.app.isTerminated else { return true }
        let application = AXUIElementCreateApplication(candidate.app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        var windows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
        guard result == .success, let list = windows as? [AXUIElement] else { return false }
        // The application's window list is authoritative: a closed AX object may remain
        // valid, or a destruction notification can arrive before this list is updated.
        // A cancelled close / save sheet still contains the tracked window, so never quit.
        guard !list.contains(where: { CFEqual($0, candidate.window) }) else { return false }
        // Finish this gesture immediately if another window remains. A later Cmd-W must
        // not accidentally turn this earlier red-button click into an app-wide quit.
        if !list.isEmpty { return true }
        let remaining = list.count
        guard QuitOnCloseRules.shouldQuit(enabled: enabled, trusted: AXIsProcessTrusted(), clickedCloseButton: true,
                                         windowWasDestroyed: true, remainingWindows: remaining,
                                         protectedApplication: isProtected(candidate.app)) else { return false }
        if candidate.app.terminate() { requestCount += 1 }
        return true
    }

    private func isProtected(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == ProcessInfo.processInfo.processIdentifier || app.activationPolicy != .regular
            || ["com.apple.finder", "com.apple.loginwindow", "com.apple.systemuiserver", "com.apple.dock"].contains(app.bundleIdentifier ?? "")
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
