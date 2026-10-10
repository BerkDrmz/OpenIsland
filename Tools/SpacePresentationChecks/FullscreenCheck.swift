import AppKit
import IslandCore

@MainActor final class NSScreen {
    static var screens = [NSScreen()]
    let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let safeAreaInsets = NSEdgeInsetsZero
    let deviceDescription: [NSDeviceDescriptionKey: Any] = [NSDeviceDescriptionKey("NSScreenNumber"): CGDirectDisplayID(1)]
}
@MainActor var testWindows: [[String: Any]] = []
@MainActor func CGWindowListCopyWindowInfo(_ options: CGWindowListOption, _ id: CGWindowID) -> CFArray? { testWindows as CFArray }
@main struct FullscreenCheck {
    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(1400)) }
    @MainActor static func main() async {
        let monitor = FullscreenMonitor()
        monitor.start()
        let window: [String: Any] = [kCGWindowOwnerPID as String: Int32(123), kCGWindowLayer as String: 0,
            kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 1000, height: 800).dictionaryRepresentation]
        testWindows = [window]
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settle()
        precondition(monitor.state[1] == true)
        print("PASS: wake reevaluates fullscreen without requiring a Space notification")

        testWindows = []
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(500))
        precondition(monitor.state[1] == true, "first false snapshot must not reveal the island during exit")
        testWindows = [window]
        try? await Task.sleep(for: .milliseconds(900))
        precondition(monitor.state[1] == true, "fullscreen returning in the second sample cancels the transient exit")
        print("PASS: a transient exit snapshot cannot reveal the island before the fullscreen transition settles")

        // First poll still sees fullscreen; only the final scheduled poll sees a safe exit.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(600))
        testWindows = []
        try? await Task.sleep(for: .milliseconds(800))
        precondition(monitor.state[1] == true, "the last scheduled false snapshot still needs confirmation")
        try? await Task.sleep(for: .milliseconds(400))
        precondition(monitor.state[1] == false, "delayed exit must finish without another system notification")
        print("PASS: delayed fullscreen exit completes its pending confirmation without another event")

        testWindows = [window]
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await settle()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(600))
        testWindows = []
        try? await Task.sleep(for: .milliseconds(800))
        testWindows = [window]
        try? await Task.sleep(for: .milliseconds(400))
        precondition(monitor.state[1] == true, "returning to fullscreen cancels a pending delayed exit")
        print("PASS: reversed delayed exit preserves fullscreen instead of revealing content")

        testWindows = []
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await settle()
        precondition(monitor.state[1] == false)
        print("PASS: display geometry change clears stale fullscreen state")
        testWindows = [window]
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await settle()
        precondition(monitor.state[1] == true)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(600))
        testWindows = []
        try? await Task.sleep(for: .milliseconds(800))
        precondition(monitor.state[1] == true)
        monitor.stop()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settle()
        precondition(monitor.state.isEmpty)
        print("PASS: screen wake reevaluates; stop removes both centers and cancels delayed evaluation")
    }
}
