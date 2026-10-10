import CoreGraphics

/// `notch`: donanım çentiğine yapışık, üst köşeleri içe kıvrılan siyah şekil.
/// `pill`: çentiksiz ekranlar ve harici monitörler için menü çubuğunun hemen altında yüzen kapsül.
public enum IslandStyle: Sendable, Equatable, Hashable {
    case notch
    case pill
}

/// Yalnızca açık çentiğin dış boşlukları ve köşeleri; içerik ölçüleri değişmez.
public enum ExpandedSurfaceSize: String, Sendable, CaseIterable, Equatable {
    case compact
    case standard
}

public struct NotchMetrics: Sendable, Equatable {
    /// Donanım çentiğinin (veya pill modunda sanal çentiğin) boyutu. Notch ekranlarda
    /// `auxiliaryTopLeftArea/RightArea` ve `safeAreaInsets.top` ile dinamik hesaplanır.
    public var notchSize: CGSize
    public var style: IslandStyle
    /// Pill modunda adanın ekranın üst kenarından ne kadar aşağıda yüzdüğü (menü çubuğu + boşluk).
    public var floatOffset: CGFloat
    /// Ekranın `backingScaleFactor`'ü: kenarlar bu ölçekte tam piksele hizalanır.
    public var scale: CGFloat
    /// Küçük notch, fiziksel çentikle aynı yüksekliktedir (`safeAreaInsets.top`): kanatların alt kenarı
    /// donanım çentiğinin alt kenarıyla hizalanır, çentik kanatların altından sarkmaz. Yalnızca en yakın
    /// ekran pikseline yuvarlanır (ölçülen çentik 33,5 pt = 2× ekranda tam 67 piksel; yuvarlama payı yok).
    /// Donanım ölçüsü korunur: açık yüzeyin başlığı ve içerik yüksekliği bundan etkilenmez.
    public var compactHeight: CGFloat {
        guard style == .notch else { return notchSize.height }
        return max((notchSize.height * scale).rounded(), 1) / scale
    }
    /// Küçük adanın alt kenarı çentiğin alt kenarından 0,10 pt yukarıda biter (33,5 pt çentikte 33,40 pt):
    /// tam piksel adımları (66 / 67) çentiğe göre biri kısa, diğeri biraz uzun kalıyordu; alt kenar yarı
    /// saydam bir satırla ikisinin arasına oturur. Yalnızca dinlenme yüksekliğindeki görünümlere uygulanır.
    public var restHeightTrim: CGFloat {
        style == .notch ? 0.10 : 0
    }
    /// Genişletilmiş adanın yükseklik ince ayarı (kullanıcı tercihi, −40…+60 pt).
    public var contentHeightOffset: CGFloat
    /// Pill modunda dinlenmedeki kapsül görünür mü (değilse görünmez "tutamaç" gibi davranır).
    public var showsIdlePill: Bool
    /// Nook'ta medyanın sağındaki widget sayısı (Sade 1, Dengeli 2, Üretkenlik 3). Nook genişliği buna
    /// göre içerikten hesaplanır; boş kalan bir kolon için yüzey genişlemez.
    public var nookWidgetCount: Int
    /// Genişletilmiş görünümlerin gösterdiği içerik miktarı: gövde bu kadar büyür (tuval bundan bağımsızdır).
    public var content: ExpandedContent
    public var expandedSurfaceSize: ExpandedSurfaceSize

    public init(notchSize: CGSize, style: IslandStyle, floatOffset: CGFloat = 0, scale: CGFloat = 2,
                contentHeightOffset: CGFloat = 0, showsIdlePill: Bool = true, nookWidgetCount: Int = 2,
                content: ExpandedContent = ExpandedContent(), expandedSurfaceSize: ExpandedSurfaceSize = .standard) {
        self.notchSize = notchSize
        self.style = style
        self.floatOffset = floatOffset
        self.scale = max(scale, 1)
        self.contentHeightOffset = contentHeightOffset
        self.showsIdlePill = showsIdlePill
        self.nookWidgetCount = nookWidgetCount
        self.content = content
        self.expandedSurfaceSize = expandedSurfaceSize
    }

    /// Çentiksiz ekranlarda kullanılan sanal çentik: menü çubuğunun hemen altında yüzer.
    public static func pill(menuBarHeight: CGFloat, scale: CGFloat = 2) -> NotchMetrics {
        NotchMetrics(notchSize: CGSize(width: 180, height: 30), style: .pill,
                     floatOffset: max(menuBarHeight, 22) + 5, scale: scale)
    }
}

/// Genişletilmiş görünümlerin içerik miktarı (yalnızca sayılar). Siyah gövde gösterdiği içerik kadar büyür;
/// her görünümün üst sınırında içerik kendi içinde kayar.
public struct ExpandedContent: Sendable, Equatable {
    public var clipboardItems: Int
    public var shelfItems: Int
    /// Odak sekmesinin takvim sütunundaki yaklaşan etkinlikler.
    public var upcomingEvents: Int
    /// Odak sekmesinin anımsatıcı sütunundaki bugünkü anımsatıcılar.
    public var reminders: Int
    public var launcherItems: Int

    public init(clipboardItems: Int = 0, shelfItems: Int = 0, upcomingEvents: Int = 0, reminders: Int = 0,
                launcherItems: Int = 0) {
        self.clipboardItems = clipboardItems
        self.shelfItems = shelfItems
        self.upcomingEvents = upcomingEvents
        self.reminders = reminders
        self.launcherItems = launcherItems
    }

    /// Her görünümün en büyük hali: sabit tuval bununla ölçülür, içerik değişince panel yeniden boyutlanmaz.
    public static let maximum = ExpandedContent(clipboardItems: 99, shelfItems: 99, upcomingEvents: 99,
                                                reminders: 99, launcherItems: 99)
}

public struct IslandLayout: Sendable, Equatable {
    public var size: CGSize
    /// Notch stilinde üstteki içbükey "kulak" yarıçapı; gövde kenarı bu kadar içeride başlar.
    public var topCornerRadius: CGFloat
    /// Alt köşelerin sürekli eğrilikli (squircle) yarıçapı.
    public var bottomCornerRadius: CGFloat
    /// 0 = donanıma gömülü (gölge yok), 1 = tam yükseltilmiş yüzey.
    public var elevation: Double
    /// 0...1 cam kenar ışığı (0,5 pt kontur) yoğunluğu.
    public var edgeHighlight: Double
    /// Şeklin panelin üst kenarından ne kadar aşağıda başladığı (pill modunda "yüzme" payı).
    public var topInset: CGFloat

    public init(size: CGSize, topCornerRadius: CGFloat, bottomCornerRadius: CGFloat, elevation: Double, edgeHighlight: Double, topInset: CGFloat) {
        self.size = size
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.elevation = elevation
        self.edgeHighlight = edgeHighlight
        self.topInset = topInset
    }
}

/// Bir katmanın ada koordinatlarındaki yeri (sol-üst orijin) ve eş-merkezli köşe yarıçapı.
public struct SlotFrame: Sendable, Equatable {
    public var rect: CGRect
    public var cornerRadius: CGFloat
}

/// Tuvalin adanın çevresinde bıraktığı pay (gölge ve yay taşması için).
public struct EdgeBleed: Sendable, Equatable {
    public var horizontal: CGFloat
    public var bottom: CGFloat
}

/// Her görünüm için hedef boyut, köşe yarıçapları ve iç yerleşim yuvalarını hesaplar.
/// Tüm tasarım ölçüleri burada tek noktada tutulur; SwiftUI bu değerler arasında yay
/// fiziğiyle interpolasyon yapar.
public enum IslandLayoutEngine {
    // MARK: Tasarım ölçüleri

    /// En yoğun görünüm (Nook, Üretkenlik) bile bu genişliği aşmaz; fazlası yatay kaydırılır.
    /// Revizyon 18: yan boşluklar 8 pt küçüldüğü için sınır da 8 pt indi; kayan içerik alanı (632 pt) aynı kaldı.
    public static let maxExpandedWidth: CGFloat = 672
    /// Başlık sekmeleri çentiğin iki yanına yaslanır; tüm sekmeler her zaman doğrudan tıklanabilir ("⋯" yok).
    /// Sistem özeti ve mikserle solda 5 sekme, sağda 4 sekme + iğne. Dar yuvalar toplam genişliği korur.
    public static let tabButtonSize = CGSize(width: 14, height: 24)
    public static let tabSpacing: CGFloat = 2.5
    public static let tabsPerSide = 5
    /// Soldan sağa sekme sırası: Müzik en başta. Sağda bunları iğne izler.
    public static let leadingTabOrder: [ExpandedTab] = [.media, .nook, .shelf, .clipboard, .mixer]
    public static let trailingTabOrder: [ExpandedTab] = [.focus, .notes, .mirror, .system]
    /// Nook sütunları: panel ve yerleşim aynı değerleri kullanır (medya metni; takvim, anımsatıcılar, kısayollar).
    public static let nookMediaTextWidth: CGFloat = 124
    public static let nookWidgetWidths: [CGFloat] = [170, 160, 150]
    /// İki sütun arasındaki ayırıcı + iki yanındaki boşluk.
    public static let columnDividerSpan: CGFloat = 12 * 2 + 0.5
    /// Medya panelindeki başlık / satır içi süre çubuğu (`1:12 ━━━ 3:47`) / kontrol sütunu.
    public static let mediaColumnWidth: CGFloat = 248
    /// Kapak ile sütun arası.
    public static let mediaArtworkGap: CGFloat = 12
    /// Genişletilmiş içerik ile gövde kenarı arasındaki boşluk. Eş-merkezli yarıçapların temeli:
    /// iç yarıçap = dış yarıçap − bu boşluk. (18 → 14 → 12 → 10: içerik ölçüleri aynı kalır, yalnızca gövdenin
    /// çevresindeki boş kenar azalır.)
    public static let contentInset: CGFloat = 10
    /// Başlık satırı (çentik yüksekliği) ile içerik arasındaki boşluk.
    public static let headerGap: CGFloat = 2
    /// Hover'da yüzeyin "kabarma" miktarı: fark edilir ama pencere açılıyormuş gibi değil.
    public static let hoverSwell = CGSize(width: 10, height: 4)
    public static let hudWingExtra: CGFloat = 40
    /// Bildirimde kanatlar biraz daha açılır ve çentiğin altında bir açıklama satırı belirir.
    public static let noticeWingExtra: CGFloat = 52
    public static let noticeCaptionHeight: CGFloat = 26
    /// Kilit açılma geri bildirimi: normal bildirimden geniş, açıklama satırı yok; sembol ortada.
    public static let unlockWingExtra: CGFloat = 64

    public static let restTopRadius: CGFloat = 6
    public static let restBottomRadius: CGFloat = 12
    /// Açık ada (Revizyon 18, "genişlemiş çentik"): üst kenar ekranın tavanına ve donanım çentiğine kesintisiz
    /// bağlıdır; üst köşelerde çentiğin kendi köşeleri gibi küçük içbükey kulaklar (10), altta sıkı sürekli
    /// eğrilik (28). Büyük, kart gibi yuvarlak alt köşe (32) ve cam kenar/gölge açılır pencere hissi veriyordu.
    public static let expandedTopRadius: CGFloat = 10
    public static let expandedBottomRadius: CGFloat = 28

    /// Yükseltilmiş yüzeyin gölgesinin kırpılmaması için gereken pay.
    public static let shadowBleed = EdgeBleed(horizontal: 28, bottom: 40)
    /// ζ≈0,78 yayının ~%2 aşımı + güvenlik payı.
    public static let overshootBleed = EdgeBleed(horizontal: 14, bottom: 14)

    // MARK: Görünüm başına içerik ölçüleri (paneller de aynı değerleri kullanır)

    /// İki sütun arası boşluk (ayırıcının iki yanı).
    public static let columnGap: CGFloat = 12

    public enum Notes {
        public static let noteMinimumWidth: CGFloat = 180
        /// ~4 satırlık not alanı.
        public static let editorHeight: CGFloat = 64
        public static let labelHeight: CGFloat = 17 // 13 pt etiket + 4 boşluk
        public static let launcherColumns = 3
        public static let launcherCell: CGFloat = 32
        public static let launcherSpacing: CGFloat = 8
        public static let launcherMaxRows = 2
        public static let launcherHeader: CGFloat = 19 // 13 pt başlık + 6 boşluk
        public static var launcherWidth: CGFloat {
            CGFloat(launcherColumns) * launcherCell + CGFloat(launcherColumns - 1) * launcherSpacing
        }
        public static let columnSpacing: CGFloat = 16
    }

    public enum Clipboard {
        /// 6 + 15 + 6 pt satır.
        public static let rowHeight: CGFloat = 25
        public static let rowSpacing: CGFloat = 4
        /// En fazla bu kadar satır görünür; fazlası listede kayar.
        public static let visibleRows = 3
        /// 6 pt boşluk + 14 pt alt bilgi satırı.
        public static let footerHeight: CGFloat = 20
        public static let historyWidth: CGFloat = 190
        /// Damlalık düğmesi + tek sıra renk (5 × 20 + 4 × 6; fazlası yatay kayar).
        public static let colorColumnWidth: CGFloat = 124
        public static let colorColumnHeight: CGFloat = 55
        /// Boş/engelli durum: simge + başlık + iki satır açıklama.
        public static let placeholderHeight: CGFloat = 84
    }

    public enum Shelf {
        public static let tileSize = CGSize(width: 80, height: 81)
        public static let tileSpacing: CGFloat = 4
        public static let actionBarHeight: CGFloat = 18
        public static let actionBarSpacing: CGFloat = 8
        /// Seçim özeti + "Tümünü seç" + 4 eylem düğmesi + İşlemler menüsü (22 + 12 pt).
        public static let actionBarMinimumWidth: CGFloat = 287
        public static let emptyHeight: CGFloat = 98
        public static let emptyTextWidth: CGFloat = 300
        /// Bundan fazla öğe yatay kayar (~6 öğe). Revizyon 18: yan boşluklarla birlikte 8 pt indi (kayan alan aynı).
        public static let maximumBodyWidth: CGFloat = 552
    }

    public enum Focus {
        public static let timerWidth: CGFloat = 158
        public static let ringSize: CGFloat = 88
        public static let durationWidth: CGFloat = 158
        public static let durationRowHeight: CGFloat = 24
        public static let durationRowSpacing: CGFloat = 8
    }

    public enum System {
        public static let columnWidths: [CGFloat] = [140, 190, 160]
        public static let columnHeight: CGFloat = 104
        public static let storageHeight: CGFloat = 42
        public static let sectionGap: CGFloat = 10
        public static let contentHeight = columnHeight + 2 * sectionGap + 0.5 + storageHeight
    }

    public enum Mirror {
        public static let previewSize: CGFloat = 140
        public static let captionWidth: CGFloat = 180
        public static let spacing: CGFloat = 20
    }

    /// Medya ve Nook'ta kapak yuvası kare ve içerik yüksekliğine eşittir. Medya: başlık (34) + süre satırı (14)
    /// + kontroller (31,5) + iki 4 pt boşluk = 87,5. Nook'ta takvim: ay + gün şeridi (35) + 6 + etkinlikler (46).
    public static let mediaContentHeight: CGFloat = 88
    public static let nookContentHeight: CGFloat = 88

    /// Sekmenin içerik alanı (yan ve alt boşluklar, başlık hariç), gösterdiği içeriğe göre.
    public static func contentSize(for tab: ExpandedTab, metrics: NotchMetrics) -> CGSize {
        let content = metrics.content
        switch tab {
        case .nook:
            let widgets = nookWidgetWidths.prefix(max(metrics.nookWidgetCount, 0))
            let width = nookContentHeight + 12 + nookMediaTextWidth + widgets.reduce(0) { $0 + columnDividerSpan + $1 }
            return CGSize(width: width, height: nookContentHeight)

        case .media:
            return CGSize(width: mediaContentHeight + mediaArtworkGap + mediaColumnWidth, height: mediaContentHeight)

        case .notes:
            let rows = min(max(Int((Double(content.launcherItems) / Double(Notes.launcherColumns)).rounded(.up)), 1), Notes.launcherMaxRows)
            let launcher = Notes.launcherHeader + CGFloat(rows) * Notes.launcherCell + CGFloat(rows - 1) * Notes.launcherSpacing
            let note = Notes.labelHeight + Notes.editorHeight
            return CGSize(width: Notes.noteMinimumWidth + Notes.columnSpacing + Notes.launcherWidth, height: max(note, launcher))

        case .clipboard:
            let width = Clipboard.historyWidth + columnDividerSpan + Clipboard.colorColumnWidth
            guard content.clipboardItems > 0 else { return CGSize(width: width, height: Clipboard.placeholderHeight) }
            let rows = min(content.clipboardItems, Clipboard.visibleRows)
            let list = CGFloat(rows) * Clipboard.rowHeight + CGFloat(rows - 1) * Clipboard.rowSpacing + Clipboard.footerHeight
            return CGSize(width: width, height: max(list, Clipboard.colorColumnHeight))

        case .shelf:
            guard content.shelfItems > 0 else { return CGSize(width: Shelf.emptyTextWidth, height: Shelf.emptyHeight) }
            let tiles = CGFloat(content.shelfItems) * Shelf.tileSize.width + CGFloat(content.shelfItems - 1) * Shelf.tileSpacing
            return CGSize(width: max(tiles, Shelf.actionBarMinimumWidth),
                          height: Shelf.tileSize.height + Shelf.actionBarSpacing + Shelf.actionBarHeight)

        case .focus:
            let durationHeight = 3 * Focus.durationRowHeight + 2 * Focus.durationRowSpacing
            return CGSize(width: Focus.timerWidth + columnDividerSpan + Focus.durationWidth,
                          height: max(Focus.ringSize, durationHeight))

        case .mirror:
            return CGSize(width: Mirror.previewSize + Mirror.spacing + Mirror.captionWidth, height: Mirror.previewSize)

        case .mixer:
            return CGSize(width: 400, height: 310)

        case .system:
            let dividers = CGFloat(System.columnWidths.count - 1) * columnDividerSpan
            return CGSize(width: System.columnWidths.reduce(0, +) + dividers, height: System.contentHeight)
        }
    }

    /// Tüm sekmelerin sığdığı başlık genişliği: çentik + iki yanda 4'er öğe (185 pt çentikte 369). Gövde bundan dar
    /// olmaz; tüm sekmeler her görünümde aynı yerde durur (geçişte hiçbir sekme kaymaz).
    public static func minimumExpandedWidth(for metrics: NotchMetrics) -> CGFloat {
        let tabs = CGFloat(tabsPerSide) * tabButtonSize.width + CGFloat(tabsPerSide - 1) * tabSpacing
        let center = metrics.style == .notch ? metrics.notchSize.width : 12
        return center + 2 * (headerSidePadding(style: metrics.style, size: metrics.expandedSurfaceSize) + tabs)
    }

    /// Başlık satırının gövde kenarından boşluğu: notch'ta içbükey kulağın (10) hemen içi.
    public static func headerSidePadding(style: IslandStyle, size: ExpandedSurfaceSize = .standard) -> CGFloat {
        style == .notch ? (size == .compact ? 8 : expandedTopRadius + 2) : 8
    }

    /// Genişletilmiş gövdenin yan boşluğu (notch'ta içbükey kulak + içerik boşluğu).
    public static func expandedSideInset(style: IslandStyle, size: ExpandedSurfaceSize = .standard) -> CGFloat {
        if style == .notch, size == .compact { return 8 + 8 }
        return (style == .notch ? expandedTopRadius : 0) + contentInset
    }

    public static func expandedBottomInset(for metrics: NotchMetrics) -> CGFloat {
        metrics.style == .notch && metrics.expandedSurfaceSize == .compact ? 6 : contentInset
    }

    private static func expandedShoulder(for metrics: NotchMetrics) -> CGFloat {
        metrics.style == .notch && metrics.expandedSurfaceSize == .compact ? 8 : expandedTopRadius
    }

    private static func expandedCorner(for metrics: NotchMetrics) -> CGFloat {
        metrics.style == .notch && metrics.expandedSurfaceSize == .compact ? 24 : expandedBottomRadius
    }

    /// Görünür siyah gövdenin boyutu: içerik + boşluklar; genişlik başlık minimumu ile görünümün üst sınırı arasında.
    public static func expandedSize(for tab: ExpandedTab, metrics: NotchMetrics) -> CGSize {
        let content = contentSize(for: tab, metrics: metrics)
        let side = expandedSideInset(style: metrics.style, size: metrics.expandedSurfaceSize)
        // Üst sınır da dış boşluk farkı kadar küçülür: kayan içerik alanı bile aynı genişlikte kalır.
        let maximum = (tab == .shelf ? Shelf.maximumBodyWidth : maxExpandedWidth)
            + 2 * (side - expandedSideInset(style: metrics.style))
        let width = min(max(content.width + 2 * side, minimumExpandedWidth(for: metrics)), maximum)
        let height = metrics.notchSize.height + headerGap + content.height + expandedBottomInset(for: metrics) + metrics.contentHeightOffset
        return CGSize(width: width, height: height)
    }

    public static func wingWidth(for metrics: NotchMetrics) -> CGFloat {
        metrics.notchSize.height + 14
    }

    /// Genişliği, ekran ölçeğinde **çift piksel** sayısına yuvarlar. Ada piksel hizalı merkeze göre
    /// kurulduğu için kenarlar `merkez ± genişlik/2` olur; genişlik çift piksel olduğunda iki kenar da
    /// tam piksele düşer ve genişleme sol ve sağa birebir aynı piksel sayısıyla dağılır.
    /// 2× ekranda her tam nokta çift pikseldir: 185 pt'lik bir çentik **185 pt olarak kalır**
    /// (kenarlar 762,5 / 947,5 pt = 1525 / 1895 px). 1× ekranda çift noktaya iner.
    /// Aşağı yuvarlanır: dinlenmedeki şekil donanım çentiğini hiçbir zaman taşmaz.
    public static func symmetricWidth(_ width: CGFloat, scale: CGFloat) -> CGFloat {
        let pixels = (width * scale / 2).rounded(.down) * 2
        return pixels / scale
    }

    /// Yüksekliği tam piksele hizalar (alt kenar bulanık çizilmesin). Üst kenar ekranın tavanıdır.
    public static func pixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    // MARK: Yerleşim

    public static func layout(for presentation: IslandPresentation, metrics: NotchMetrics) -> IslandLayout {
        var layout = unsnappedLayout(for: presentation, metrics: metrics)
        layout.size.width = symmetricWidth(layout.size.width, scale: metrics.scale)
        layout.size.height = pixelAligned(layout.size.height, scale: metrics.scale)
        layout.topInset = pixelAligned(layout.topInset, scale: metrics.scale)
        if layout.size.height == metrics.compactHeight { layout.size.height -= metrics.restHeightTrim }
        return layout
    }

    private static func unsnappedLayout(for presentation: IslandPresentation, metrics: NotchMetrics) -> IslandLayout {
        let notch = metrics.notchSize
        let wing = wingWidth(for: metrics)
        let isPill = metrics.style == .pill
        let restHeight = metrics.compactHeight
        let restSize = CGSize(width: notch.width + wing * 2, height: restHeight)
        let pillIdle = CGSize(width: 110, height: 22)

        // Açık yüzeyler: pill'de yüzen kapsül olarak yükseltilir; notch'ta çentiğin gölgesiz, kenar ışıksız devamıdır.
        let openElevation: Double = isPill ? 1 : 0

        func make(_ size: CGSize, top: CGFloat, bottom: CGFloat, elevation: Double) -> IslandLayout {
            if isPill {
                // Donanım yok: kapsül yüzer; her zaman ince kenar ışığı ve hafif gölgeyle ayrışır.
                let radius = min(size.height / 2, max(bottom, 14))
                return IslandLayout(size: size, topCornerRadius: radius, bottomCornerRadius: radius,
                                    elevation: max(elevation, 0.35), edgeHighlight: max(0.6, elevation),
                                    topInset: metrics.floatOffset)
            }
            return IslandLayout(size: size, topCornerRadius: top, bottomCornerRadius: bottom,
                                elevation: elevation, edgeHighlight: elevation, topInset: 0)
        }

        switch presentation {
        case .idle:
            // Notch: donanım bandının içinde; görünmez ama girdi sensörü burada yaşar.
            return isPill ? make(pillIdle, top: 11, bottom: 11, elevation: 0)
                          : make(CGSize(width: notch.width, height: restHeight), top: restTopRadius, bottom: 10, elevation: 0)

        case .compact:
            return make(restSize, top: restTopRadius, bottom: restBottomRadius, elevation: 0)

        case .peek(let activity):
            let peekTop = restTopRadius + 1
            let base: CGSize
            if activity != nil {
                base = restSize
            } else if isPill {
                base = pillIdle
            } else {
                // Dinlenmede içbükey kulaklar donanım çentiğinin içinde kalır; kabarmada ise gövdenin
                // kendisi çentikten geniş olmalı ki altta beliren dudak çentikle tek parça görünsün.
                base = CGSize(width: notch.width + peekTop * 2, height: restHeight)
            }
            let size = CGSize(width: base.width + hoverSwell.width,
                              height: base.height + (isPill ? hoverSwell.height : 0))
            // Notch'ta hover yalnızca yatay genişler; donanımın altında ayrı bir dudak oluşmaz.
            return make(size, top: peekTop, bottom: restBottomRadius + 2, elevation: 0)

        case .hud:
            return make(CGSize(width: notch.width + (wing + hudWingExtra) * 2, height: restHeight),
                        top: restTopRadius, bottom: restBottomRadius, elevation: 0)

        case .notice(let notice):
            // Notch'ta bildirim dinlenmeye yakın bir durumdur: gölge/kenar ışığı yok (fiziksel çentik
            // etrafında hale oluşmasın). Pill'de `make` zaten hafif ayrışma verir.
            if case .audioOutput = notice {
                return make(CGSize(width: notch.width + max(wing + noticeWingExtra, 120) * 2, height: restHeight),
                            top: restTopRadius, bottom: restBottomRadius, elevation: 0)
            }
            if notice == .unlocked {
                // Kilit açılma: çentik yalnızca yatay genişler, dikey büyümez. Fiziksel donanımın
                // doğal uzantısı gibi görünmesi için yükseklik çentik bandında kalır.
                return make(CGSize(width: notch.width + (wing + unlockWingExtra) * 2, height: restHeight),
                            top: restTopRadius, bottom: restBottomRadius, elevation: 0)
            }
            return make(CGSize(width: notch.width + (wing + noticeWingExtra) * 2, height: notch.height + noticeCaptionHeight),
                        top: restTopRadius + 2, bottom: 20, elevation: 0)

        case .dropTarget:
            // Açık adayla aynı kulak ve köşeler; karo alanı Revizyon 17'dekiyle aynı (yalnızca kenar boşlukları küçüldü).
            return make(CGSize(width: max(notch.width + 246, 456), height: notch.height + 108),
                        top: expandedTopRadius, bottom: expandedBottomRadius, elevation: openElevation)

        case .expanded(let tab):
            return make(expandedSize(for: tab, metrics: metrics),
                        top: expandedShoulder(for: metrics), bottom: expandedCorner(for: metrics), elevation: openElevation)
        }
    }

    /// Görsel pencerenin sabit boyutu: her görünümü, gölgesini ve yay aşımını kırpmadan taşır.
    /// Pencere animasyon sırasında **hiç** yeniden boyutlanmaz; tüm morph Core Animation'dadır.
    public static func canvasSize(for metrics: NotchMetrics) -> CGSize {
        // Tuval içerik miktarından ve Nook düzeninden bağımsızdır: her görünümün en büyük hali sığar,
        // içerik değişince görsel panel yeniden boyutlanmaz (yalnızca görünür gövde morph eder).
        var metrics = metrics
        // Boyut ayarı yalnız görünür yüzeyi değiştirir; panelin sabit tuvali yeniden boyutlanmaz.
        metrics.expandedSurfaceSize = .standard
        metrics.content = .maximum
        metrics.nookWidgetCount = nookWidgetWidths.count
        var presentations: [IslandPresentation] = [.idle, .dropTarget, .peek(.media),
                                                   .hud(HUDPayload(kind: .brightness, level: 1)),
                                                   .notice(.timerFinished(title: "")),
                                                   .notice(.unlocked),
                                                   .notice(.audioOutput(name: "", kind: .headphones, connected: true))]
        presentations += ExpandedTab.allCases.map(IslandPresentation.expanded)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for presentation in presentations {
            let layout = layout(for: presentation, metrics: metrics)
            width = max(width, layout.size.width)
            height = max(height, layout.topInset + layout.size.height)
        }
        let horizontal = shadowBleed.horizontal + overshootBleed.horizontal
        // Tuval her ölçekte çift tam nokta: merkezi, piksel hizalı çapaya birebir oturur.
        return CGSize(
            width: symmetricWidth(width + horizontal * 2 + 2, scale: 1),
            height: (height + shadowBleed.bottom + overshootBleed.bottom).rounded(.up)
        )
    }

    /// Gövde kenarının şeklin sol kenarından içeride başladığı mesafe (notch "kulakları").
    public static func bodyInset(for layout: IslandLayout, style: IslandStyle) -> CGFloat {
        style == .notch ? layout.topCornerRadius : 0
    }

    /// Genişletilmiş içerik için yatay kenar boşluğu.
    public static func contentSideInset(for layout: IslandLayout, style: IslandStyle,
                                        size: ExpandedSurfaceSize = .standard) -> CGFloat {
        bodyInset(for: layout, style: style) + (style == .notch && size == .compact ? 8 : contentInset)
    }

    /// Eş-merkezli köşe: iç öğe dış köşeden `inset` kadar içerideyse yarıçapı `outer − inset` olmalı.
    public static func concentricRadius(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(outer - inset, 3)
    }

    // MARK: Kalıcı katman yuvaları

    /// Albüm kapağının yeri. Kapak, kompakt kanattan genişletilmiş panele aynı yay ile "akan"
    /// tek bir kalıcı katmandır; yarıçapı her durumda yüzeyle eş-merkezlidir.
    public static func artworkSlot(for presentation: IslandPresentation, metrics: NotchMetrics) -> SlotFrame? {
        let layout = layout(for: presentation, metrics: metrics)
        switch presentation {
        case .compact(.media), .peek(.media), .notice(.nowPlaying):
            // Kapak, hover dahil o anki kanat yüksekliğine göre dikey ortalanır.
            let isNotice = if case .notice = presentation { true } else { false }
            let height = isNotice ? metrics.notchSize.height : layout.size.height
            let emphasized = presentation != .compact(.media)
            let size = (metrics.notchSize.height * 0.6).rounded() + (emphasized ? 2 : 0)
            let inset = (height - size) / 2
            let outer = metrics.style == .pill ? height / 2 : (isNotice ? restBottomRadius : layout.bottomCornerRadius)
            return SlotFrame(
                rect: CGRect(x: bodyInset(for: layout, style: metrics.style) + inset, y: inset, width: size, height: size),
                cornerRadius: concentricRadius(outer: outer, inset: inset)
            )
        case .expanded(.media), .expanded(.nook):
            // Nook'ta medya widget'ı en solda sabittir; kapak aynı eş-merkezli yuvaya akar.
            let top = metrics.notchSize.height + headerGap
            let bottom = expandedBottomInset(for: metrics)
            let size = layout.size.height - top - bottom
            return SlotFrame(
                rect: CGRect(x: contentSideInset(for: layout, style: metrics.style, size: metrics.expandedSurfaceSize), y: top, width: size, height: size),
                cornerRadius: concentricRadius(outer: layout.bottomCornerRadius, inset: bottom)
            )
        default:
            return nil
        }
    }

    /// Müzik nabzının yeri (kompaktta sağ kanat, genişletilmişte başlık satırının sağı).
    public static func waveformSlot(for presentation: IslandPresentation, metrics: NotchMetrics) -> CGRect? {
        let layout = layout(for: presentation, metrics: metrics)
        switch presentation {
        case .compact(.media), .peek(.media), .notice(.nowPlaying):
            let restHeight = metrics.notchSize.height
            let isNotice = if case .notice = presentation { true } else { false }
            let height = isNotice ? restHeight : layout.size.height
            let size = CGSize(width: (restHeight * 0.7).rounded(), height: (restHeight * 0.36).rounded())
            let artworkInset = (height - (restHeight * 0.6).rounded()) / 2
            let x = layout.size.width - bodyInset(for: layout, style: metrics.style) - artworkInset - size.width
            return CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
        case .expanded(.media):
            let size = CGSize(width: 34, height: 18)
            let x = layout.size.width - contentSideInset(for: layout, style: metrics.style, size: metrics.expandedSurfaceSize) - size.width
            return CGRect(x: x, y: metrics.notchSize.height + headerGap + 2, width: size.width, height: size.height)
        default:
            return nil
        }
    }
}
