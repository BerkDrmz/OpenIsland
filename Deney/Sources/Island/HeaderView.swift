import AppKit
import IslandCore

/// Genişletilmiş adanın başlık satırı: solda Medya, Nook, Raf, Pano, Mikser; sağda Odak, Notlar, Ayna, Sistem ve iğne.
/// Kapalı modüllerin sekmesi gösterilmez. Dar gövdelerde satır `headerRowShift` kadar kayar: düğmelerin yerleşimi
/// (odak, erişilebilirlik, isabet) tek adımda geçer, görünen etiketler aynı yayla kayar (K8 ile aynı davranış).
@MainActor
final class HeaderView: FlippedView {
    private let model: IslandViewModel
    private let environment: AppEnvironment
    private var buttons: [ExpandedTab: TabButtonView] = [:]
    private let pin: IconButtonView
    /// Seçim kapsülü başlığın kendi katmanında, düğme katmanlarının altında düz bir katmandır (`RoundedView` ile aynı
    /// özellikler: sürekli köşe eğrisi, görünüşe göre çözülen dolgu). Kayma ve yeniden boyutlama yayı her karede yalnız
    /// katman çerçevesini yazar; kapsül görünümü taşınırken her kare görünüm geometrisi ve pencerenin izleme alanı
    /// hesabı yenileniyordu.
    private let capsule = CALayer()
    private var visibleTabs: [ExpandedTab] = []
    private var selectedTab: ExpandedTab?
    /// Görünen kayma (etiketler); yerleşim hedefe tek adımda geçer.
    private var shift = Spring(0)
    private var capsuleX = Spring(0)
    private var lastLayoutTab: ExpandedTab?
    /// Hızlı geçişte (bkz. `ExpandedContentView.rapidInterval`) seçim, kapsül ve satır kayması animasyonsuz.
    var rapidSwitch = false
    private var lastRowShift: CGFloat = 0
    private lazy var driver = FrameDriver(view: self) { [weak self] dt in
        guard let self else { return false }
        self.shift.step(dt); self.capsuleX.step(dt)
        self.applyVisualOffsets()
        return self.shift.isActive || self.capsuleX.isActive
    }

    init(model: IslandViewModel, environment: AppEnvironment) {
        self.model = model
        self.environment = environment
        pin = IconButtonView(symbol: model.isPinned ? "pin.fill" : "pin",
                             label: model.isPinned ? "Sabitlemeyi kaldır" : "Adayı açık tut", size: 9.5) { [weak model] in
            model?.send(.togglePin)
        }
        super.init(frame: .zero)
        pin.inHeader = true
        wantsLayer = true
        capsule.cornerRadius = IslandLayoutEngine.tabButtonSize.width / 2
        capsule.cornerCurve = .continuous
        layer?.insertSublayer(capsule, at: 0)
        rebuildButtons()
        addSubview(pin)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    static func centerGap(_ metrics: NotchMetrics) -> CGFloat {
        metrics.style == .notch ? metrics.notchSize.width : Spacing.m
    }

    private func rebuildButtons() {
        let visible = environment.preferences.visibleTabs
        guard visible != visibleTabs else { return }
        visibleTabs = visible
        buttons.values.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        for tab in IslandLayoutEngine.leadingTabOrder + IslandLayoutEngine.trailingTabOrder where visible.contains(tab) {
            let button = TabButtonView(tab: tab) { [weak model, weak self] in
                guard let self, tab != self.selectedTab else { return }
                model?.send(.selectTab(tab))
            }
            buttons[tab] = button
            addSubview(button)
        }
    }

    func refresh() {
        rebuildButtons()
        let tab = model.presentation.expandedTab
        if tab != selectedTab {
            let previousTab = selectedTab
            selectedTab = tab
            // SwiftUI: sekme geçişi yerleşimi değiştiriyorsa `IslandMotion.resize` işleminde, değilse animasyonsuz.
            var spec: SpringSpec?
            if let old = previousTab, let tab, window != nil, !rapidSwitch {
                let metrics = model.metrics
                if IslandLayoutEngine.layout(for: .expanded(old), metrics: metrics) != IslandLayoutEngine.layout(for: .expanded(tab), metrics: metrics) {
                    spec = DeneyMotion.resize(style: DeneyMotion.effectiveStyle(model.motionStyle))
                }
            }
            for (t, b) in buttons { b.setSelected(t == tab, spec: spec) }
        }
        pin.setSymbol(model.isPinned ? "pin.fill" : "pin", label: model.isPinned ? "Sabitlemeyi kaldır" : "Adayı açık tut")
    }

    /// Görünmez başlık iskeletinin (dolgu dahil) yerleşim genişliği.
    func skeletonWidth(bodyWidth: CGFloat) -> CGFloat {
        let p = placement(bodyWidth: bodyWidth, boxWidth: bodyWidth)
        return 2 * p.padding + max(bodyWidth - 2 * p.padding, p.leadingRow + p.gap + p.trailingRow)
    }

    private struct Placement {
        var boxWidth: CGFloat, shift: CGFloat, padding: CGFloat, gap: CGFloat, leadingRow: CGFloat, trailingRow: CGFloat
    }

    private func placement(bodyWidth: CGFloat, boxWidth: CGFloat) -> Placement {
        let metrics = model.metrics
        let padding = IslandLayoutEngine.headerSidePadding(style: metrics.style, size: metrics.expandedSurfaceSize)
        let tab = IslandLayoutEngine.tabButtonSize.width
        let spacing = IslandLayoutEngine.tabSpacing
        let leading = CGFloat(IslandLayoutEngine.leadingTabOrder.filter(visibleTabs.contains).count)
        let trailing = CGFloat(IslandLayoutEngine.trailingTabOrder.filter(visibleTabs.contains).count)
        let leadingRow = leading > 0 ? leading * tab + (leading - 1) * spacing : 0
        let trailingRow = trailing * (tab + spacing) + IconButtonView.diameter(for: 9.5)
        let gap = Self.centerGap(metrics)
        func shift(_ width: CGFloat) -> CGFloat? {
            IslandLayoutEngine.headerRowShift(bodyWidth: width, sidePadding: padding, centerGap: gap,
                                              leadingRowWidth: leadingRow, trailingRowWidth: trailingRow, scale: metrics.scale)
        }
        if let bodyShift = shift(bodyWidth), shift(boxWidth) == 0 {
            return Placement(boxWidth: boxWidth, shift: bodyShift, padding: padding, gap: gap, leadingRow: leadingRow, trailingRow: trailingRow)
        }
        return Placement(boxWidth: bodyWidth, shift: 0, padding: padding, gap: gap, leadingRow: leadingRow, trailingRow: trailingRow)
    }

    private var layoutPositions: [ExpandedTab: CGFloat] = [:]
    private var pinX: CGFloat = 0

    func layoutRow(tab: ExpandedTab, frameWidth: CGFloat) {
        let metrics = model.metrics
        let layout = IslandLayoutEngine.layout(for: .expanded(tab), metrics: metrics)
        let p = placement(bodyWidth: layout.size.width, boxWidth: frameWidth)
        let rowShift = stableRowShift(frameWidth: frameWidth)
        let boxX = (frameWidth - p.boxWidth) / 2 + rowShift
        let inner = p.boxWidth - 2 * p.padding
        let half = (inner - p.gap) / 2
        let size = IslandLayoutEngine.tabButtonSize
        let y = (bounds.height - size.height) / 2
        var x = boxX + p.padding + half - p.leadingRow
        for t in IslandLayoutEngine.leadingTabOrder where visibleTabs.contains(t) {
            layoutPositions[t] = x
            x += size.width + IslandLayoutEngine.tabSpacing
        }
        x = boxX + p.padding + half + p.gap
        for t in IslandLayoutEngine.trailingTabOrder where visibleTabs.contains(t) {
            layoutPositions[t] = x
            x += size.width + IslandLayoutEngine.tabSpacing
        }
        pinX = x
        // Yerleşim (isabet, odak, AX) hedefe tek adımda; görünen kayma ve kapsül yeniden boyutlama yayıyla.
        let style = DeneyMotion.effectiveStyle(model.motionStyle)
        let tabChanged = lastLayoutTab != nil && lastLayoutTab != tab
        let animate = tabChanged && window != nil && !rapidSwitch
        let newShift = rowShift
        if tabChanged && rapidSwitch {
            shift.set(0) // görünen kayma yarıda kalmaz, etiketler doğrudan yeni yerleşimde
        } else if animate, newShift != lastRowShift {
            // Yalnız kayma gerçekten değişince: etiketler eski görünür konumdan yeni yerleşime kayar. (Önceden yeni kayma
            // yayın hedefiyle (0) karşılaştırılıyordu; sıfırdan farklı kaymada satır her geçişte sıçrayıp geri kayıyordu.)
            shift.set(shift.value + lastRowShift - newShift)
            shift.animate(to: 0, spec: DeneyMotion.resize(style: style))
        }
        lastRowShift = newShift
        lastLayoutTab = tab
        for (t, button) in buttons {
            guard let bx = layoutPositions[t] else { continue }
            button.frame = pixelRect(CGRect(x: bx, y: y, width: size.width, height: size.height))
        }
        let d = IconButtonView.diameter(for: 9.5)
        pin.setLayoutFrame(CGRect(x: pinX, y: (bounds.height - d) / 2, width: d, height: d))
        // Seçim kapsülü (matchedGeometryEffect): yerleşim değişince yeniden boyutlama yayıyla, değişmezse anında.
        if let sx = layoutPositions[tab] {
            if animate, layout.size.width != (lastBodyWidth ?? layout.size.width) {
                let visible = capsuleX.value
                capsuleX.set(visible)
                capsuleX.animate(to: sx, spec: DeneyMotion.resize(style: style))
            } else {
                capsuleX.set(sx)
            }
            setCapsuleFrame(pixelRect(CGRect(x: capsuleX.value, y: y, width: size.width, height: size.height)))
        }
        lastBodyWidth = layout.size.width
        applyVisualOffsets()
        if shift.isActive || capsuleX.isActive { driver.start() }
    }

    private var lastBodyWidth: CGFloat?

    /// Satır kayması bütün sekmelerde aynı (kullanıcı isteği; SwiftUI'den bilinçli fark): görünen sekmeler arasındaki en
    /// dar gövdenin kayması. SwiftUI'de kayma sekmenin gövde genişliğine göre değişir; dar gövdeli (kompakt) adada her
    /// geçişte bütün simge satırı birkaç punto sağa sola kayıyordu, hızlı geçişte titreme olarak görünüyordu. En dar
    /// gövdeye sığan satır daha genişlerine de sığar; simgeler hiçbir geçişte yer değiştirmez.
    private var stableShiftKey: (metrics: NotchMetrics, tabs: [ExpandedTab], width: CGFloat)?
    private var stableShift: CGFloat = 0

    private func stableRowShift(frameWidth: CGFloat) -> CGFloat {
        let metrics = model.metrics
        if let key = stableShiftKey, key.metrics == metrics, key.tabs == visibleTabs, key.width == frameWidth { return stableShift }
        let narrowest = visibleTabs.min { IslandLayoutEngine.layout(for: .expanded($0), metrics: metrics).size.width
            < IslandLayoutEngine.layout(for: .expanded($1), metrics: metrics).size.width }
        let width = narrowest.map { IslandLayoutEngine.layout(for: .expanded($0), metrics: metrics).size.width } ?? frameWidth
        stableShift = placement(bodyWidth: width, boxWidth: frameWidth).shift
        stableShiftKey = (metrics, visibleTabs, frameWidth)
        return stableShift
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if FrameDriver.isLogging {
            FrameDriver.note("header window=\(window != nil) capsule attached=\(capsule.superlayer === layer) first=\(layer?.sublayers?.first === capsule) color=\(capsule.backgroundColor != nil)")
        }
    }

    private func setCapsuleFrame(_ rect: CGRect) {
        // Düğmeler yeniden kurulduğunda da en altta kalsın.
        if layer?.sublayers?.first !== capsule {
            if FrameDriver.isLogging {
                FrameDriver.note("capsule reinsert attached=\(capsule.superlayer === layer) index=\(layer?.sublayers?.firstIndex(where: { $0 === capsule }) ?? -1)")
            }
            layer?.insertSublayer(capsule, at: 0)
        }
        if let scale = window?.backingScaleFactor, capsule.contentsScale != scale { capsule.contentsScale = scale }
        guard capsule.frame != rect else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.frame = rect
        CATransaction.commit()
    }

    nonisolated override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        // Dinamik renk (Kontrastı Artır) görünümün görünüşüyle çözülür; görünüş değişince AppKit yeniden çağırır.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance { capsule.backgroundColor = Palette.fillHover.cgColor }
        CATransaction.commit()
    }

    private func applyVisualOffsets() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dx = shift.value
        for button in buttons.values { button.labelOffset = dx }
        pin.labelOffset = dx
        let size = IslandLayoutEngine.tabButtonSize
        // Hareket sırasında kesirli konum (SwiftUI şekli de ara karelerde piksele oturmaz); dururken piksel ızgarası.
        let rect = CGRect(x: capsuleX.value + dx, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let capsuleFrame = shift.isActive || capsuleX.isActive ? rect : pixelRect(rect)
        setCapsuleFrame(capsuleFrame)
        CATransaction.commit()
    }
}

/// Sekme düğmesi: 14 × 24 pt, 12 pt yarı kalın sembol. Seçili beyaz; değil: üçüncül ton (tek katmanlı sembollerde
/// katman opaklığı, alt yolları üst üste binen Pano/Mikser'de renk alfası — TabIconTintCheck ile aynı karar).
final class TabButtonView: FlippedView {
    let tab: ExpandedTab
    private let icon: SymbolView
    private let action: () -> Void
    private(set) var isSelected = false
    /// Seçim değişimi SwiftUI'deki işlemle aynı: yerleşim değiştiyse `IslandMotion.resize` yayı, değişmediyse anında.
    func setSelected(_ selected: Bool, spec: SpringSpec?) {
        guard selected != isSelected else { return }
        isSelected = selected
        setAccessibilitySelected(selected)
        updateTint(spec: spec)
    }
    /// Seçililik miktarı (0…1). Tek katmanlı sembollerde katman opaklığı (render sunucusunda); Pano/Mikser'de renk alfası
    /// alt yollara ayrı uygulandığı için kare sürücüsüyle renk karışımı (SwiftUI renk animasyonu ile birebir).
    private lazy var opacity = LayerSpring(0) { [weak self] s in
        guard let self, let layer = self.icon.layer else { return [] }
        return [(layer, "opacity", Float(self.unselectedAlpha + (1 - self.unselectedAlpha) * s))]
    }
    private var colorAmount = Spring(0)
    private lazy var colorDriver = FrameDriver(view: self) { [weak self] dt in
        guard let self else { return false }
        self.colorAmount.step(dt)
        self.applyColor()
        return self.colorAmount.isActive
    }
    private var unselectedAlpha: CGFloat { Palette.increasedContrast ? 0.7 : 0.48 }
    /// Görünen kayma; sembolün çerçevesi değişmez (`SymbolView.setVisualOffset`). Doğrudan uygulanır: `needsLayout`
    /// her karede pencerenin bütün görünüm ağacını taratıyordu.
    var labelOffset: CGFloat = 0 { didSet { if labelOffset != oldValue { icon.setVisualOffset(labelOffset) } } }

    init(tab: ExpandedTab, action: @escaping () -> Void) {
        self.tab = tab
        self.action = action
        icon = SymbolView(tab.symbolName, size: 12, weight: .semibold)
        super.init(frame: .zero)
        wantsLayer = true
        icon.wantsLayer = true
        addSubview(icon)
        toolTip = tab.title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tab.title)
        setAccessibilityHelp(tab.title)
        updateTint(spec: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    private var usesLayerOpacity: Bool { tab != .mixer && tab != .clipboard }

    private func updateTint(spec: SpringSpec?) {
        let target: Double = isSelected ? 1 : 0
        if usesLayerOpacity {
            icon.contentTintColor = Palette.primary
            opacity.animate(to: CGFloat(target), spec: spec)
        } else if let spec, window != nil {
            colorAmount.animate(to: target, spec: spec)
            colorDriver.start()
        } else {
            colorAmount.set(target)
            applyColor()
        }
    }

    private func applyColor() {
        let a = unselectedAlpha + (1 - unselectedAlpha) * CGFloat(colorAmount.value)
        icon.contentTintColor = NSColor(white: 1, alpha: a)
    }

    override func layout() { super.layout(); layoutIcon() }

    private func layoutIcon() {
        // Kaydırma ofseti canlandırılır; SwiftUI'deki gibi yalnız taban konum piksele oturur.
        let frame = icon.drawingFrame(centeredIn: bounds, halfPixelUp: true)
        if icon.frame != frame { icon.frame = frame }
        icon.setVisualOffset(labelOffset)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// `NSButton` ve SwiftUI düğmesi gibi: klavye odağı yalnız "Klavyeyle gezinme" açıkken. Kapalıyken tıklanan sekme
    /// odağı alıp büyüyen bir odak halkası çiziyordu; hızlı geçişte halkalar yanıp sönüyordu.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override func accessibilityPerformPress() -> Bool { action(); return true }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { action() } else { super.keyDown(with: event) }
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: bounds.width / 2, yRadius: bounds.width / 2).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// Ada içindeki yuvarlak ikon düğmesi (SwiftUI `IslandIconButton`): hover'da dolgu ve 1,06 ölçek.
final class IconButtonView: FlippedView, TransientStateResettable {
    func resetTransientState() {
        guard isHovering else { return }
        isHovering = false
        updateHover(animated: false)
    }

    static func diameter(for size: CGFloat) -> CGFloat { size * 2.1 }

    private let circle = RoundedView(radius: 0, fill: .clear)
    private let icon: SymbolView
    private let action: () -> Void
    private let isProminent: Bool
    private var hoverArea: NSTrackingArea?
    private var isHovering = false { didSet { if isHovering != oldValue { updateHover(animated: true) } } }
    var labelOffset: CGFloat = 0 { didSet { if labelOffset != oldValue { applyLabelOffset() } } }
    /// Başlık satırındaki düğme (iğne): sembolün yarım piksel yuvarlaması başlık kuralıyla.
    var inHeader = false
    /// Hover miktarı (0…1): dolgu ve 1,06 ölçek aynı `IslandMotion.control` yayıyla, düğme merkezi çevresinde
    /// (SwiftUI `.background(Circle).scaleEffect`).
    private lazy var hover = LayerSpring(0) { [weak self] h in
        guard let self, let layer = self.layer, let circleLayer = self.circle.layer else { return [] }
        let scale = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 1 + 0.06 * h
        let center = CGPoint(x: self.bounds.midX + self.labelOffset, y: self.bounds.midY)
        var color = CGColor.clear
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = LayerSpring.mix(self.isProminent ? Palette.fill : Palette.clearWhite, Palette.fillHover, h)
        }
        return [(layer, "transform", LayerSpring.scale(scale, about: center, in: layer)),
                (circleLayer, "backgroundColor", color)]
    }

    init(symbol: String, label: String, size: CGFloat, isProminent: Bool = false, action: @escaping () -> Void) {
        self.action = action
        self.isProminent = isProminent
        icon = SymbolView(symbol, size: size, weight: .semibold,
                          color: isProminent ? Palette.primary : Palette.primary.withAlphaComponent(0.85))
        super.init(frame: .zero)
        wantsLayer = true
        circle.wantsLayer = true
        addSubview(circle)
        addSubview(icon)
        setSymbol(symbol, label: label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateHover(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func setSymbol(_ symbol: String, label: String) {
        icon.set(symbol)
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilityHelp(label)
    }

    private func updateHover(animated: Bool) {
        // Model değeri (görünüm değişiminde `updateLayer` bunu yeniden yazar); görünen geçiş katman yayında.
        circle.fill = isHovering ? Palette.fillHover : (isProminent ? Palette.fill : .clear)
        hover.animate(to: isHovering ? 1 : 0, spec: animated ? DeneyMotion.control : nil)
    }

    override func layout() { super.layout(); layoutContent() }

    /// SwiftUI yerleşim çerçevesi: görünüm piksele oturur, AX ham (kesirli) çerçeveyi bildirir (SwiftUI ile aynı).
    private var layoutRect: CGRect?
    func setLayoutFrame(_ rect: CGRect) {
        layoutRect = rect
        frame = pixelRect(rect)
    }

    override func accessibilityFrame() -> NSRect {
        guard let layoutRect, let superview, let window else { return super.accessibilityFrame() }
        return window.convertToScreen(superview.convert(layoutRect, to: nil))
    }

    private func layoutContent() {
        if circle.frame != bounds { circle.frame = bounds }
        circle.layer?.cornerRadius = bounds.width / 2
        let frame = icon.drawingFrame(centeredIn: bounds, halfPixelUp: inHeader)
        if icon.frame != frame { icon.frame = frame }
        applyLabelOffset()
    }

    /// Görünen kayma daireye ve simgeye birlikte katman dönüşümüyle uygulanır; alt görünüm çerçeveleri yerinde kalır
    /// (kayma animasyonunda kare başına çerçeve değişimi izleme alanlarını kirletiyor, sembolü yeniden çizdiriyordu).
    private func applyLabelOffset() {
        // Simge piksel adımlarıyla kayar (bkz. `SymbolView.setVisualOffset`); piksel arası kaydırma titreme gibi görünür.
        let scale = window?.backingScaleFactor ?? 2
        let dx = (labelOffset * scale).rounded() / scale
        let transform = dx == 0 ? CATransform3DIdentity : CATransform3DMakeTranslation(dx, 0, 0)
        if let layer, !CATransform3DEqualToTransform(layer.sublayerTransform, transform) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = transform
            CATransaction.commit()
        }
        if hover.target != 0 { hover.animate(to: hover.target, spec: nil) } // ölçek merkezi yeni sınırlara/kaymaya göre
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override func accessibilityPerformPress() -> Bool { action(); return true }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { action() } else { super.keyDown(with: event) }
    }
}

/// HUD seviyesi ve olay bildirimleri genişletilmiş adada alt kenarda kısa bir kapsül olarak görünür.
final class BannerHostView: FlippedView {
    private let model: IslandViewModel
    private let capsule = RoundedView(radius: 13, fill: .black)
    private let icon = SymbolView("speaker.wave.2.fill", size: 11, weight: .semibold)
    private let bar = LevelBarView()
    private let text = TextLabel("", font: Fonts.caption)
    private var progress = Spring(0)
    private lazy var driver = FrameDriver(view: self) { [weak self] dt in
        guard let self else { return false }
        self.progress.step(dt)
        self.applyProgress()
        return self.progress.isActive
    }

    init(model: IslandViewModel) {
        self.model = model
        super.init(frame: .zero)
        capsule.stroke = (Palette.fillHover, 0.5)
        addSubview(capsule)
        [icon, bar, text].forEach(capsule.addSubview)
        capsule.wantsLayer = true
        capsule.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func refresh() {
        let hud = model.hud
        let notice = model.notice.map(NoticePresentation.init)
        let visible = hud != nil || (notice?.showsInExpandedIsland ?? false)
        if let hud {
            icon.set(Self.bannerSymbol(hud))
            bar.isHidden = false
            text.isHidden = true
            bar.setLevel(hud.level, animated: true)
            capsule.setAccessibilityLabel("Seviye")
            capsule.setAccessibilityValue("%\(Int((hud.level * 100).rounded()))")
        } else if let notice, notice.showsInExpandedIsland {
            icon.set(notice.bannerSymbol)
            bar.isHidden = true
            text.isHidden = false
            text.set(notice.bannerText)
            capsule.setAccessibilityLabel(notice.bannerText)
        }
        let target: Double = visible ? 1 : 0
        if progress.target != target {
            progress.animate(to: target, spec: DeneyMotion.hud)
            driver.start()
        }
        needsLayout = true
    }

    private static func bannerSymbol(_ hud: HUDPayload) -> String {
        switch hud.kind {
        case .volume(let muted): muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .brightness: "sun.max.fill"
        case .keyboardBacklight: "light.max"
        }
    }

    override func layout() {
        super.layout()
        let s = icon.layoutSize
        let contentWidth = s.width + Spacing.s + (bar.isHidden ? text.naturalWidth : 120)
        let w = contentWidth + 2 * Spacing.m
        let h: CGFloat = max(s.height, 14) + 12
        capsule.frame = CGRect(x: (bounds.width - w) / 2, y: bounds.height - h, width: w, height: h)
        capsule.layer?.cornerRadius = h / 2
        icon.frame = icon.drawingFrame(layoutOrigin: CGPoint(x: capsule.frame.minX + Spacing.m, y: capsule.frame.minY + (h - s.height) / 2))
            .offsetBy(dx: -capsule.frame.minX, dy: -capsule.frame.minY)
        let x = Spacing.m + s.width + Spacing.s
        bar.frame = CGRect(x: x, y: (h - 4) / 2, width: 120, height: 4)
        let th = ceil(text.intrinsicContentSize.height)
        text.frame = CGRect(x: x, y: (h - th) / 2, width: text.naturalWidth, height: th)
        applyProgress()
    }

    private func applyProgress() {
        let p = max(0, min(1, progress.value))
        capsule.isHidden = p <= 0.001
        capsule.layer?.opacity = Float(p)
        capsule.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: CGFloat(1 - p) * 4))
    }
}

extension ExpandedTab {
    /// `ExpandedTab.symbol` (UI/ExpandedIslandView.swift) ile aynı.
    var symbolName: String { symbol }
}
