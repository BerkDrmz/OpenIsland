import AppKit

/// Kompozisyon kökü: tüm servislerin tek örneği burada yaşar ve görünümlere enjekte edilir.
@MainActor
final class AppEnvironment {
    let preferences = Preferences()
    let system = SystemMonitor()
    let audioMixer = AudioMixerController()
    let quitOnClose = QuitOnCloseService()
    let dockPreviews = DockPreviewController()
    let maintenance = MaintenanceController()
    let permissions = PermissionsCenter()
    let screens = ScreenManager()
    let media = MediaController()
    let shelf = ShelfStore()
    let hud = HUDController()
    let mirror = CameraMirror()
    let clipboard = ClipboardHistory()
    let colorPicker = ColorPickerService()
    let focusTimer = FocusTimer()
    let eventStore = EventStoreProvider()
    let calendar: CalendarService
    let reminders: RemindersService
    let notes = NotesStore()
    let launcher = LauncherStore()
    let power = PowerMonitor()
    let audioOutput = AudioOutputMonitor()
    let bluetooth = BluetoothConnectionMonitor()
    let transfers = TransferMonitor()
    let network = NetworkMonitor()
    let hotKey = HotKeyService()
    let fullscreen = FullscreenMonitor()
    let lifecycle = SystemLifecycleMonitor()
    /// Düşük Güç Modu ve ısı durumu (pil tasarrufu).
    let energy = EnergyStateMonitor()
    /// Sistem arayüzleri (Quick Look, AirDrop, dosya seçici) açıkken adayı açık tutar.
    let hold = IslandHold()
    /// SwiftUI'nin Ayarlar sahnesini açan eylem; adanın kök görünümü göründüğünde SwiftUI ortamından alınır
    /// (AppKit'ten açmanın desteklenen yolu `openSettings` eylemidir).
    var settingsAction: (() -> Void)?

    init() {
        calendar = CalendarService(provider: eventStore)
        reminders = RemindersService(provider: eventStore)
        shelf.hold = hold
        launcher.hold = hold
        dockPreviews.onRequestScreenAccess = { [weak self] in
            guard let self else { return }
            self.permissions.resolve(.screenCapture, reminders: self.reminders, calendar: self.calendar)
        }
        permissions.onStateChange = { [weak clipboard, weak media, weak quitOnClose, weak dockPreviews, weak preferences] kind, state in
            if kind == .accessibility {
                clipboard?.setShortcutMonitoring(state == .granted)
                quitOnClose?.configure(enabled: preferences?.quitOnLastWindowClose == true)
            }
            if kind == .accessibility || kind == .screenCapture {
                dockPreviews?.configure(enabled: preferences?.dockWindowPreviews == true)
            }
            if state == .granted, let bundleID = PermissionsCenter.automationTargets[kind] {
                media?.recoverAutomation(for: bundleID)
            }
        }
    }

    /// Ada menüsünden Ayarlar: uygulama önce etkinleştirilir (erişilebilirlik tek pencerede, Dock simgesi yok).
    func openSettings() {
        NSApp.activate()
        settingsAction?()
    }

    func shutdown() {
        maintenance.shutdown()
        system.stop()
        audioMixer.shutdown()
        quitOnClose.stop()
        dockPreviews.stop()
        permissions.stop()
        notes.flush()
        focusTimer.shutdown()
        SpacePresentationController.shared.tearDown()
        media.stop()
        mirror.stop()
        hud.setObservesVolume(false)
        clipboard.stop()
        power.stop()
        audioOutput.stop()
        bluetooth.stop()
        transfers.stop()
        network.stop()
        calendar.stop()
        reminders.shutdown()
        hotKey.setEnabled(false)
        fullscreen.stop()
        screens.stop()
        lifecycle.stop()
        energy.stop()
    }
}
