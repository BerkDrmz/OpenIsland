import AppKit
import SwiftUI

/// Ayarlar penceresi. GEÇİCİ: ilk aşamada mevcut SwiftUI `SettingsView` bir AppKit penceresinde barındırılıyor;
/// AppKit sürümü sonraki aşamada (bkz. Deney/README.md → Durum).
@MainActor
final class SettingsWindowController {
    private let environment: AppEnvironment
    private var window: NSWindow?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(environment: environment))
            let window = NSWindow(contentViewController: controller)
            window.title = "OpenIsland Deney Ayarları"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
