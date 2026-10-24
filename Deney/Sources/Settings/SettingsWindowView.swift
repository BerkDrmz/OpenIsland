import AppKit
import IslandCore
import ServiceManagement

/// Ayarlar penceresi (SwiftUI `SettingsView` karşılığı): 560 × 600 içerik, `NSTabView` (SwiftUI `TabView`'in kullandığı
/// denetimin kendisi, aynı çerçeveyle), her sekmede gruplu form.
@MainActor
enum SettingsWindowFactory {
    static func makeWindow(environment: AppEnvironment) -> NSWindow {
        let controller = NSViewController()
        controller.view = SettingsRootView(environment: environment)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "OpenIsland Deney Ayarları"
        window.setContentSize(NSSize(width: 560, height: 600))
        return window
    }
}

/// Kök: SwiftUI barındırma kökü gibi AX grubu; sekme görünümü SwiftUI'nin yerleştirdiği çerçevede (−7, −10, 574 × 616).
@MainActor
final class SettingsRootView: NSView {
    private let tabs = SettingsTabView()

    init(environment: AppEnvironment) {
        super.init(frame: CGRect(x: 0, y: 0, width: 560, height: 600))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let items: [(String, () -> NSView)] = [
            ("Genel", { SettingsContent.general(environment) }),
            ("Modüller", { SettingsContent.modules(environment.preferences) }),
            ("Sistem Erişimi", { SettingsContent.permissions(environment) }),
        ]
        for (title, make) in items {
            let item = SettingsTabItem(make: make)
            item.label = title
            tabs.addTabViewItem(item)
        }
        (tabs.selectedTabViewItem as? SettingsTabItem)?.load()
        tabs.frame = CGRect(x: -7, y: -10, width: 574, height: 616)
        addSubview(tabs)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }
}

/// Sekme içeriği ilk seçilişte kurulur (SwiftUI `TabView` gibi tembel).
@MainActor
private final class SettingsTabItem: NSTabViewItem {
    private let make: () -> NSView
    private var loaded = false

    init(make: @escaping () -> NSView) {
        self.make = make
        super.init(identifier: nil)
        view = NSView()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("desteklenmiyor") }

    func load() {
        guard !loaded else { return }
        loaded = true
        view = make()
    }
}

/// Seçilen sekmenin içeriği gösterilmeden önce kurulur.
private final class SettingsTabView: NSTabView {
    /// SwiftUI: sekme grubunun AX çerçevesi barındırıcının çerçevesi (pencere içeriği), denetiminki değil.
    override func accessibilityFrame() -> NSRect {
        guard let window, let superview else { return super.accessibilityFrame() }
        return window.convertToScreen(superview.convert(superview.bounds, to: nil))
    }

    override func selectTabViewItem(_ tabViewItem: NSTabViewItem?) {
        (tabViewItem as? SettingsTabItem)?.load()
        super.selectTabViewItem(tabViewItem)
    }
}

/// Sekmelerin içeriği: SwiftUI `GeneralSettings`, `ModuleSettings`, `PermissionSettings` ile aynı sıra ve metinler.
@MainActor
enum SettingsContent {
    static func general(_ environment: AppEnvironment) -> NSView {
        let p = environment.preferences
        let notch = environment.screens.screens.first { $0.isBuiltIn && $0.hasNotch }?.notchRect?.size
        let preview = IslandPreviewView(preferences: p, notchSize: notch ?? IslandPreviewView.typicalNotch)
        func toggle(_ title: String, _ keyPath: ReferenceWritableKeyPath<Preferences, Bool>, enabled: (() -> Bool)? = nil) -> SettingsToggleRow {
            SettingsToggleRow(title, get: { p[keyPath: keyPath] }, set: { p[keyPath: keyPath] = $0 }, enabled: enabled)
        }
        func segmented<T: Equatable>(_ title: String, _ cases: [T], titles: (T) -> String, _ keyPath: ReferenceWritableKeyPath<Preferences, T>) -> SettingsSegmentedRow {
            SettingsSegmentedRow(title, items: cases.map(titles), get: { cases.firstIndex(of: p[keyPath: keyPath]) ?? -1 },
                                 set: { if cases.indices.contains($0) { p[keyPath: keyPath] = cases[$0] } })
        }
        func popup<T: Equatable>(_ title: String, _ cases: [T], titles: (T) -> String, _ keyPath: ReferenceWritableKeyPath<Preferences, T>) -> SettingsPopUpRow {
            SettingsPopUpRow(title, items: cases.map(titles), get: { cases.firstIndex(of: p[keyPath: keyPath]) ?? -1 },
                             set: { if cases.indices.contains($0) { p[keyPath: keyPath] = cases[$0] } })
        }
        let sizes: [ExpandedSurfaceSize] = [.compact, .standard]
        let sections = [
            SettingsSection(rows: [SettingsViewRow(preview) { preview.preferredHeight }],
                            footer: "Önizleme: üzerine gel veya tıkla; seçili hareket stiliyle açılır."),
            SettingsSection(header: "Açık ada görünümü",
                            rows: [segmented("Açık ada boyutu", sizes, titles: { $0 == .compact ? "Kompakt" : "Standart" }, \.expandedSurfaceSize)],
                            footer: "Çentiğe kesintisiz bağlı yüzey. Kompakt görünüm çevredeki boşluğu azaltır; sekmeler ve içerikler aynı boyutta kalır."),
            SettingsSection(header: "Ada", rows: [
                segmented("Üzerine gelince aç", HoverPreset.allCases, titles: \.title, \.hoverPreset),
                segmented("Hareket", MotionStyle.allCases, titles: \.title, \.motionStyle),
                toggle("Dokunsal geri bildirim (Force Touch trackpad)", \.hapticsEnabled),
                toggle("Düşük Güç Modu'nda pil tasarrufu", \.energySaving),
                toggle("Müzik nabzı albüm renginde", \.albumColoredPulse),
            ], footer: "Hızlı: 60 ms bekleme. Canlı: hızlı açılır (~0,22 sn) ve kapanır (~0,18 sn). Sakin: yumuşak ve yavaş. Sistemdeki \"Hareketi Azalt\" ayarı açıksa hareket her zaman azaltılmış olur. Pil tasarrufu: Düşük Güç Modu açıkken veya Mac ısındığında müzik nabzı sabitlenir ve hareket kısalır; seçtiğin Hareket ayarı değişmez."),
            SettingsSection(header: "Ekranlar", rows: [
                popup("Gösterilecek ekran", DisplayTarget.allCases, titles: \.title, \.displayTarget),
                popup("Tam ekranda", FullscreenBehavior.allCases, titles: \.title, \.fullscreenBehavior),
            ], dynamicFooter: { p.fullscreenBehavior.summary + " Çentiksiz ekranlarda ada, menü çubuğunun altında yüzen bir kapsüldür." }),
            SettingsSection(header: "Geçici bildirimler", rows: [
                toggle("Ağ bağlantısı kesildi / geri geldi", \.networkNotices),
                toggle("Harici ekran ve ekran düzeni değişikliği", \.displayNotices),
                toggle("Pil ve şarj (adaptör, %20, %10, %100)", \.batteryNotices),
                toggle("Ses aygıtı bağlandı / ayrıldı (AirPods, kulaklık)", \.audioDeviceNotices),
                toggle("Parça değişimi", \.trackChangeNotices),
                toggle("Toplantı hatırlatması (5 dk önce)", \.meetingReminders),
                toggle("Kilit açıldı", \.unlockNotices),
            ]),
            SettingsSection(header: "Sistem", rows: [
                toggle("Dock'ta pencere önizlemeleri", \.dockWindowPreviews),
                SettingsCaptionRow("Uygulama simgesinde durunca açık pencereleri gösterir; tıklayınca seçili pencereye geçer. Erişilebilirlik ve ekran erişimi gerekir. Görüntüler kaydedilmez; sürekli ekran yakalama yapılmaz."),
                toggle("Son pencereyi kırmızı düğmeden kapatınca uygulamadan çık", \.quitOnLastWindowClose),
                SettingsCaptionRow("Erişilebilirlik izni gerekir. Diğer açık pencereler ve kaydetme uyarıları korunur; Finder kapanmaz."),
                toggle("Klavye kısayolu ⌃⌥⌘I ile aç/kapat", \.globalHotKey),
                SettingsToggleRow("Oturum açılışında başlat", get: { p.launchAtLogin }, set: { p.launchAtLogin = $0 },
                                  enabled: { AppPaths.isRunningAsBundle }),
                SettingsButtonRow("Oturum Açma Öğeleri’nde Onayla", visible: { p.launchAtLoginStatus == .requiresApproval }) {
                    SMAppService.openSystemSettingsLoginItems()
                },
                SettingsCaptionRow { p.launchAtLoginError },
                toggle("Demo modu (ekran kaydı ve sunum)", \.demoMode),
            ], footer: "Demo modunda ada kendiliğinden kapanmaz, duraklatılan müzik kanatta kalır ve tam ekranda da görünür. Adayı kapatmak için ona sağ tıkla veya ⌃⌥⌘I kısayolunu kullan; demo modu da aynı menüden açılıp kapanır. Saklanmaz: uygulama yeniden açılınca kapalı başlar."),
        ]
        let form = SettingsFormView(sections: sections)
        p.refreshLaunchAtLogin()
        SettingsActivation.observe(form) { p.refreshLaunchAtLogin() }
        return form
    }

    static func modules(_ p: Preferences) -> NSView {
        func toggle(_ title: String, _ keyPath: ReferenceWritableKeyPath<Preferences, Bool>, enabled: (() -> Bool)? = nil) -> SettingsToggleRow {
            SettingsToggleRow(title, get: { p[keyPath: keyPath] }, set: { p[keyPath: keyPath] = $0 }, enabled: enabled)
        }
        let layouts = NookLayout.allCases
        return SettingsFormView(sections: [
            SettingsSection(rows: [
                SettingsSegmentedRow("Nook düzeni", items: layouts.map(\.title), get: { layouts.firstIndex(of: p.nookLayout) ?? -1 },
                                     set: { if layouts.indices.contains($0) { p.nookLayout = layouts[$0] } }),
            ], dynamicFooter: { p.nookLayout.summary }),
            SettingsSection(header: "Sekmeler", rows: [
                toggle("Pano geçmişi ve renk seçici", \.clipboardHistoryEnabled),
                toggle("Odak: zamanlayıcı, takvim, anımsatıcılar", \.focusModule),
                toggle("Notlar ve uygulama kısayolları", \.notesModule),
                toggle("Ayna (kamera önizlemesi)", \.mirrorModule),
                toggle("Sistem: CPU, GPU, bellek, sıcaklık, parlaklık", \.systemModule),
            ], footer: "Kapalı modülün sekmesi gösterilmez ve arka planda hiçbir şey çalıştırmaz. Nook, Medya ve Raf her zaman açıktır."),
            SettingsSection(header: "Sistem entegrasyonu", rows: [
                toggle("Sıcaklık, parlaklık ve klavye ışığı", \.systemPrivateSensors),
                toggle("Trackpad jestleri (yatay: parça, dikey: ses)", \.gesturesEnabled),
                toggle("Medya jestini ters çevir (sağa kaydır: sonraki parça)", \.reversesMediaSwipe, enabled: { p.gesturesEnabled }),
                toggle("İndirme / aktarım canlı etkinliği", \.transferActivity),
            ]),
        ])
    }

    /// İzinler: durumlar yalnız bu sekme açılınca ve uygulama yeniden etkinleşince okunur (SwiftUI ile aynı).
    static func permissions(_ environment: AppEnvironment) -> NSView {
        let permissions = environment.permissions
        let rows = PermissionsCenter.Kind.allCases.map { kind in
            SettingsStatusRow(source: {
                let entry = permissions.entries.first { $0.kind == kind }!
                return SettingsStatusRow.Content(title: entry.title, detail: entry.reason, status: entry.state.label,
                                                 symbol: permissionSymbol(entry.state), positive: entry.state == .granted,
                                                 action: permissionAction(entry), waiting: entry.isRequesting)
            }, perform: { permissions.resolve(kind, reminders: environment.reminders, calendar: environment.calendar) })
        }
        let space = SettingsStatusRow(source: { spaceContent(SpacePresentationController.shared.status) })
        let form = SettingsFormView(sections: [
            SettingsSection(rows: rows, footer: "Hiçbir izin zorunlu değildir. İzin verilmeyen özellik sessizce geriler; uygulamanın geri kalanı etkilenmez."),
            SettingsSection(header: "Ada penceresi", rows: [space]),
        ])
        permissions.refresh()
        SettingsActivation.observe(form) { permissions.refresh() }
        return form
    }

    private static func permissionSymbol(_ state: PermissionsCenter.State) -> String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .notGranted: "xmark.circle"
        case .askOnUse: "questionmark.circle"
        case .unsupported: "minus.circle"
        case .unavailable: "exclamationmark.circle"
        }
    }

    private static func permissionAction(_ entry: PermissionsCenter.Entry) -> String? {
        switch entry.state {
        case .granted, .unsupported: nil
        case .askOnUse: entry.kind == .clipboard ? "Ayarlar" : "İzin İste"
        case .notGranted: "Ayarları Aç"
        case .unavailable: "Yeniden Dene"
        }
    }

    private static func spaceContent(_ status: SpacePresentationStatus) -> SettingsStatusRow.Content {
        var behavior: SpaceBehavior?
        var provider: SpaceProviderKind?
        if case .settled(let p, let b) = status { provider = p; behavior = b }
        let title: String, symbol: String
        switch behavior {
        case nil: (title, symbol) = ("Denetleniyor", "clock")
        case .pinned: (title, symbol) = ("Ada sabit", "checkmark.circle.fill")
        case .unverified: (title, symbol) = ("Doğrulanamadı", "questionmark.circle")
        case .slides: (title, symbol) = ("Yedek mod", "exclamationmark.circle")
        case .hidden: (title, symbol) = ("Ada görünmüyor", "xmark.octagon")
        }
        let method: String = switch provider {
        case .privateSpace: "ayrı WindowServer Space'i"
        case .publicStationary: "yalnızca public AppKit"
        case .safeFallback: "güvenli yedek"
        case nil: ""
        }
        let detail: String = switch behavior {
        case nil: "Ada penceresinin davranışı doğrulanıyor."
        case .pinned: "Dört parmakla kaydırmada, tam ekrana giriş ve çıkışta ve Mission Control'de ada yerinde kalır (\(method))."
        case .unverified: "Ada görünür; bu macOS sürümünde sabit kaldığı doğrulanamıyor (\(method))."
        case .slides: "Ada görünür ama Space değişirken kayabilir (\(method)). Uyanma, kilit açma veya ekran değişiminde yeniden denenir."
        case .hidden: "Ada bir ekranda görünmüyor; uyanma, kilit açma veya ekran değişiminde yeniden denenir."
        }
        return SettingsStatusRow.Content(title: "Space geçişleri", detail: detail, status: title, symbol: symbol,
                                         positive: behavior == .pinned, action: nil, waiting: false)
    }
}

/// SwiftUI `.onReceive(NSApplication.didBecomeActiveNotification)`: görünüm yaşadıkça uygulama etkinleşince çalışır.
@MainActor
enum SettingsActivation {
    static func observe(_ owner: NSView, _ action: @escaping @MainActor () -> Void) {
        let token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        objc_setAssociatedObject(owner, &key, SettingsObserverToken(token), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static var key: UInt8 = 0
}

private final class SettingsObserverToken {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
