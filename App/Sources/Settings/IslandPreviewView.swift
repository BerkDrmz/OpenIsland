import AppKit
import IslandCore

/// Ayarlardaki ada önizlemesi (SwiftUI `IslandPreview` karşılığı): gerçek yerleşim motoru ve `IslandShape` yolu,
/// seçili hareket stilinin yaylarıyla kompakt medya ↔ Nook. SwiftUI'de bütün canlanan değerler (boyut, köşe
/// yarıçapları, kapak yuvası) aynı yayla iki uç arasında ilerler; burada tek ilerleme yayı (0 kompakt, 1 açık) ve
/// doğrusal ara değerler (hız korunur, yay fiziği doğrusal). İçerik geçişleri `islandReveal`. Animasyon yalnız
/// etkileşimde; boştayken kare yok.
@MainActor
final class IslandPreviewView: FlippedView {
    static let typicalNotch = CGSize(width: 185, height: 32)
    static let scale: CGFloat = 0.62
    private let preferences: Preferences
    private let notchSize: CGSize

    private let gradient = CAGradientLayer()
    private let band = CALayer()
    private let island = CALayer()          // ölçeklenen ada (kendi koordinatları ölçeksiz)
    private let surface = CAShapeLayer()
    private let clip = CAShapeLayer()
    private let compact = CALayer()
    private var bars: [CALayer] = []
    private let expanded = CALayer()
    private var expandedParts: [CALayer] = []
    private let artwork = CAGradientLayer()

    private var progress = Spring(0)
    private var compactVisibility = Spring(1)
    private var expandedVisibility = Spring(0)
    private var removingCompact = false
    private var removingExpanded = false
    private var isExpanded = false
    private var spec = AppMotion.rest
    private lazy var driver = FrameDriver(view: self) { [weak self] dt in self?.step(dt) ?? false }
    private var demo: DispatchWorkItem?
    private var lastMotion: MotionStyle?
    private var lastSize: ExpandedSurfaceSize?
    private var lastWidgets = -1

    init(preferences: Preferences, notchSize: CGSize) {
        self.preferences = preferences
        self.notchSize = notchSize
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        root.masksToBounds = true // köşeler ayarlar kartıyla kırpılır
        // Uygulama simgesinin gece mavisi zemini (üstte açık, altta koyu).
        gradient.colors = [CGColor(srgbRed: 0.157, green: 0.188, blue: 0.4, alpha: 1), CGColor(srgbRed: 0.071, green: 0.082, blue: 0.18, alpha: 1)]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        band.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06)
        island.anchorPoint = .zero
        surface.fillColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        island.mask = clip
        artwork.colors = [CGColor(srgbRed: 0.95, green: 0.45, blue: 0.3, alpha: 1), CGColor(srgbRed: 0.55, green: 0.2, blue: 0.6, alpha: 1)]
        artwork.startPoint = CGPoint(x: 0, y: 0)
        artwork.endPoint = CGPoint(x: 1, y: 1)
        artwork.cornerCurve = .continuous
        artwork.masksToBounds = true
        for level in [0.5, 0.9, 0.6, 1.0, 0.7] {
            let bar = CALayer()
            bar.backgroundColor = IslandPalette.pulseNSColor.cgColor
            bar.setValue(level, forKey: "level")
            compact.addSublayer(bar)
            bars.append(bar)
        }
        [surface, compact, expanded, artwork].forEach(island.addSublayer)
        [gradient, band, island].forEach(root.addSublayer)
        expanded.opacity = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.unknown)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Oynat") { [weak self] in self?.play(); return true }])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    private var metrics: NotchMetrics {
        NotchMetrics(notchSize: notchSize, style: .notch, nookWidgetCount: preferences.nookLayout.widgetCount,
                     expandedSurfaceSize: preferences.expandedSurfaceSize)
    }

    private var style: MotionStyle { AppMotion.effectiveStyle(preferences.motionStyle) }

    var preferredHeight: CGFloat {
        pixelRound(IslandLayoutEngine.layout(for: .expanded(.nook), metrics: metrics).size.height * Self.scale + 14)
    }

    override func accessibilityLabel() -> String? { "Ada önizlemesi, \(preferences.motionStyle.title) hareket" }

    /// Tercihler okunur (form gözlemi içinde); stil ya da boyut değişince bir kez aç-kapat (SwiftUI `onChange`).
    func refresh() {
        let motion = preferences.motionStyle, size = preferences.expandedSurfaceSize
        let widgets = preferences.nookLayout.widgetCount
        let changed = lastMotion != nil && (motion != lastMotion || size != lastSize)
        let geometry = size != lastSize || widgets != lastWidgets
        lastMotion = motion
        lastSize = size
        lastWidgets = widgets
        if geometry { buildExpanded() }
        if changed { play() }
        needsLayout = true
    }

    // MARK: Etkileşim

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { demo?.cancel(); setExpanded(true) }
    override func mouseExited(with event: NSEvent) { demo?.cancel(); setExpanded(false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { setExpanded(!isExpanded) }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        let from: IslandPresentation = isExpanded ? .expanded(.nook) : .compact(.media)
        let to: IslandPresentation = expanded ? .expanded(.nook) : .compact(.media)
        isExpanded = expanded
        spec = AppMotion.morph(from: from, to: to, style: style)
        progress.animate(to: expanded ? 1 : 0, spec: spec)
        // `islandReveal`: giren içerik saydamlık (+ bulanıklık) ile, çıkan saydamlıkla.
        let contentIn = style == .reduced ? AppMotion.reduced : AppMotion.contentIn(style)
        let contentOut = style == .reduced ? AppMotion.reduced : AppMotion.contentOut(style)
        if expanded {
            expandedVisibility.set(0)
            expandedVisibility.animate(to: 1, spec: contentIn)
            removingExpanded = false
            removingCompact = true
            compactVisibility.animate(to: 0, spec: contentOut)
        } else {
            compactVisibility.set(0)
            compactVisibility.animate(to: 1, spec: contentIn)
            removingCompact = false
            removingExpanded = true
            expandedVisibility.animate(to: 0, spec: contentOut)
        }
        driver.start()
    }

    /// Stil değişince bir kez aç-kapat: fark hemen görülsün.
    private func play() {
        demo?.cancel()
        setExpanded(true)
        let work = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
        demo = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func step(_ dt: Double) -> Bool {
        progress.step(dt)
        compactVisibility.step(dt)
        expandedVisibility.step(dt)
        apply()
        return progress.isActive || compactVisibility.isActive || expandedVisibility.isActive
    }

    // MARK: Çizim

    /// Açık yer tutucu (Nook): sol sütun çubukları ve widget kutuları; yerleşim açık durumunkiyle sabit (SwiftUI'de
    /// yalnız açık durumda var; kaldırılırken son hâliyle söner).
    private func buildExpanded() {
        expandedParts.forEach { $0.removeFromSuperlayer() }
        expandedParts = []
        let m = metrics
        let layout = IslandLayoutEngine.layout(for: .expanded(.nook), metrics: m)
        let top = m.notchSize.height + IslandLayoutEngine.headerGap
        let inset = IslandLayoutEngine.contentSideInset(for: layout, style: m.style, size: m.expandedSurfaceSize)
        let art = IslandLayoutEngine.artworkSlot(for: .expanded(.nook), metrics: m)?.rect.width ?? 0
        let height = layout.size.height - top - IslandLayoutEngine.expandedBottomInset(for: m)
        let width = layout.size.width - inset * 2
        func part(_ rect: CGRect, _ radius: CGFloat, _ alpha: CGFloat, continuous: Bool = false) {
            let l = CALayer()
            l.frame = rect.offsetBy(dx: inset, dy: top)
            l.cornerRadius = radius
            if continuous { l.cornerCurve = .continuous }
            l.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
            expanded.addSublayer(l)
            expandedParts.append(l)
        }
        // HStack(spacing: 10): [sol sütun art + 150 (VStack, öndeki dolgu art + 10)] + eşit genişlikte widget'lar.
        let column = art + 150
        let x0 = art + IslandLayoutEngine.contentInset
        part(CGRect(x: x0, y: 0, width: 90, height: 9), 3, 0.85)
        part(CGRect(x: x0, y: 15, width: 60, height: 7), 3, 0.62)
        part(CGRect(x: x0, y: height - 4, width: column - x0, height: 4), 2, 0.18)
        let count = m.nookWidgetCount
        if count > 0 {
            let spacing = IslandLayoutEngine.contentInset
            let w = (width - column - CGFloat(count) * spacing) / CGFloat(count)
            for i in 0..<count {
                part(CGRect(x: column + spacing + CGFloat(i) * (w + spacing), y: 0, width: w, height: height), 12, 0.07, continuous: true)
            }
        }
    }

    override func layout() {
        super.layout()
        apply()
    }

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let m = metrics
        let p = CGFloat(progress.value)
        let l0 = IslandLayoutEngine.layout(for: .compact(.media), metrics: m)
        let l1 = IslandLayoutEngine.layout(for: .expanded(.nook), metrics: m)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        let size = CGSize(width: mix(l0.size.width, l1.size.width), height: mix(l0.size.height, l1.size.height))
        if FrameDriver.isLogging { FrameDriver.note(String(format: "geo w=%.2f h=%.2f", size.width, size.height)) }
        gradient.frame = bounds
        band.frame = CGRect(x: 0, y: 0, width: bounds.width, height: pixelRound(notchSize.height * Self.scale))
        // ZStack(alignment: .top): ölçeklenmiş ada yatayda ortalı, üstte; kare kare piksele yuvarlanır.
        island.bounds = CGRect(origin: .zero, size: size)
        island.position = CGPoint(x: pixelRound((bounds.width - size.width * Self.scale) / 2), y: 0)
        island.setAffineTransform(CGAffineTransform(scaleX: Self.scale, y: Self.scale))
        let shape = IslandShape(style: .notch, topRadius: mix(l0.topCornerRadius, l1.topCornerRadius),
                                bottomRadius: mix(l0.bottomCornerRadius, l1.bottomCornerRadius))
        let path = shape.path(in: CGRect(origin: .zero, size: size)).cgPath
        surface.path = path
        clip.path = path
        // SwiftUI ölçeklenmiş adadaki yaprak görünümleri pencere pikseline oturtur: köken ve genişlik en yakın piksele,
        // yükseklik aşağı (ölçüldü).
        let origin = island.position
        func snapped(_ r: CGRect) -> CGRect {
            let screen = CGRect(x: pixelRound(origin.x + r.minX * Self.scale), y: pixelRound(origin.y + r.minY * Self.scale),
                                width: pixelRound(r.width * Self.scale), height: (r.height * Self.scale * 2).rounded(.down) / 2)
            return CGRect(x: (screen.minX - origin.x) / Self.scale, y: (screen.minY - origin.y) / Self.scale,
                          width: screen.width / Self.scale, height: screen.height / Self.scale)
        }
        // Kompakt dalga çubukları: HStack(spacing: 2) yuvada ortalı.
        let slot = IslandLayoutEngine.waveformSlot(for: .compact(.media), metrics: m) ?? .zero
        var x = slot.minX + (slot.width - (CGFloat(bars.count) * 3 + CGFloat(bars.count - 1) * 2)) / 2
        for bar in bars {
            let h = slot.height * CGFloat(bar.value(forKey: "level") as? Double ?? 1)
            bar.frame = snapped(CGRect(x: x, y: slot.minY + (slot.height - h) / 2, width: 3, height: h))
            bar.cornerRadius = 1.5
            x += 5
        }
        if let s0 = IslandLayoutEngine.artworkSlot(for: .compact(.media), metrics: m),
           let s1 = IslandLayoutEngine.artworkSlot(for: .expanded(.nook), metrics: m) {
            artwork.frame = snapped(CGRect(x: mix(s0.rect.minX, s1.rect.minX), y: mix(s0.rect.minY, s1.rect.minY),
                                           width: mix(s0.rect.width, s1.rect.width), height: mix(s0.rect.height, s1.rect.height)))
            artwork.cornerRadius = mix(s0.cornerRadius, s1.cornerRadius)
        }
        reveal(compact, value: compactVisibility.value, removing: removingCompact)
        reveal(expanded, value: expandedVisibility.value, removing: removingExpanded)
    }

    /// `islandReveal` (genişletilmemiş içerik): giriş saydamlık + (Azaltılmış dışında) (1 − p) × 6 bulanıklık, çıkış
    /// yalnız saydamlık.
    private func reveal(_ layer: CALayer, value: Double, removing: Bool) {
        let p = max(0, min(1, value))
        layer.opacity = Float(p)
        RevealBlur.apply(radius: removing || style == .reduced ? 0 : (1 - p) * 6, to: layer)
        layer.isHidden = p <= 0.001
    }
}
