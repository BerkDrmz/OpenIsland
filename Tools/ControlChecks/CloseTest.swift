import AppKit

@MainActor final class CloseTestDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var windows: [NSWindow] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        for index in 0..<2 {
            let window = NSWindow(contentRect: NSRect(x: 120 + index * 60, y: 200 + index * 60, width: 320, height: 160),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "OpenIsland kapatma testi \(index)"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSTextField(labelWithString: "OpenIsland’in kontrollü kapatma testi")
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if CommandLine.arguments.contains("delayed") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                sender.close()
            }
            return false
        }
        return !CommandLine.arguments.contains("veto")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct CloseTest {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = CloseTestDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
