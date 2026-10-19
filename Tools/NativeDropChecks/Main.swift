import AppKit
import IslandCore

@MainActor final class IslandDiagnostics {
    static let shared: IslandDiagnostics? = nil
    func log(_ message: String) {}
}

@main struct NativeDropChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let windowsBefore = NSApp.windows.count
        for _ in 0..<100 {
            let first = ManagedDropReceiver(frame: .init(x: 700, y: 1000, width: 280, height: 34))
            let monitors = ManagedDropReceiver.monitoringState.monitors
            precondition(monitors > 0 && monitors <= 2)
            let second = ManagedDropReceiver(frame: .init(x: 0, y: 0, width: 280, height: 34))
            precondition(ManagedDropReceiver.monitoringState.receivers == 2)
            precondition(ManagedDropReceiver.monitoringState.monitors == monitors)
            precondition(ManagedDropReceiver.monitoringState.lifecycleObservers == 2)
            first.update(frame: .zero, enabled: false)
            first.stop()
            first.stop()
            precondition(ManagedDropReceiver.monitoringState.receivers == 1)
            second.stop()
            precondition(ManagedDropReceiver.monitoringState.receivers == 0)
            precondition(ManagedDropReceiver.monitoringState.monitors == 0)
            precondition(ManagedDropReceiver.monitoringState.lifecycleObservers == 0)
        }
        precondition(NSApp.windows.count == windowsBefore, "Idle receivers allocated windows")
        print("PASS Native drop: 100 cycles, one shared monitor pair, multi-display ownership, idempotent stop, no idle windows or retained monitors")
    }
}
