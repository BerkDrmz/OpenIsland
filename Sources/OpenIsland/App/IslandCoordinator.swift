import AppKit
import ServiceManagement
import IslandCore

/// Uygulamanın "sinir sistemi": ekranlara göre pencere denetleyicilerini oluşturur, servis
/// olaylarını tüm adaların durum makinelerine yayınlar ve ayarları uygular.
///
/// İmleç dururken hiçbir zamanlayıcı veya fare yoklaması çalışmaz. Dock önizlemeleri yalnızca
/// gelen fare olaylarında ekran kenarını kontrol eder. Diğer
/// tetikleyiciler olaydır: ekran bildirimi, dağıtık bildirim, NSTrackingArea, drag destination,
/// Core Audio geri çağrısı, CGEventTap, IOKit güç bildirimi, NSProgress yayını, Carbon kısayolu.
@MainActor
final class IslandCoordinator {
    private let environment: AppEnvironment
    private var controllers: [CGDirectDisplayID: NotchWindowController] = [:]
    private let gestures = TrackpadGestureRouter()
    private var scrollMonitor: Any?
    private var accessibilityObserver: NSObjectProtocol?
    private var accessibilityCheck: Task<Void, Never>?
    private var isAccessibilityTrusted = AXIsProcessTrusted()
    /// Genişletilmiş görünümlerin içerik miktarı (yeni ekranlardaki adalara da uygulanır).
    private var contentHints = ExpandedContent()
    /// Çift tetiklemeleri ve hızlı kilit/açılma durumlarını önlemek için son kilit açılma zamanı.
    private var lastUnlockTime: Date = .distantPast
    private var unlockTraceTask: Task<Void, Never>?
    private var isStarted = false

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func stop() {
        isStarted = false
        unlockTraceTask?.cancel()
        unlockTraceTask = nil
        accessibilityCheck?.cancel()
        accessibilityCheck = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
        accessibilityObserver = nil
        controllers.values.forEach { $0.close() }
        controllers.removeAll()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let env = environment
        let launchedAtLogin = SystemLifecycleMonitor.launchedRightAfterLogin()
        // İzin durumları yalnızca Ayarlar > Sistem Erişimi açıldığında okunur (açılışta iş yok).

        env.screens.onChange = { [weak self] _ in
            env.system.recover()
            self?.reconcileScreens()
        }
        env.screens.onExternalChange = { [weak self] name, kind in
            guard let self, self.environment.preferences.displayNotices else { return }
            self.broadcast(.noticeRequested(.displayChanged(name: name, kind: kind)))
        }
        env.preferences.onChange = { [weak self] in self?.applyPreferences() }
        reconcileScreens()
        wireServices()
        Notifier.requestAuthorization()
        startInputHandling()
        observeAccessibilityTrust()

        env.shelf.restore()
        env.media.start()
        env.calendar.start()
        // Ses aygıtı izleyicisi her zaman açık: HUD ses kontrolü aygıt değişimine bağlı.
        // Bildirim ayarı yalnızca bildirimin gösterilip gösterilmeyeceğini belirler.
        env.audioOutput.start()
        if env.preferences.audioDeviceNotices { env.bluetooth.start() }
        env.lifecycle.start()
        env.preferences.enableLaunchAtLoginOnFirstRun()
        LifecycleLog.note("açılış: oturum açılışında başlat=\(SMAppService.mainApp.status.rawValue) (0 kayıtsız, 1 etkin, 2 onay bekliyor, 3 bulunamadı) oturum başlangıcına yakın=\(SystemLifecycleMonitor.launchedRightAfterLogin()) çalışma süresi=\(Int(ProcessInfo.processInfo.systemUptime)) sn")
        env.energy.onChange = { [weak self] in self?.applyPreferences() }
        env.energy.start()
        applyPreferences()
        IslandDiagnostics.shared?.log("controls: accessibility=\(AXIsProcessTrusted()) quit-enabled=\(env.preferences.quitOnLastWindowClose) quit-monitor=\(env.quitOnClose.isMonitoring)")
        observeContentHints()

        if let value = ProcessInfo.processInfo.environment["OPENISLAND_MIXER_SCRIPT"], let pid = pid_t(value) {
            IslandDiagnostics.shared?.runMixerScript(environment: env, pid: pid)
        } else if ProcessInfo.processInfo.environment["OPENISLAND_PERFORMANCE_SCRIPT"] == "1",
           let controller = controllers.values.first {
            IslandDiagnostics.shared?.runPerformanceScript(on: controller, environment: environment)
        } else if ProcessInfo.processInfo.environment["OPENISLAND_DIAGNOSTICS_SCRIPT"] == "1",
           let controller = controllers.values.first {
            IslandDiagnostics.shared?.runScript(on: controller, environment: env)
        }

        // Oturum az önce açıldıysa (yeniden başlatma, çıkış → giriş, oturum açılışında başlatma) animasyonu
        // ilk karede, doğru geometriyle oynat: masaüstü açıldıktan sonra geç belirme olmaz.
        if env.preferences.unlockNotices, launchedAtLogin {
            triggerUnlockNotice()
        }
    }

    // MARK: - Ekranlar

    private func reconcileScreens(updatePresentation: Bool = true) {
        let targets = environment.screens.targets(for: environment.preferences.displayTarget)
        let targetIDs = Set(targets.map(\.id))

        for (id, controller) in controllers where !targetIDs.contains(id) {
            controller.close()
            controllers[id] = nil
        }
        for screen in targets {
            if let controller = controllers[screen.id] {
                if updatePresentation || controller.screen != screen {
                    controller.update(screen: screen)
                } else {
                    controller.applyPreferences()
                }
            } else {
                let controller = NotchWindowController(screen: screen, environment: environment)
                controller.onExpanded = { [weak self] in self?.environment.clipboard.refresh() }
                controller.setContent(contentHints)
                controllers[screen.id] = controller
                applyMotion(to: controller.model)
                syncContext(into: controller.model)
                controller.setFullscreen(environment.fullscreen.state[screen.id] ?? false,
                                         behavior: environment.preferences.effectiveFullscreenBehavior)
            }
        }
    }

    /// Yeni oluşturulan adayı mevcut servis durumlarıyla eşitler.
    private func syncContext(into model: IslandViewModel) {
        model.send(.mediaPlaybackChanged(isPlaying: environment.media.isPlaying))
        model.send(.timerRunningChanged(isRunning: environment.focusTimer.isRunning))
        model.send(.shelfCountChanged(environment.shelf.items.count))
        model.send(.transferActiveChanged(isActive: environment.transfers.isActive))
        model.send(.holdChanged(isHeld: environment.hold.isHeld))
        model.send(.demoModeChanged(isOn: environment.preferences.demoMode))
    }

    private func broadcast(_ event: IslandEvent) {
        controllers.values.forEach { $0.model.send(event) }
    }

    /// Kilit açılma geri bildirimini tetikler: donanım çentiği olan ekranı önceler,
    /// peş peşe gelen sistem bildirimlerini (çift tetikleme / hızlı kilit) debounce eder.
    private func triggerUnlockNotice() {
        guard environment.preferences.unlockNotices else { LifecycleLog.note("unlock: ayar kapalı"); return }
        let now = Date()
        guard now.timeIntervalSince(lastUnlockTime) > 2.0 else { LifecycleLog.note("unlock: debounce (2 sn içinde tekrar)"); return }
        lastUnlockTime = now
        traceUnlock("tetik")

        let notchControllers = controllers.values.filter { $0.screen.hasNotch }
        if !notchControllers.isEmpty {
            notchControllers.forEach { $0.model.send(.noticeRequested(.unlocked)) }
        } else {
            controllers.values.first?.model.send(.noticeRequested(.unlocked))
        }
    }

    /// Kilit açılma yolunun teşhisi: makine durumu ve panel görünürlüğü, tetikten sonra üç anda.
    private func traceUnlock(_ stage: String) {
        for (id, controller) in controllers {
            let m = controller.model.machine
            LifecycleLog.note("unlock[\(stage)] ekran \(id): sunum=\(String(describing: m.presentation)) bildirim=\(String(describing: m.notice)) tamEkran=\(m.context.isFullscreen) panel görünür=\(controller.panel.isVisible) occlusion=\(controller.panel.occlusionState.rawValue) alpha=\(controller.panel.alphaValue)")
        }
        guard stage == "tetik" else { return }
        unlockTraceTask?.cancel()
        unlockTraceTask = Task { @MainActor [weak self] in
            for (delay, label) in [(0.25, "+0,25 sn"), (0.8, "+1,05 sn"), (0.7, "+1,75 sn")] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.traceUnlock(label)
            }
            self?.unlockTraceTask = nil
        }
    }

    /// Ekran kilitlendi: yarım kalan kilit açılma geri bildirimi iptal edilir, açık ada kapanır.
    /// Debounce sıfırlanır; "kilitle → hemen aç" çifti ikinci animasyonu yutmaz (çift bildirim yine engellenir).
    private func handleLock() {
        unlockTraceTask?.cancel()
        unlockTraceTask = nil
        lastUnlockTime = .distantPast
        broadcast(.systemLocked)
    }

    // MARK: - Servis → durum makinesi

    private func wireServices() {
        let env = environment
        env.media.onSessionEnd = { [weak self] in self?.broadcast(.mediaSessionEnded) }
        env.media.onPlaybackChange = { [weak self] isPlaying in
            self?.broadcast(.mediaPlaybackChanged(isPlaying: isPlaying))
        }
        env.focusTimer.onRunningChange = { [weak self] isRunning in
            self?.broadcast(.timerRunningChanged(isRunning: isRunning))
        }
        env.shelf.onCountChange = { [weak self] count in
            self?.broadcast(.shelfCountChanged(count))
        }
        env.hud.onHUD = { [weak self] payload in
            self?.broadcast(.hudRequested(payload))
        }
        env.hold.onChange = { [weak self] isHeld in
            self?.broadcast(.holdChanged(isHeld: isHeld))
            // Modal menus/previews can suspend hover delivery. Reconcile once when the hold ends.
            if !isHeld { self?.controllers.values.forEach { $0.reconcilePointerExit() } }
        }
        QuickLookController.shared.onVisibilityChange = { isVisible in
            isVisible ? env.hold.begin() : env.hold.end()
        }
        env.transfers.onActiveChange = { [weak self] isActive in
            self?.broadcast(.transferActiveChanged(isActive: isActive))
        }
        env.transfers.onFinished = { [weak self] name in
            self?.broadcast(.noticeRequested(.transferFinished(name: name)))
        }
        env.transfers.onEnded = { [weak self] name, outcome in
            self?.broadcast(.noticeRequested(.transferEnded(name: name, outcome: outcome)))
        }
        env.network.onChange = { [weak self] available in
            self?.broadcast(.noticeRequested(.networkChanged(isAvailable: available)))
        }
        env.power.onEvent = { [weak self] event in
            guard env.preferences.batteryNotices else { return }
            self?.broadcast(.noticeRequested(.power(event)))
        }
        env.audioOutput.onNotice = { [weak self] device, connected in
            guard let self, self.environment.preferences.audioDeviceNotices else { return }
            // IOBluetooth owns classic device connections. CoreAudio remains the fallback
            // and continues to handle HDMI/AirPlay routing and volume-device recovery.
            guard !device.isBluetooth || device.isBluetoothLE || !self.environment.bluetooth.isMonitoring else { return }
            self.broadcast(.noticeRequested(.audioOutput(name: device.name, kind: device.kind, connected: connected)))
        }
        env.bluetooth.onConnected = { [weak self] name, kind in
            guard let self, self.environment.preferences.audioDeviceNotices else { return }
            self.broadcast(.noticeRequested(.audioOutput(name: name, kind: kind, connected: true)))
        }
        env.bluetooth.onDisconnected = { [weak self] name, kind in
            guard let self, self.environment.preferences.audioDeviceNotices else { return }
            self.broadcast(.noticeRequested(.audioOutput(name: name, kind: kind, connected: false)))
        }
        env.audioOutput.onDefaultOutputChange = {
            env.hud.recover()
        }
        env.lifecycle.onWake = { [weak self] in
            env.screens.refresh()
            env.hud.recover()
            env.media.recover()
            env.system.recover()
            env.focusTimer.reconcileDeadline()
            self?.reconcileScreens()
        }
        env.lifecycle.onClockChange = { env.focusTimer.reconcileDeadline() }
        env.lifecycle.onUnlock = { [weak self] in
            self?.triggerUnlockNotice()
        }
        env.lifecycle.onLock = { [weak self] in
            self?.handleLock()
        }
        env.media.onTrackChange = { [weak self] info in
            guard env.preferences.trackChangeNotices else { return }
            self?.broadcast(.noticeRequested(.nowPlaying(title: info.title, artist: info.artist)))
        }
        env.calendar.onMeetingSoon = { [weak self] title, minutes in
            guard env.preferences.meetingReminders else { return }
            self?.broadcast(.noticeRequested(.meeting(title: title, minutes: minutes)))
        }
        env.focusTimer.onPhaseFinished = { [weak self] title in
            self?.broadcast(.noticeRequested(.timerFinished(title: title)))
        }
        env.colorPicker.onPicked = { [weak self] hex in
            self?.broadcast(.noticeRequested(.colorPicked(hex: hex)))
        }
        env.shelf.onAirDropSent = { [weak self] count in
            self?.broadcast(.noticeRequested(.airDropSent(count: count)))
        }
        env.hotKey.onPressed = { [weak self] in self?.toggleFromKeyboard() }
        env.fullscreen.onChange = { [weak self] _ in self?.applyFullscreenState() }
        gestures.onNextTrack = { env.media.nextTrack() }
        gestures.onPreviousTrack = { env.media.previousTrack() }
        gestures.onVolumeStep = { env.hud.adjustVolume(by: $0) }
    }

    // MARK: - Girdi

    /// Hover ve sürükle-bırak her pencerenin kendi tracking area / drag destination'ıyla gelir.
    /// Burada yalnızca yerel scroll izleyicisi var: yalnızca imleç kendi panelimizin üzerindeyken çağrılır.
    private func startInputHandling() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.routeScroll(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// Dinlenmede jestler görünmez sensöre, açıkken görsel panele gelir.
    private func routeScroll(_ event: NSEvent) -> Bool {
        guard environment.preferences.gesturesEnabled,
              let controller = controllers.values.first(where: { $0.panel === event.window || $0.sensor === event.window })
        else { return false }
        return gestures.handle(event, phase: controller.model.machine.phase)
    }

    private func applyFullscreenState() {
        let behavior = environment.preferences.effectiveFullscreenBehavior
        for (id, controller) in controllers {
            controller.setFullscreen(environment.fullscreen.state[id] ?? false, behavior: behavior)
        }
    }

    /// Kısayol: imlecin bulunduğu ekrandaki ada (yoksa ilki).
    private func toggleFromKeyboard() {
        let mouse = NSEvent.mouseLocation
        let controller = controllers.values.first { $0.screen.frame.containsInclusive(mouse) } ?? controllers.values.first
        controller?.toggleFromKeyboard()
    }

    // MARK: - Erişilebilirlik izni (yoklamasız)

    /// TCC Erişilebilirlik listesi değiştiğinde sistem `com.apple.accessibility.api` dağıtık
    /// bildirimini yayınlar. Bildirim, güven durumu güncellenmeden hemen önce gelebildiğinden
    /// iki kısa, tek seferlik kontrol yapılır. Önceki sürümdeki 2 sn'lik sonsuz yoklamanın yerini alır.
    private func observeAccessibilityTrust() {
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAccessibilityCheck() }
        }
    }

    private func scheduleAccessibilityCheck() {
        accessibilityCheck?.cancel()
        accessibilityCheck = Task { [weak self] in
            for delay in [0.3, 1.2] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.accessibilityTrustMayHaveChanged()
            }
        }
    }

    private func accessibilityTrustMayHaveChanged() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isAccessibilityTrusted else { return }
        isAccessibilityTrusted = trusted
        environment.permissions.refresh()
        environment.clipboard.setShortcutMonitoring(trusted)
        environment.quitOnClose.configure(enabled: environment.preferences.quitOnLastWindowClose)
        environment.dockPreviews.configure(enabled: environment.preferences.dockWindowPreviews)
    }

    // MARK: - İçerik miktarı

    /// Genişletilmiş gövdenin boyutunu belirleyen sayıları izler. Yoklama yok: Observation yalnızca bu
    /// sayılardan biri değiştiğinde tek bir geri çağrı verir; değer uygulanıp yeniden abone olunur.
    private func observeContentHints() {
        let env = environment
        let hints = withObservationTracking {
            ExpandedContent(clipboardItems: env.clipboard.items.count, shelfItems: env.shelf.items.count,
                            upcomingEvents: env.calendar.events.count, reminders: env.reminders.items.count,
                            launcherItems: env.launcher.items.count)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.isStarted == true { self?.observeContentHints() } } }
        }
        contentHints = hints
        for controller in controllers.values { controller.setContent(hints) }
    }

    // MARK: - Ayarlar

    private func applyPreferences() {
        let prefs = environment.preferences
        environment.quitOnClose.configure(enabled: prefs.quitOnLastWindowClose)
        environment.dockPreviews.configure(enabled: prefs.dockWindowPreviews)
        environment.system.privateEnabled = prefs.systemPrivateSensors
        environment.system.slowPolling = EnergyRules.savesEnergy(isEnabled: prefs.energySaving,
            lowPowerMode: environment.energy.isLowPowerMode, thermal: environment.energy.thermal)
        if prefs.audioDeviceNotices { environment.bluetooth.start() } else { environment.bluetooth.stop() }
        let visibleTabs = prefs.visibleTabs
        for controller in controllers.values {
            controller.model.configure(prefs.islandConfiguration)
            controller.model.hapticsEnabled = prefs.hapticsEnabled
            applyMotion(to: controller.model)
            controller.model.send(.demoModeChanged(isOn: prefs.demoMode))
            // Kapatılan modülün sekmesi açıksa (veya son sekmeyse) Nook'a dönülür.
            if !visibleTabs.contains(controller.model.machine.context.lastTab) {
                controller.model.send(.selectTab(.nook))
            }
        }
        reconcileScreens(updatePresentation: false)
        // Ses tuşları ve sistem ses değişimleri adada HUD açmaz; jestler doğrudan yayınlar.
        environment.hud.setObservesVolume(false)
        if prefs.clipboardHistoryEnabled { environment.clipboard.start() } else { environment.clipboard.stop() }
        environment.hotKey.setEnabled(prefs.globalHotKey)
        gestures.reversesTrackDirection = prefs.reversesMediaSwipe

        // Yalnızca açık olan olay kaynakları dinlenir; kapalıysa hiçbir geri çağrı kurulmaz.
        if prefs.networkNotices { environment.network.start() } else { environment.network.stop() }
        if prefs.batteryNotices { environment.power.start() } else { environment.power.stop() }
        if prefs.transferActivity { environment.transfers.start() } else { environment.transfers.stop() }
        if prefs.effectiveFullscreenBehavior == .alwaysShow { environment.fullscreen.stop() } else { environment.fullscreen.start() }
        applyFullscreenState()
    }

    /// Pil tasarrufunda (Düşük Güç Modu / ısınma) hareket kısalır ve müzik nabzı sabitlenir; kayıtlı Hareket ayarı
    /// değişmez, tasarruf bitince seçili stile dönülür.
    private func applyMotion(to model: IslandViewModel) {
        let prefs = environment.preferences
        let saving = EnergyRules.savesEnergy(isEnabled: prefs.energySaving, lowPowerMode: environment.energy.isLowPowerMode,
                                             thermal: environment.energy.thermal)
        model.motionStyle = saving ? .reduced : prefs.motionStyle
        if model.energySaving != saving { model.energySaving = saving }
    }
}
