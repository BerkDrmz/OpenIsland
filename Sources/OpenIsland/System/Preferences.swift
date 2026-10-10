import Foundation
import IslandCore
import ServiceManagement

/// UserDefaults destekli, gözlemlenebilir ayarlar. Her değişiklik `onChange` ile koordinatöre bildirilir.
@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loginStatus: () -> SMAppService.Status
    @ObservationIgnored private let setLoginRegistration: (Bool) throws -> Void
    @ObservationIgnored private var batchingChanges = false
    @ObservationIgnored private var hasPendingChange = false
    private(set) var launchAtLoginStatus: SMAppService.Status
    private(set) var launchAtLoginError: String?
    @ObservationIgnored var onChange: (() -> Void)?

    var expandsOnHover: Bool { didSet { persist(expandsOnHover, "expandsOnHover") } }
    var quitOnLastWindowClose: Bool { didSet { persist(quitOnLastWindowClose, "quitOnLastWindowClose") } }
    var dockWindowPreviews: Bool { didSet { persist(dockWindowPreviews, "dockWindowPreviews") } }
    var hapticsEnabled: Bool { didSet { persist(hapticsEnabled, "hapticsEnabled") } }
    /// Düşük Güç Modu'nda veya Mac ısındığında müzik nabzını sabitle ve hareketi kısalt (`EnergyRules`).
    var energySaving: Bool { didSet { persist(energySaving, "energySaving") } }
    /// Müzik nabzı çalan parçanın kapak renginde (gri tonlu kapakta amber kalır).
    var albumColoredPulse: Bool { didSet { persist(albumColoredPulse, "albumColoredPulse") } }
    var displayTarget: DisplayTarget { didSet { persist(displayTarget.rawValue, "displayTarget") } }
    var gesturesEnabled: Bool { didSet { persist(gesturesEnabled, "gesturesEnabled") } }
    /// Yatay medya jestinin yönü ters: sağa kaydırma sonraki parça.
    var reversesMediaSwipe: Bool { didSet { persist(reversesMediaSwipe, "reversesMediaSwipe") } }
    var clipboardHistoryEnabled: Bool { didSet { persist(clipboardHistoryEnabled, "clipboardHistoryEnabled") } }
    /// Hover'da açılmadan önceki bekleme (menü çubuğuna giderken yanlışlıkla açılmayı önler).
    var hoverDelay: Double { didSet { persist(hoverDelay, "hoverDelay") } }
    var batteryNotices: Bool { didSet { persist(batteryNotices, "batteryNotices") } }
    var networkNotices: Bool { didSet { persist(networkNotices, "networkNotices") } }
    var displayNotices: Bool { didSet { persist(displayNotices, "displayNotices") } }
    var audioDeviceNotices: Bool { didSet { persist(audioDeviceNotices, "audioDeviceNotices") } }
    var trackChangeNotices: Bool { didSet { persist(trackChangeNotices, "trackChangeNotices") } }
    var meetingReminders: Bool { didSet { persist(meetingReminders, "meetingReminders") } }
    var transferActivity: Bool { didSet { persist(transferActivity, "transferActivity") } }
    var globalHotKey: Bool { didSet { persist(globalHotKey, "globalHotKey") } }
    var unlockNotices: Bool { didSet { persist(unlockNotices, "unlockNotices") } }
    var fullscreenBehavior: FullscreenBehavior { didSet { persist(fullscreenBehavior.rawValue, "fullscreenBehavior") } }
    var motionStyle: MotionStyle { didSet { persist(motionStyle.rawValue, "motionStyle") } }
    var nookLayout: NookLayout { didSet { persist(nookLayout.rawValue, "nookLayout") } }
    var expandedSurfaceSize: ExpandedSurfaceSize { didSet { persist(expandedSurfaceSize.rawValue, "expandedSurfaceSize") } }
    var focusModule: Bool { didSet { persist(focusModule, "focusModule") } }
    var notesModule: Bool { didSet { persist(notesModule, "notesModule") } }
    var systemModule: Bool { didSet { persist(systemModule, "systemModule") } }
    var systemPrivateSensors: Bool { didSet { persist(systemPrivateSensors, "systemPrivateSensors") } }
    var mirrorModule: Bool { didSet { persist(mirrorModule, "mirrorModule") } }
    /// Demo modu (ekran kaydı, sunum): ada kendiliğinden kapanmaz, duraklatılan medya kanatta kalır, tam ekranda
    /// da görünür. **Saklanmaz**: yalnızca bu oturum için; uygulama yeniden açılınca kapalı başlar ve kayıtlı hiçbir
    /// ayarı değiştirmez.
    var demoMode = false { didSet { if demoMode != oldValue { onChange?() } } }

    /// Demo modu açıkken tam ekran yok sayılır; kayıtlı "Tam ekranda" ayarı değişmez.
    var effectiveFullscreenBehavior: FullscreenBehavior { demoMode ? .alwaysShow : fullscreenBehavior }

    /// Hover ön ayarı mevcut iki anahtarın (`expandsOnHover`, `hoverDelay`) görünümüdür; ayrı saklanmaz.
    var hoverPreset: HoverPreset {
        get { expandsOnHover ? HoverPreset.nearest(to: hoverDelay) : .off }
        set {
            // Two stored keys represent one setting: publish only the complete configuration.
            batchingChanges = true
            defer {
                batchingChanges = false
                if hasPendingChange { hasPendingChange = false; onChange?() }
            }
            if let delay = newValue.delay { hoverDelay = delay }
            expandsOnHover = newValue != .off
        }
    }

    /// Kapalı modüllerin sekmesi gösterilmez. Nook, Medya ve Raf çekirdektir (dosya bırakma rafı açar).
    var visibleTabs: [ExpandedTab] {
        ExpandedTab.allCases.filter { tab in
            switch tab {
            case .nook, .media, .shelf, .mixer: true
            case .system: systemModule
            case .clipboard: clipboardHistoryEnabled
            case .focus: focusModule
            case .notes: notesModule
            case .mirror: mirrorModule
            }
        }
    }

    init(defaults: UserDefaults = .standard,
         loginStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         setLoginRegistration: @escaping (Bool) throws -> Void = { enabled in
             if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
         }) {
        self.defaults = defaults
        self.loginStatus = loginStatus
        self.setLoginRegistration = setLoginRegistration
        launchAtLoginStatus = loginStatus()
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        expandsOnHover = bool("expandsOnHover", true)
        quitOnLastWindowClose = bool("quitOnLastWindowClose", true)
        dockWindowPreviews = bool("dockWindowPreviews", true)
        hapticsEnabled = bool("hapticsEnabled", true)
        energySaving = bool("energySaving", true)
        albumColoredPulse = bool("albumColoredPulse", true)
        displayTarget = DisplayTarget(rawValue: defaults.string(forKey: "displayTarget") ?? "") ?? .primary
        gesturesEnabled = bool("gesturesEnabled", true)
        reversesMediaSwipe = bool("reversesMediaSwipe", false)
        clipboardHistoryEnabled = bool("clipboardHistoryEnabled", true)
        let savedHover = defaults.object(forKey: "hoverDelay") as? Double ?? 0.18
        // Known presets become faster; custom durations and disabled hover remain intact.
        let migrateHover = defaults.object(forKey: "hoverLatencyOptimized") == nil
        let effectiveHover = migrateHover ? (savedHover == 0.18 ? 0.10 : savedHover == 0.12 ? 0.06 : savedHover == 0.35 ? 0.25 : savedHover) : (savedHover == 0 ? 0.06 : savedHover)
        hoverDelay = effectiveHover
        defaults.set(effectiveHover, forKey: "hoverDelay")
        defaults.set(true, forKey: "hoverLatencyOptimized")
        networkNotices = bool("networkNotices", true)
        displayNotices = bool("displayNotices", true)
        batteryNotices = bool("batteryNotices", true)
        audioDeviceNotices = bool("audioDeviceNotices", true)
        trackChangeNotices = bool("trackChangeNotices", true)
        meetingReminders = bool("meetingReminders", true)
        transferActivity = bool("transferActivity", true)
        globalHotKey = bool("globalHotKey", true)
        unlockNotices = bool("unlockNotices", true)
        fullscreenBehavior = FullscreenBehavior(rawValue: defaults.string(forKey: "fullscreenBehavior") ?? "") ?? .smart
        motionStyle = MotionStyle(rawValue: defaults.string(forKey: "motionStyle") ?? "") ?? .expressive
        nookLayout = NookLayout(rawValue: defaults.string(forKey: "nookLayout") ?? "") ?? .balanced
        expandedSurfaceSize = ExpandedSurfaceSize(rawValue: defaults.string(forKey: "expandedSurfaceSize") ?? "") ?? .compact
        focusModule = bool("focusModule", true)
        notesModule = bool("notesModule", true)
        mirrorModule = bool("mirrorModule", true)
        systemModule = bool("systemModule", true)
        systemPrivateSensors = bool("systemPrivateSensors", true)
    }

    var islandConfiguration: IslandConfiguration {
        IslandConfiguration(expandsOnHover: expandsOnHover, hoverExpandDelay: hoverDelay,
                            collapseGraceDelay: motionStyle.collapseGraceDelay)
    }

    /// Yalnızca .app paketi olarak çalışırken anlamlıdır (SMAppService paket kimliği ister).
    var launchAtLogin: Bool {
        get { launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval }
        set {
            refreshLaunchAtLogin()
            guard newValue != launchAtLogin else { return }
            launchAtLoginError = nil
            do { try setLoginRegistration(newValue) }
            catch {
                launchAtLoginError = "Oturum açılışında başlatma değiştirilemedi. Sistem Ayarları’ndaki Oturum Açma Öğeleri’ni kontrol et."
                LifecycleLog.note("login item hatası: \(error.localizedDescription)")
            }
            refreshLaunchAtLogin()
        }
    }

    func refreshLaunchAtLogin() {
        let status = loginStatus()
        if status != launchAtLoginStatus { launchAtLoginStatus = status }
    }

    /// İlk çalıştırmada "Oturum açılışında başlat" bir kez etkinleştirilir. Kullanıcı sonradan kapatırsa
    /// (Ayarlar veya Sistem Ayarları › Oturum Açma Öğeleri) yeniden açılmaz; bayrak kalıcıdır.
    /// Bayrak yalnızca kayıt gerçekten oluştuysa (etkin ya da kullanıcı onayı bekliyor) kalıcı olur; kayıt
    /// başarısız olursa (ör. durum `.notFound`) sonraki açılışta yeniden denenir.
    func enableLaunchAtLoginOnFirstRun() {
        guard AppPaths.isRunningAsBundle, defaults.object(forKey: "launchAtLoginDefaultApplied") == nil else { return }
        refreshLaunchAtLogin()
        if !launchAtLogin { launchAtLogin = true }
        let status = launchAtLoginStatus
        LifecycleLog.note("login item kaydı: durum=\(status.rawValue) (0 kayıtsız, 1 etkin, 2 onay bekliyor, 3 bulunamadı)")
        if status == .enabled || status == .requiresApproval { defaults.set(true, forKey: "launchAtLoginDefaultApplied") }
    }

    private func persist(_ value: Any, _ key: String) {
        if let previous = defaults.object(forKey: key) as? NSObject,
           previous.isEqual(value) { return }
        defaults.set(value, forKey: key)
        if batchingChanges { hasPendingChange = true } else { onChange?() }
    }
}

enum HoverPreset: String, CaseIterable, Identifiable {
    case off, quick, normal, relaxed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Kapalı"
        case .quick: "Hızlı"
        case .normal: "Normal"
        case .relaxed: "Rahat"
        }
    }

    /// Açılmadan önceki bekleme. Normal (100 ms) menü çubuğuna giden imleci yakalamaz,
    /// ama bilinçli bir duraksamaya da gecikmiş hissettirmez.
    var delay: Double? {
        switch self {
        case .off: nil
        case .quick: 0.06
        case .normal: 0.10
        case .relaxed: 0.25
        }
    }

    static func nearest(to delay: Double) -> HoverPreset {
        [.quick, .normal, .relaxed].min { abs($0.delay! - delay) < abs($1.delay! - delay) } ?? .normal
    }
}

/// Ham değerler eski ayarlarla uyumludur ("natural", "expressive", "reduced"); yalnızca adlar ve Canlı'nın süreleri değişti.
enum MotionStyle: String, CaseIterable, Identifiable {
    /// Varsayılan. Hızlı: açılış ~0,22 sn'de tepe (~%3 aşım), kapanış ~0,2 sn (aşımsız), imleç çıkınca 0,10 sn bekleme.
    case expressive
    /// Sakin: ~%2 aşımlı yumuşak açılış (~0,44 sn), sekmesiz kapanış (~0,5 sn), 0,35 sn bekleme.
    case natural
    /// Aşımsız, kısa yaylar (sistemin "Hareketi Azalt" ayarı da bunu seçer).
    case reduced

    var id: String { rawValue }
    var title: String {
        switch self {
        case .expressive: "Canlı"
        case .natural: "Sakin"
        case .reduced: "Azaltılmış"
        }
    }

    /// İmleç adadan çıktıktan sonra kapanmadan önceki bekleme (yanlışlıkla kapanmayı önler).
    var collapseGraceDelay: TimeInterval {
        self == .expressive ? 0.10 : 0.35
    }
}

/// Nook sekmesindeki widget kümesi. Medya her düzende en soldadır (kalıcı kapak katmanı oraya akar).
enum NookLayout: String, CaseIterable, Identifiable {
    case minimal, balanced, productivity

    var id: String { rawValue }
    var title: String {
        switch self {
        case .minimal: "Sade"
        case .balanced: "Dengeli"
        case .productivity: "Üretkenlik"
        }
    }

    var summary: String {
        switch self {
        case .minimal: "Medya ve takvim."
        case .balanced: "Medya, takvim ve anımsatıcılar."
        case .productivity: "Medya, takvim, anımsatıcılar ve uygulama kısayolları."
        }
    }

    var showsReminders: Bool { self != .minimal }
    var showsShortcuts: Bool { self == .productivity }
    /// Medyanın sağındaki widget sayısı; Nook genişliği buna göre hesaplanır (`NotchMetrics.nookWidgetCount`).
    var widgetCount: Int {
        switch self {
        case .minimal: 1
        case .balanced: 2
        case .productivity: 3
        }
    }
}
