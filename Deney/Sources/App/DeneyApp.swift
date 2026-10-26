import AppKit

/// AppKit deneyinin girişi: SwiftUI `App`/`MenuBarExtra` yerine `NSApplication` + `NSStatusItem`.
/// Servisler (`AppEnvironment`) ve durum makinesi (`IslandCoordinator`, `IslandViewModel`) ana uygulamayla ortaktır.
@main
@MainActor
final class DeneyAppDelegate: NSObject, NSApplicationDelegate {
    private static var retained: DeneyAppDelegate?

    static func main() {
        TestIsolationGuard.validate()
        let app = NSApplication.shared
        let delegate = DeneyAppDelegate()
        retained = delegate
        app.delegate = delegate
        app.run()
    }

    let environment = AppEnvironment()
    private var coordinator: IslandCoordinator?
    private var statusItem: NSStatusItem?
    private var menuBuilder: StatusMenuBuilder?
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // Dock simgesi yok (LSUIElement ile aynı)
        if DockPreviewParityHarness.runIfRequested() { return }
        if ToolsParityHarness.runIfRequested(environment) { return }
        if SettingsParityHarness.runIfRequested(environment) { return }
        let settings = SettingsWindowController(environment: environment)
        self.settings = settings
        environment.settingsAction = { [weak settings] in settings?.show() }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "OpenIsland")
        let builder = StatusMenuBuilder(environment: environment)
        item.menu = builder.menu
        statusItem = item
        menuBuilder = builder

        let coordinator = IslandCoordinator(environment: environment)
        coordinator.start()
        self.coordinator = coordinator
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        environment.shutdown()
    }
}

/// Menü çubuğu menüsü: SwiftUI sürümündeki `MenuBarContent` ile aynı öğeler ve sıra. Menü her açılışta
/// güncel durumdan yeniden kurulur (yoklama yok).
@MainActor
final class StatusMenuBuilder: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild() }
    }

    private func rebuild() {
        menu.removeAllItems()
        let env = environment
        if let info = env.media.nowPlaying {
            let title = NSMenuItem(title: "♪ \(info.title) — \(info.artist)", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(item(info.isPlaying ? "Duraklat" : "Oynat") { env.media.togglePlayPause() })
            menu.addItem(.separator())
        }
        menu.addItem(item(env.focusTimer.isRunning ? "Odak zamanlayıcısını duraklat" : "Odak zamanlayıcısını başlat") {
            env.focusTimer.toggle()
        })
        let demo = item("Demo modu") { env.preferences.demoMode.toggle() }
        demo.state = env.preferences.demoMode ? .on : .off
        menu.addItem(demo)
        menu.addItem(.separator())
        menu.addItem(item("Araçlar…") { env.maintenance.open() })
        menu.addItem(item("Ayarlar…", key: ",") { env.openSettings() })
        menu.addItem(item("OpenIsland'den Çık", key: "q") { NSApp.terminate(nil) })
    }

    private func item(_ title: String, key: String = "", action: @escaping () -> Void) -> NSMenuItem {
        let item = StatusMenuItem(title: title, keyEquivalent: key, handler: action)
        return item
    }
}

/// Hedef/eylem yerine kapanış taşıyan menü öğesi.
final class StatusMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("desteklenmiyor") }

    @objc private func fire() { handler() }
}
