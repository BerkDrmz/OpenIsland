import AppKit

@MainActor private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        for index in 0..<3 {
            let window = NSWindow(contentRect: CGRect(x: 180 + index * 40, y: 240 + index * 30, width: 480, height: 300),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "OpenIsland önizleme testi \(index + 1)"
            window.isReleasedWhenClosed = false
            let view = NSView(frame: CGRect(x: 0, y: 0, width: 480, height: 300))
            view.wantsLayer = true
            view.layer?.backgroundColor = [NSColor.systemBlue, .systemGreen, .systemOrange][index].cgColor
            let label = NSTextField(labelWithString: "Pencere \(index + 1)")
            label.font = .systemFont(ofSize: 32, weight: .semibold)
            label.textColor = .white
            label.frame = CGRect(x: 28, y: 160, width: 400, height: 48)
            view.addSubview(label)
            window.contentView = view
            windows.append(window)
            window.orderFront(nil)
        }
        windows[2].miniaturize(nil)
        // Failure cleanup for this disposable fixture only, never a production timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { NSApp.terminate(nil) }
    }
}

@main private struct Fixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = FixtureDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
