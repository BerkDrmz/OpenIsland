import AppKit
import ApplicationServices
import IslandCore

@main struct DockPreviewCheck {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        if ProcessInfo.processInfo.environment["OPENISLAND_DOCK_CHECK_LIGHT_APPEARANCE"] == "1" {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        let denied = DockPreviewController(accessibilityTrusted: { false }, screenCaptureAllowed: { false })
        denied.configure(enabled: true)
        precondition(denied.monitorCount == 0 && denied.observerCount == 0)
        denied.stop()

        let service = DockPreviewController(accessibilityTrusted: { true }, screenCaptureAllowed: { false })
        for _ in 0..<100 {
            service.configure(enabled: true)
            service.configure(enabled: true)
            precondition(service.monitorCount == 2 && service.observerCount == 7, "Duplicate mouse monitors/observers")
            service.configure(enabled: false)
            precondition(service.monitorCount == 0 && service.observerCount == 0 && service.pendingCaptureCount == 0)
        }
        service.configure(enabled: true)
        let dismissals = service.dismissalCount
        for _ in 0..<10_000 { service.dismiss() }
        precondition(service.dismissalCount == dismissals,
                     "Idle clicks/Space notifications must not repeatedly clear observable preview state")
        let screen = NSScreen.screens[0].frame
        let point = CGPoint(x: screen.midX, y: screen.midY)
        for _ in 0..<10_000 { service.pointerMoved(to: point) }
        precondition(service.probeCount == 0 && service.windowReadCount == 0 && service.captureCount == 0,
                     "Interior pointer events queried Dock/windows or captured images")
        try await Task.sleep(for: .milliseconds(400))
        precondition(service.windowReadCount == 0 && service.captureCount == 0, "Idle work appeared without hover")
        service.stop()
        precondition(service.monitorCount == 0 && service.observerCount == 0 && service.imageCount == 0 && !service.isVisible)
        print("PASS Dock: denied access registers no monitors; 100 enable/disable cycles have exactly 2 monitors / 7 observers then zero; 10,000 idle dismissals do no cleanup; 10,000 interior pointer events and idle cause no Dock/window/capture reads; stop releases images and tasks")
        if CommandLine.arguments.count > 1 { try await liveCheck(URL(fileURLWithPath: CommandLine.arguments[1])) }
    }

    @MainActor private static func liveCheck(_ fixtureURL: URL) async throws {
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            print("SKIP Dock live: this test process needs existing Accessibility and Screen Recording permission; no permission is requested")
            return
        }
        let originalApp = NSWorkspace.shared.frontmostApplication
        let originalPoint = NSEvent.mouseLocation
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let fixture = try await NSWorkspace.shared.openApplication(at: fixtureURL, configuration: configuration)
        let deniedCapture = ProcessInfo.processInfo.environment["OPENISLAND_DOCK_CHECK_WITHOUT_SCREEN_ACCESS"] == "1"
        let service = DockPreviewController(screenCaptureAllowed: { !deniedCapture && CGPreflightScreenCaptureAccess() })
        defer {
            service.stop()
            fixture.terminate()
            originalApp?.activate()
            moveCursor(originalPoint)
        }
        try await Task.sleep(for: .seconds(1))
        let singleWindow = ProcessInfo.processInfo.environment["OPENISLAND_DOCK_CHECK_SINGLE_WINDOW"] == "1"
        if singleWindow {
            // Keep the minimized third fixture window, exercising the narrowest panel.
            let app = AXUIElementCreateApplication(fixture.processIdentifier)
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            for window in value as? [AXUIElement] ?? [] {
                var minimized: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
                if minimized as? Bool != true {
                    var close: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &close) == .success, let close {
                        _ = AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
                    }
                }
            }
        }
        let expectedCount = singleWindow ? 1 : 3
        guard let anchor = dockAnchor(for: fixture) else { preconditionFailure("Fixture Dock icon missing") }
        let hover = CGPoint(x: anchor.midX, y: anchor.midY)
        let away = CGPoint(x: NSScreen.screens[0].frame.midX, y: NSScreen.screens[0].frame.midY)
        service.configure(enabled: true)
        moveCursor(hover); service.pointerMoved(to: hover)
        for _ in 0..<20 {
            if service.previewedWindows.count == expectedCount && (deniedCapture || service.imageCount == expectedCount) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        precondition(service.isVisible && service.previewedWindows.count == expectedCount && service.imageCount == (deniedCapture ? 0 : expectedCount),
            "Expected \(expectedCount) window cards and \(deniedCapture ? 0 : expectedCount) snapshots (including minimized); windows=\(service.previewedWindows.count), images=\(service.imageCount)")
        precondition(service.captureCount == (deniedCapture ? 0 : expectedCount), "A visible card must be captured once; missing permission never captures")
        let applicationReads = service.applicationReadCount
        for _ in 0..<1000 { service.pointerMoved(to: hover) }
        try await Task.sleep(for: .milliseconds(200))
        precondition(service.applicationReadCount == applicationReads,
                     "Pointer motion over the same Dock item re-enumerated running applications")
        if let panel = NSApp.windows.first(where: { $0.title == "OpenIsland — Dock önizlemeleri" && $0.isVisible }) {
            precondition(abs(panel.frame.height - (deniedCapture ? DockPreviewRules.permissionPanelHeight : DockPreviewRules.panelHeight)) < 1,
                         "Preview panel escaped its compact height: \(panel.frame.height)")
            let data = try JSONSerialization.data(withJSONObject: ["window_id": panel.windowNumber, "pid": ProcessInfo.processInfo.processIdentifier])
            try data.write(to: URL(fileURLWithPath: "/tmp/codex-dock-preview-live-window.json"))
            print("LIVE PANEL READY: window \(panel.windowNumber), \(expectedCount) cards / \(service.imageCount) snapshots; visual inspection pause")
            if let helper = ProcessInfo.processInfo.environment["OPENISLAND_DOCK_SCREENSHOT_HELPER"],
               let path = ProcessInfo.processInfo.environment["OPENISLAND_DOCK_SCREENSHOT_PATH"] {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                capture.arguments = ["python3", helper, "--window-id", String(panel.windowNumber), "--path", path]
                try capture.run()
                capture.waitUntilExit()
                precondition(capture.terminationStatus == 0, "Visual test screenshot failed")
            }
            let pause = Double(ProcessInfo.processInfo.environment["OPENISLAND_DOCK_VISUAL_HOLD_SECONDS"] ?? "0") ?? 0
            if pause > 0 { try await Task.sleep(for: .seconds(min(pause, 45))) }
            let panelPoint = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            moveCursor(panelPoint); service.pointerMoved(to: panelPoint)
            try await Task.sleep(for: .milliseconds(400))
            precondition(service.isVisible && service.captureCount == (deniedCapture ? 0 : expectedCount), "Panel hover refreshed images or closed")
        }
        let minimized = service.previewedWindows.first { $0.minimized }!
        service.selectWindow(minimized.id)
        try await Task.sleep(for: .milliseconds(500))
        var minimizedValue: CFTypeRef?
        precondition(AXUIElementCopyAttributeValue(minimized.element, kAXMinimizedAttribute as CFString, &minimizedValue) == .success)
        precondition(minimizedValue as? Bool == false, "Selecting minimized preview did not restore the window")
        let application = AXUIElementCreateApplication(fixture.processIdentifier)
        var focused: CFTypeRef?
        precondition(AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success)
        precondition(focused.map { CFEqual($0, minimized.element) } == true, "Selected window did not become focused")
        precondition(service.imageCount == 0 && service.pendingCaptureCount == 0 && !service.isVisible)

        let captures = service.captureCount
        for _ in 0..<10 {
            moveCursor(hover); service.pointerMoved(to: hover)
            try await Task.sleep(for: .milliseconds(25))
            moveCursor(away); service.pointerMoved(to: away)
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(400))
        precondition(service.captureCount == captures && !service.isVisible && service.imageCount == 0,
                     "Rapid cancelled hovers started captures or left a panel/image behind")
        service.stop()
        precondition(service.monitorCount == 0 && service.observerCount == 0)
        print("PASS Dock live: \(expectedCount) cards / \(deniedCapture ? 0 : expectedCount) snapshots incl. minimized; static/panel hover does not recapture; selected minimized window restored and focused; 10 rapid cancelled hovers do no capture; all images/tasks/observers released")
    }

    @MainActor private static func moveCursor(_ point: CGPoint) {
        let cgPoint = CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cgPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    @MainActor private static func dockAnchor(for app: NSRunningApplication) -> CGRect? {
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let dock = AXUIElementCreateApplication(dockApp.processIdentifier)
        for list in attribute(dock, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            for icon in attribute(list, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                guard let url = attribute(icon, kAXURLAttribute) as? URL, url.standardizedFileURL == app.bundleURL?.standardizedFileURL,
                      let position = attribute(icon, kAXPositionAttribute), let size = attribute(icon, kAXSizeAttribute) else { continue }
                var point = CGPoint.zero, dimensions = CGSize.zero
                guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { continue }
                return CGRect(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y - dimensions.height,
                              width: dimensions.width, height: dimensions.height)
            }
        }
        return nil
    }
}
