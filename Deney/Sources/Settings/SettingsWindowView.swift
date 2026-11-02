import AppKit
import IslandCore
import ServiceManagement

/// Ayarlar penceresi (macOS Sistem Ayarları düzeninde): solda uygulama başlığı ve renkli simgeli sayfa listesi, sağda
/// seçili sayfanın gruplu kartları. Başlık çubuğu saydam, içerik onun altına uzanır.
@MainActor
enum SettingsWindowFactory {
    static let contentSize = NSSize(width: 800, height: 620)

    static func makeWindow(environment: AppEnvironment) -> NSWindow {
        let controller = NSViewController()
        controller.view = SettingsRootView(environment: environment)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "OpenIsland Ayarları"
        window.setContentSize(contentSize)
        return window
    }
}

/// Kök: kenar çubuğu (uygulama başlığı + kaynak listesi) ve seçili sayfa. Sayfalar ilk seçilişte kurulur.
@MainActor
final class SettingsRootView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct Page {
        let title: String
        let symbol: String
        let tint: NSColor
        let make: () -> NSView
    }

    static let sidebarWidth: CGFloat = 220
    private static let titlebarHeight: CGFloat = 28
    private let pages: [Page]
    private var built: [Int: NSView] = [:]
    private var current = -1
    private let sidebar = NSVisualEffectView()
    private let header = SettingsSidebarHeader()
    private let scroll = NSScrollView()
    private let table = SettingsSidebarTable()
    private let container = NSView()
    private let divider = NSBox()

    init(environment: AppEnvironment) {
        pages = [
            Page(title: "Ada", symbol: "capsule.fill", tint: .systemIndigo) { SettingsContent.general(environment) },
            Page(title: "Bildirimler", symbol: "bell.badge.fill", tint: .systemRed) { SettingsContent.notifications(environment) },
            Page(title: "Modüller", symbol: "square.grid.2x2.fill", tint: .systemPurple) { SettingsContent.modules(environment.preferences) },
            Page(title: "Sistem", symbol: "gearshape.fill", tint: .systemGray) { SettingsContent.system(environment) },
            Page(title: "İzinler", symbol: "hand.raised.fill", tint: .systemBlue) { SettingsContent.permissions(environment) },
        ]
        super.init(frame: CGRect(origin: .zero, size: SettingsWindowFactory.contentSize))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Ayarlar bölümleri")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        divider.boxType = .separator
        [header, scroll].forEach(sidebar.addSubview)
        [sidebar, divider, container].forEach(addSubview)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        show(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override var isFlipped: Bool { true }

    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let page = pages[row]
        return SettingsSidebarCell(title: page.title, symbol: page.symbol, tint: page.tint)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow >= 0 { show(table.selectedRow) }
    }

    private func show(_ index: Int) {
        guard index != current, pages.indices.contains(index) else { return }
        current = index
        let view = built[index] ?? {
            let view = pages[index].make()
            built[index] = view
            container.addSubview(view)
            return view
        }()
        for (key, other) in built { other.isHidden = key != index }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
    }

    override func layout() {
        super.layout()
        let width = Self.sidebarWidth
        sidebar.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        divider.frame = CGRect(x: width, y: 0, width: 1, height: bounds.height)
        // Kenar çubuğu (çevrilmemiş): sayfa listesi başlık çubuğunun altından, uygulama başlığı en altta.
        header.frame = CGRect(x: 0, y: 14, width: width, height: 52)
        let listTop = bounds.height - Self.titlebarHeight - 10
        scroll.frame = CGRect(x: 10, y: header.frame.maxY + 12, width: width - 20, height: listTop - header.frame.maxY - 12)
        container.frame = CGRect(x: width + 1, y: Self.titlebarHeight, width: bounds.width - width - 1, height: bounds.height - Self.titlebarHeight)
        built[current]?.frame = container.bounds
    }
}

/// Kenar çubuğu başlığı: uygulama simgesi, adı ve sürümü.
@MainActor
private final class SettingsSidebarHeader: FlippedView {
    private let icon = NSImageView()
    private let name = TextLabel("OpenIsland", font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
    private let version: TextLabel

    override init(frame: NSRect) {
        let value = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        version = TextLabel(value.isEmpty ? "Ayarlar" : "Sürüm \(value)", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        super.init(frame: frame)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        [icon, name, version].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 14, y: 4, width: 44, height: 44)
        let x: CGFloat = 14 + 44 + 8
        name.frame = CGRect(x: x, y: 9, width: min(pixelCeil(name.exactWidth), bounds.width - x - 8), height: 16)
        version.frame = CGRect(x: x, y: 27, width: min(pixelCeil(version.exactWidth), bounds.width - x - 8), height: 14)
    }
}

/// Kaynak listesi: klavyeyle (oklar) ve VoiceOver ile gezilir.
private final class SettingsSidebarTable: NSTableView {
    override var acceptsFirstResponder: Bool { true }
}

/// Kenar çubuğu satırı: renkli simge kutucuğu + sayfa adı.
@MainActor
private final class SettingsSidebarCell: NSTableCellView {
    private let tile: SettingsIconTile
    private let label: NSTextField

    init(title: String, symbol: String, tint: NSColor) {
        tile = SettingsIconTile(symbol: symbol, tint: tint)
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        textField = label
        [tile, label].forEach(addSubview)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func layout() {
        super.layout()
        tile.frame = CGRect(x: 6, y: (bounds.height - SettingsIconTile.size) / 2, width: SettingsIconTile.size, height: SettingsIconTile.size)
        let h = label.fittingSize.height
        label.frame = CGRect(x: 6 + SettingsIconTile.size + 10, y: (bounds.height - h) / 2, width: bounds.width - 46, height: h)
    }
}

/// Sayfaların içeriği. Metinler ve ayar anahtarları önceki form ile aynı; ayarlar ilgili sayfalara bölündü.
@MainActor
enum SettingsContent {
    private static func toggle(_ p: Preferences, _ title: String, _ keyPath: ReferenceWritableKeyPath<Preferences, Bool>,
                               symbol: String, tint: NSColor, detail: String? = nil, enabled: (() -> Bool)? = nil) -> SettingsToggleRow {
        SettingsToggleRow(title, symbol: symbol, tint: tint, detail: detail,
                          get: { p[keyPath: keyPath] }, set: { p[keyPath: keyPath] = $0 }, enabled: enabled)
    }

    /// Ada: önizleme, görünüm, hareket ve ekranlar.
    static func general(_ environment: AppEnvironment) -> NSView {
        let p = environment.preferences
        let notch = environment.screens.screens.first { $0.isBuiltIn && $0.hasNotch }?.notchRect?.size
        let preview = IslandPreviewView(preferences: p, notchSize: notch ?? IslandPreviewView.typicalNotch)
        func segmented<T: Equatable>(_ title: String, symbol: String, tint: NSColor, _ cases: [T], titles: (T) -> String,
                                     _ keyPath: ReferenceWritableKeyPath<Preferences, T>) -> SettingsSegmentedRow {
            SettingsSegmentedRow(title, symbol: symbol, tint: tint, items: cases.map(titles),
                                 get: { cases.firstIndex(of: p[keyPath: keyPath]) ?? -1 },
                                 set: { if cases.indices.contains($0) { p[keyPath: keyPath] = cases[$0] } })
        }
        func popup<T: Equatable>(_ title: String, symbol: String, tint: NSColor, _ cases: [T], titles: (T) -> String,
                                 _ keyPath: ReferenceWritableKeyPath<Preferences, T>) -> SettingsPopUpRow {
            SettingsPopUpRow(title, symbol: symbol, tint: tint, items: cases.map(titles),
                             get: { cases.firstIndex(of: p[keyPath: keyPath]) ?? -1 },
                             set: { if cases.indices.contains($0) { p[keyPath: keyPath] = cases[$0] } })
        }
        let sizes: [ExpandedSurfaceSize] = [.compact, .standard]
        let sections = [
            SettingsSection(rows: [SettingsViewRow(preview, fullBleed: true) { preview.preferredHeight }],
                            footer: "Önizleme: üzerine gel veya tıkla; seçili hareket stiliyle açılır."),
            SettingsSection(header: "Görünüm", rows: [
                segmented("Açık ada boyutu", symbol: "arrow.up.left.and.arrow.down.right", tint: .systemTeal, sizes,
                          titles: { $0 == .compact ? "Kompakt" : "Standart" }, \.expandedSurfaceSize),
            ], footer: "Çentiğe kesintisiz bağlı yüzey. Kompakt görünüm çevredeki boşluğu azaltır; sekmeler ve içerikler aynı boyutta kalır."),
            SettingsSection(header: "Hareket ve his", rows: [
                segmented("Üzerine gelince aç", symbol: "cursorarrow.rays", tint: .systemBlue, HoverPreset.allCases, titles: \.title, \.hoverPreset),
                segmented("Hareket", symbol: "wind", tint: .systemCyan, MotionStyle.allCases, titles: \.title, \.motionStyle),
                toggle(p, "Dokunsal geri bildirim (Force Touch trackpad)", \.hapticsEnabled, symbol: "hand.tap.fill", tint: .systemPink),
                toggle(p, "Düşük Güç Modu'nda pil tasarrufu", \.energySaving, symbol: "leaf.fill", tint: .systemGreen),
                toggle(p, "Müzik nabzı albüm renginde", \.albumColoredPulse, symbol: "waveform", tint: .systemOrange),
            ], footer: "Hızlı: 60 ms bekleme. Canlı: hızlı açılır (~0,22 sn) ve kapanır (~0,18 sn). Sakin: yumuşak ve yavaş. Sistemdeki \"Hareketi Azalt\" ayarı açıksa hareket her zaman azaltılmış olur. Pil tasarrufu: Düşük Güç Modu açıkken veya Mac ısındığında müzik nabzı sabitlenir ve hareket kısalır; seçtiğin Hareket ayarı değişmez."),
            SettingsSection(header: "Ekranlar", rows: [
                popup("Gösterilecek ekran", symbol: "display", tint: .systemBlue, DisplayTarget.allCases, titles: \.title, \.displayTarget),
                popup("Tam ekranda", symbol: "rectangle.inset.filled", tint: .systemIndigo, FullscreenBehavior.allCases, titles: \.title, \.fullscreenBehavior),
            ], dynamicFooter: { p.fullscreenBehavior.summary + " Çentiksiz ekranlarda ada, menü çubuğunun altında yüzen bir kapsüldür." }),
        ]
        return SettingsFormView(title: "Ada", subtitle: "Çentikteki adanın görünümü, hareketi ve hangi ekranda görüneceği.", sections: sections)
    }

    /// Bildirimler: adanın kısa süre gösterdiği olaylar.
    static func notifications(_ environment: AppEnvironment) -> NSView {
        let p = environment.preferences
        return SettingsFormView(title: "Bildirimler", subtitle: "Ada, kısa süreli olayları çentikte gösterir. Görmek istediklerini seç.", sections: [
            SettingsSection(header: "Geçici bildirimler", rows: [
                toggle(p, "Ağ bağlantısı kesildi / geri geldi", \.networkNotices, symbol: "wifi", tint: .systemBlue),
                toggle(p, "Harici ekran ve ekran düzeni değişikliği", \.displayNotices, symbol: "display.2", tint: .systemTeal),
                toggle(p, "Pil ve şarj (adaptör, %20, %10, %100)", \.batteryNotices, symbol: "battery.100percent.bolt", tint: .systemGreen),
                toggle(p, "Ses aygıtı bağlandı / ayrıldı (AirPods, kulaklık)", \.audioDeviceNotices, symbol: "headphones", tint: .systemPurple),
                toggle(p, "Parça değişimi", \.trackChangeNotices, symbol: "music.note", tint: .systemPink),
                toggle(p, "Toplantı hatırlatması (5 dk önce)", \.meetingReminders, symbol: "calendar", tint: .systemRed),
                toggle(p, "Kilit açıldı", \.unlockNotices, symbol: "lock.open.fill", tint: .systemGray),
            ]),
        ])
    }

    /// Sistem: Dock, pencere kapatma, kısayol, başlangıç ve demo modu.
    static func system(_ environment: AppEnvironment) -> NSView {
        let p = environment.preferences
        let form = SettingsFormView(title: "Sistem", subtitle: "Dock, pencere kapatma, kısayol ve başlangıç davranışları.", sections: [
            SettingsSection(header: "Pencereler ve Dock", rows: [
                toggle(p, "Dock'ta pencere önizlemeleri", \.dockWindowPreviews, symbol: "dock.rectangle", tint: .systemBlue,
                       detail: "Uygulama simgesinde durunca açık pencereleri gösterir; tıklayınca seçili pencereye geçer. Erişilebilirlik ve ekran erişimi gerekir. Görüntüler kaydedilmez; sürekli ekran yakalama yapılmaz."),
                toggle(p, "Son pencereyi kırmızı düğmeden kapatınca uygulamadan çık", \.quitOnLastWindowClose, symbol: "xmark.circle.fill", tint: .systemRed,
                       detail: "Erişilebilirlik izni gerekir. Diğer açık pencereler ve kaydetme uyarıları korunur; Finder kapanmaz."),
            ]),
            SettingsSection(header: "Başlatma ve kısayollar", rows: [
                toggle(p, "Klavye kısayolu ⌃⌥⌘I ile aç/kapat", \.globalHotKey, symbol: "command", tint: .systemGray),
                SettingsToggleRow("Oturum açılışında başlat", symbol: "power", tint: .systemGreen, get: { p.launchAtLogin },
                                  set: { p.launchAtLogin = $0 }, enabled: { AppPaths.isRunningAsBundle }),
                SettingsButtonRow("Oturum Açma Öğeleri’nde Onayla", visible: { p.launchAtLoginStatus == .requiresApproval }) {
                    SMAppService.openSystemSettingsLoginItems()
                },
                SettingsCaptionRow { p.launchAtLoginError },
                toggle(p, "Demo modu (ekran kaydı ve sunum)", \.demoMode, symbol: "play.rectangle.fill", tint: .systemPurple),
            ], footer: "Demo modunda ada kendiliğinden kapanmaz, duraklatılan müzik kanatta kalır ve tam ekranda da görünür. Adayı kapatmak için ona sağ tıkla veya ⌃⌥⌘I kısayolunu kullan; demo modu da aynı menüden açılıp kapanır. Saklanmaz: uygulama yeniden açılınca kapalı başlar."),
        ])
        p.refreshLaunchAtLogin()
        SettingsActivation.observe(form) { p.refreshLaunchAtLogin() }
        return form
    }

    static func modules(_ p: Preferences) -> NSView {
        let layouts = NookLayout.allCases
        return SettingsFormView(title: "Modüller", subtitle: "Açık adanın sekmeleri ve sistem entegrasyonları.", sections: [
            SettingsSection(rows: [
                SettingsSegmentedRow("Nook düzeni", symbol: "square.split.2x1.fill", tint: .systemIndigo, items: layouts.map(\.title),
                                     get: { layouts.firstIndex(of: p.nookLayout) ?? -1 },
                                     set: { if layouts.indices.contains($0) { p.nookLayout = layouts[$0] } }),
            ], dynamicFooter: { p.nookLayout.summary }),
            SettingsSection(header: "Sekmeler", rows: [
                toggle(p, "Pano geçmişi ve renk seçici", \.clipboardHistoryEnabled, symbol: "doc.on.clipboard.fill", tint: .systemOrange),
                toggle(p, "Odak: zamanlayıcı, takvim, anımsatıcılar", \.focusModule, symbol: "timer", tint: .systemRed),
                toggle(p, "Notlar ve uygulama kısayolları", \.notesModule, symbol: "note.text", tint: .systemYellow),
                toggle(p, "Ayna (kamera önizlemesi)", \.mirrorModule, symbol: "camera.fill", tint: .systemGray),
                toggle(p, "Sistem: CPU, GPU, bellek, sıcaklık, parlaklık", \.systemModule, symbol: "cpu.fill", tint: .systemGreen),
            ], footer: "Kapalı modülün sekmesi gösterilmez ve arka planda hiçbir şey çalıştırmaz. Nook, Medya ve Raf her zaman açıktır."),
            SettingsSection(header: "Sistem entegrasyonu", rows: [
                toggle(p, "Sıcaklık, parlaklık ve klavye ışığı", \.systemPrivateSensors, symbol: "thermometer.medium", tint: .systemOrange),
                toggle(p, "Trackpad jestleri (yatay: parça, dikey: ses)", \.gesturesEnabled, symbol: "hand.draw.fill", tint: .systemBlue),
                toggle(p, "Medya jestini ters çevir (sağa kaydır: sonraki parça)", \.reversesMediaSwipe, symbol: "arrow.left.arrow.right",
                       tint: .systemBlue, enabled: { p.gesturesEnabled }),
                toggle(p, "İndirme / aktarım canlı etkinliği", \.transferActivity, symbol: "arrow.down.circle.fill", tint: .systemTeal),
            ]),
        ])
    }

    /// İzinler: durumlar yalnız bu sekme açılınca ve uygulama yeniden etkinleşince okunur (SwiftUI ile aynı).
    static func permissions(_ environment: AppEnvironment) -> NSView {
        let permissions = environment.permissions
        let rows = PermissionsCenter.Kind.allCases.map { kind in
            SettingsStatusRow(symbol: permissionIcon(kind).0, tint: permissionIcon(kind).1, source: {
                let entry = permissions.entries.first { $0.kind == kind }!
                return SettingsStatusRow.Content(title: entry.title, detail: entry.reason, status: entry.state.label,
                                                 symbol: permissionSymbol(entry.state), positive: entry.state == .granted,
                                                 action: permissionAction(entry), waiting: entry.isRequesting)
            }, perform: { permissions.resolve(kind, reminders: environment.reminders, calendar: environment.calendar) })
        }
        let space = SettingsStatusRow(symbol: "rectangle.3.group.fill", tint: .systemIndigo,
                                      source: { spaceContent(SpacePresentationController.shared.status) })
        let form = SettingsFormView(title: "İzinler", subtitle: "OpenIsland'in kullandığı izinler ve ada penceresinin durumu.", sections: [
            SettingsSection(rows: rows, footer: "Hiçbir izin zorunlu değildir. İzin verilmeyen özellik sessizce geriler; uygulamanın geri kalanı etkilenmez."),
            SettingsSection(header: "Ada penceresi", rows: [space]),
        ])
        permissions.refresh()
        SettingsActivation.observe(form) { permissions.refresh() }
        return form
    }

    private static func permissionIcon(_ kind: PermissionsCenter.Kind) -> (String, NSColor) {
        switch kind {
        case .accessibility: ("accessibility", .systemBlue)
        case .screenCapture: ("rectangle.dashed.badge.record", .systemPurple)
        case .camera: ("camera.fill", .systemGray)
        case .calendar: ("calendar", .systemRed)
        case .reminders: ("checklist", .systemOrange)
        case .spotify: ("music.note", .systemGreen)
        case .music: ("music.note.list", .systemPink)
        case .clipboard: ("doc.on.clipboard.fill", .systemOrange)
        case .notifications: ("bell.badge.fill", .systemRed)
        }
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
