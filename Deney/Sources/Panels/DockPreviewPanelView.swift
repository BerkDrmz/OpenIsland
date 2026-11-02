import AppKit
import IslandCore

/// Dock önizleme paneli (SwiftUI `DockPreviewPanel` karşılığı): uygulama başlığı, yatay kaydırılan pencere kartları,
/// gerekirse ekran erişimi satırı. Panel sistem görünüşünü izler (ada gibi koyu zorlanmaz). Model gözlenir; kartlar
/// yalnız kendi verileri değişince güncellenir, görüntü yalnız görünür kart için istenir (`LazyHStack` + `onAppear`).
@MainActor
final class DockPreviewPanelView: FlippedView {
    private let model: DockPreviewModel
    private let background = DockPreviewBackgroundView()
    private let icon = DockPreviewIconView()
    private let name = TextLabel("", font: NSFont.systemFont(ofSize: 12, weight: .medium), color: .labelColor)
    private let count = TextLabel("", font: NSFont.systemFont(ofSize: 10), color: .secondaryLabelColor)
    private let scroll = NSScrollView()
    private let row = DockPreviewRowView()
    private var cards: [UUID: DockPreviewCardView] = [:]
    private let permissionText = TextLabel("Önizleme için ekran erişimi gerekiyor.", font: NSFont.systemFont(ofSize: 10),
                                           color: .secondaryLabelColor)
    private let permissionButton = DockPreviewAlignedButton(title: "İzin ver", target: nil, action: nil)
    private var generation = 0

    init(model: DockPreviewModel, size: CGSize) {
        self.model = model
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        // SwiftUI kökü (barındırma görünümü) bir AX grubudur; öğeler onun altında.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        icon.imageScaling = .scaleProportionallyUpOrDown
        permissionText.maximumLines = 0
        permissionButton.controlSize = .small
        permissionButton.bezelStyle = .push
        permissionButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.documentView = row
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        [background, icon, name, count, scroll, permissionText, permissionButton].forEach(addSubview)
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    private func observe() {
        generation += 1
        let token = generation
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    self.observe()
                }
            }
        }
    }

    private func update() {
        icon.image = model.applicationIcon
        icon.isHidden = model.applicationIcon == nil
        name.set(model.applicationName)
        count.set("\(model.windows.count) pencere")
        permissionText.isHidden = !model.needsScreenAccess
        permissionButton.isHidden = !model.needsScreenAccess
        let ids = Set(model.windows.map(\.id))
        for (id, card) in cards where !ids.contains(id) { card.removeFromSuperview(); cards[id] = nil }
        for window in model.windows {
            let card = cards[window.id] ?? {
                let card = DockPreviewCardView(window: window) { [weak self] in self?.model.selectWindow?(window.id) }
                cards[window.id] = card
                row.addSubview(card)
                return card
            }()
            card.update(image: model.images[window.id],
                        unavailable: model.needsScreenAccess || model.unavailable.contains(window.id))
        }
        needsLayout = true
    }

    @objc private func requestPermission() { model.requestPermission?() }
    @objc private func scrolled() { requestVisibleImages() }

    override func layout() {
        super.layout()
        background.frame = bounds
        let padding: CGFloat = 10
        let width = bounds.width - 2 * padding
        // Başlık satırı (HStack spacing 6): simge 16 × 16, ad (sığmazsa kesilir), en az 4 pt boşluk, pencere sayısı.
        let rowHeight: CGFloat = 16
        var x = padding
        if !icon.isHidden {
            icon.frame = CGRect(x: x, y: padding, width: 16, height: 16)
            x += 16 + 6
        }
        let countWidth = pixelCeil(count.exactWidth)
        count.frame = CGRect(x: padding + width - countWidth, y: padding + (rowHeight - count.lineHeight) / 2,
                             width: countWidth, height: count.lineHeight)
        let nameWidth = min(pixelCeil(name.exactWidth), count.frame.minX - 4 - x)
        name.frame = CGRect(x: x, y: padding + (rowHeight - name.lineHeight) / 2, width: max(nameWidth, 0), height: name.lineHeight)
        // Kart satırı (ScrollView yüksekliği `cardRowHeight`, LazyHStack spacing 8, altta 2 pt).
        let scrollY = padding + rowHeight + 8
        scroll.frame = CGRect(x: padding, y: scrollY, width: width, height: DockPreviewRules.cardRowHeight)
        let cardHeight = DockPreviewRules.cardImageHeight + 6 + 16
        // ScrollView içeriği (kartlar + altta 2 pt) kaydırma alanında dikeyde ortalanır (SwiftUI: 122 pt'de 120 pt → 1 pt).
        let cardY = (DockPreviewRules.cardRowHeight - (cardHeight + 2)) / 2
        var cx: CGFloat = 0
        for window in model.windows {
            guard let card = cards[window.id] else { continue }
            card.frame = CGRect(x: cx, y: cardY, width: DockPreviewRules.cardWidth, height: cardHeight)
            cx += DockPreviewRules.cardWidth + 8
        }
        row.frame = CGRect(x: 0, y: 0, width: max(cx - 8, width), height: DockPreviewRules.cardRowHeight)
        // İzin satırı (HStack spacing 8): sarılan açıklama + küçük düğme.
        if model.needsScreenAccess {
            // Düğme SwiftUI'deki gibi hizalama dikdörtgeniyle yerleşir (küçük düğme: 16 pt yükseklik).
            permissionButton.sizeToFit()
            let insets = permissionButton.alignmentRectInsets
            // Genişlik: SwiftUI küçük düğmesi yazının iki yanında 6 pt bırakır (NSButton'ın kendi ölçüsü 8 pt); ölçüldü.
            let titleWidth = (permissionButton.title as NSString).size(withAttributes: [.font: permissionButton.font ?? .systemFont(ofSize: 11)]).width
            let buttonSize = CGSize(width: pixelCeil(titleWidth) + 12,
                                    height: permissionButton.frame.height - insets.top - insets.bottom)
            let textWidth = min(pixelCeil(permissionText.exactWidth), width - 8 - buttonSize.width)
            let textHeight = permissionText.height(forWidth: textWidth)
            let y = scrollY + DockPreviewRules.cardRowHeight + 8
            let lineHeight = max(textHeight, buttonSize.height)
            permissionText.frame = CGRect(x: padding, y: y + (lineHeight - textHeight) / 2, width: textWidth, height: textHeight)
            permissionButton.setAlignmentFrame(CGRect(x: padding + width - buttonSize.width, y: y + (lineHeight - buttonSize.height) / 2,
                                                      width: buttonSize.width, height: buttonSize.height))
        }
        requestVisibleImages()
    }

    private func requestVisibleImages() {
        let visible = scroll.contentView.bounds
        for window in model.windows {
            guard let card = cards[window.id], card.frame.intersects(visible), !card.didRequestImage else { continue }
            card.didRequestImage = true
            model.requestImage?(window.id)
        }
    }
}

/// Küçük düğme: hizalama dikdörtgeniyle yerleşir, AX çerçevesi hizalama dikdörtgenidir (SwiftUI `Button` gibi).
private final class DockPreviewAlignedButton: NSButton, AlignedControl {
    override func accessibilityFrame() -> NSRect { alignmentScreenFrame() ?? super.accessibilityFrame() }
}

/// Kartların kaydırılan belgesi: SwiftUI `LazyHStack` gibi AX'te kartları kapsayan opak sağlayıcı grup.
private final class DockPreviewRowView: LazyStackView {}

/// Uygulama simgesi: AX çerçevesi görünüm çerçevesi (SwiftUI `Image` 16 × 16; `NSImageView` 1 pt pay ekliyordu).
private final class DockPreviewIconView: NSImageView {
    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}

/// Panel zemini: 12 pt sürekli köşeli pencere arka plan rengi + içten 1 pt %10 birincil renk çerçeve.
private final class DockPreviewBackgroundView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    nonisolated override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = primaryColor(opacity: 0.10)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Pencere kartı: 164 × 96 önizleme alanı (8 pt köşe, %5 birincil zemin) + 16 pt başlık satırı; hover'da 9 pt köşeli
/// %22 birincil çerçeve. Düz düğme: tıklayınca pencereye geçer.
@MainActor
private final class DockPreviewCardView: PlainButton {
    var didRequestImage = false
    private let previewWindow: DockPreviewWindow
    private let imageArea = DockPreviewImageAreaView()
    private let thumbnail = NSImageView()
    private let placeholderSymbol: SymbolView
    private let placeholderText: TextLabel
    private let preparing = TextLabel("Önizleme hazırlanıyor…", font: NSFont.systemFont(ofSize: 10), color: .secondaryLabelColor)
    private let minimizedSymbol: SymbolView?
    private let title: TextLabel
    private let hoverBorder = DockPreviewHoverBorderView()
    private var hoverArea: NSTrackingArea?
    private var image: NSImage?
    private var unavailable = false

    init(window: DockPreviewWindow, action: @escaping () -> Void) {
        previewWindow = window
        placeholderSymbol = SymbolView(window.minimized ? "minus.rectangle" : "macwindow", size: 18, color: .secondaryLabelColor)
        placeholderText = TextLabel(window.minimized ? "Simge durumunda" : "Görüntü alınamıyor", font: NSFont.systemFont(ofSize: 10),
                                    color: .secondaryLabelColor)
        minimizedSymbol = window.minimized ? SymbolView("minus.square", size: 9, color: .secondaryLabelColor) : nil
        title = TextLabel(window.title, font: NSFont.systemFont(ofSize: 11), color: .labelColor, truncation: .byTruncatingMiddle)
        super.init(action: action)
        wantsLayer = true
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.setAccessibilityElement(false)
        [placeholderText, preparing, title].forEach { $0.setAccessibilityElement(false) }
        imageArea.addSubview(thumbnail)
        imageArea.addSubview(placeholderSymbol)
        imageArea.addSubview(placeholderText)
        imageArea.addSubview(preparing)
        addSubview(imageArea)
        if let minimizedSymbol { addSubview(minimizedSymbol) }
        addSubview(title)
        addSubview(hoverBorder)
        hoverBorder.isHidden = true
        setAccessibilityLabel("\(window.title)\(window.minimized ? ", simge durumunda" : "")")
        setAccessibilityHelp("Bu pencereye geç")
        toolTip = "Bu pencereye geç"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    private var isConfigured = false

    func update(image: NSImage?, unavailable: Bool) {
        guard !isConfigured || image !== self.image || unavailable != self.unavailable else { return }
        isConfigured = true
        self.image = image
        self.unavailable = unavailable
        thumbnail.image = image
        thumbnail.isHidden = image == nil
        placeholderSymbol.isHidden = image != nil || !unavailable
        placeholderText.isHidden = image != nil || !unavailable
        preparing.isHidden = image != nil || unavailable
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = DockPreviewRules.cardWidth, h = DockPreviewRules.cardImageHeight
        imageArea.frame = CGRect(x: 0, y: 0, width: w, height: h)
        if let image, image.size.width > 0, image.size.height > 0 {
            // resizable().scaledToFit().padding(2): 2 pt içeride, oran korunarak ortalı.
            let box = CGSize(width: w - 4, height: h - 4)
            let s = min(box.width / image.size.width, box.height / image.size.height)
            let size = CGSize(width: image.size.width * s, height: image.size.height * s)
            thumbnail.frame = CGRect(x: (w - size.width) / 2, y: (h - size.height) / 2, width: size.width, height: size.height)
        }
        // Yer tutucu (VStack spacing 6, ortalı): sembol + metin.
        let symbolSize = placeholderSymbol.layoutSize
        let textWidth = pixelCeil(placeholderText.exactWidth)
        let stackHeight = symbolSize.height + 6 + placeholderText.lineHeight
        let top = (h - stackHeight) / 2
        placeholderSymbol.frame = placeholderSymbol.drawingFrame(layoutOrigin: CGPoint(x: (w - symbolSize.width) / 2, y: top))
        placeholderText.frame = pixelRect(CGRect(x: (w - textWidth) / 2, y: top + symbolSize.height + 6, width: textWidth,
                                                 height: placeholderText.lineHeight))
        let preparingWidth = pixelCeil(preparing.exactWidth)
        preparing.frame = pixelRect(CGRect(x: (w - preparingWidth) / 2, y: (h - preparing.lineHeight) / 2, width: preparingWidth,
                                           height: preparing.lineHeight))
        // Başlık satırı (HStack spacing 4, 16 pt yükseklik): simge durumu sembolü + ortadan kesilen başlık.
        let rowY = h + 6
        var x: CGFloat = 0
        if let minimizedSymbol {
            let s = minimizedSymbol.layoutSize
            minimizedSymbol.frame = minimizedSymbol.drawingFrame(layoutOrigin: CGPoint(x: 0, y: rowY + (16 - s.height) / 2))
            x = s.width + 4
        }
        let titleWidth = min(pixelCeil(title.exactWidth), w - x)
        title.frame = CGRect(x: x, y: rowY + (16 - title.lineHeight) / 2, width: titleWidth, height: title.lineHeight)
        hoverBorder.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    /// SwiftUI düğmesinin AX çocuğu yoktur (etiket düğmede).
    override func accessibilityChildren() -> [Any]? { [] }

    override func mouseEntered(with event: NSEvent) { hoverBorder.isHidden = false }
    override func mouseExited(with event: NSEvent) { hoverBorder.isHidden = true }
}

/// Önizleme alanı zemini: 8 pt sürekli köşe, %5 birincil renk, içeriği kırpar.
private final class DockPreviewImageAreaView: FlippedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    nonisolated override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = primaryColor(opacity: 0.05)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Hover çerçevesi: 9 pt sürekli köşe, içten 1 pt %22 birincil renk.
private final class DockPreviewHoverBorderView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    nonisolated override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = primaryColor(opacity: 0.22)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// SwiftUI `.primary.opacity(x)`: birincil renk (`labelColor`) kendi opaklığıyla çarpılır (koyu görünüşte 0,85 × x);
/// `withAlphaComponent(x)` opaklığı değiştirip daha açık bir ton veriyordu. Görünüş içinde çağrılmalı.
private func primaryColor(opacity: CGFloat) -> CGColor {
    let color = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
    return color.withAlphaComponent(color.alphaComponent * opacity).cgColor
}
