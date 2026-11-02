import AppKit

/// Ayarlar penceresi: AppKit (`SettingsWindowFactory`, App/Sources/Settings). İlk açılışta kurulur, kapanınca saklanır.
@MainActor
final class SettingsWindowController {
    private let environment: AppEnvironment
    private var window: NSWindow?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func show() {
        if window == nil {
            let window = SettingsWindowFactory.makeWindow(environment: environment)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
