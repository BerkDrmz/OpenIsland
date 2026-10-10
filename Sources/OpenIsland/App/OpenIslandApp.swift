import AppKit
import SwiftUI

@main
struct OpenIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("OpenIsland", systemImage: "capsule.fill") {
            MenuBarContent(environment: appDelegate.environment)
        }
        Settings {
            SettingsView(environment: appDelegate.environment)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()
    private var coordinator: IslandCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // Dock simgesi yok (LSUIElement ile aynı)
        let coordinator = IslandCoordinator(environment: environment)
        coordinator.start()
        self.coordinator = coordinator
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        environment.shutdown()
    }
}

private struct MenuBarContent: View {
    let environment: AppEnvironment
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let info = environment.media.nowPlaying {
            Text("♪ \(info.title) — \(info.artist)")
            Button(info.isPlaying ? "Duraklat" : "Oynat", action: environment.media.togglePlayPause)
            Divider()
        }
        Button(environment.focusTimer.isRunning ? "Odak zamanlayıcısını duraklat" : "Odak zamanlayıcısını başlat",
               action: environment.focusTimer.toggle)
        Toggle("Demo modu", isOn: Binding(get: { environment.preferences.demoMode },
                                          set: { environment.preferences.demoMode = $0 }))
        Divider()
        Button("Araçlar…", action: environment.maintenance.open)
        Button("Ayarlar…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("OpenIsland'den Çık") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
