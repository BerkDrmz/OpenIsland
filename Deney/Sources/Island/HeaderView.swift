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
    private let capsule = RoundedView(radius: 7, fill: Palette.fillHover)
    private var visibleTabs: [ExpandedTab] = []
    private var selectedTab: ExpandedTab?
    /// Görünen kayma (etiketler); yerleşim hedefe tek adımda geçer.
    private var shift = Spring(0)
    private var capsuleX = Spring(0)
    private var lastLayoutTab: ExpandedTab?
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
        capsule.layer?.cornerRadius = IslandLayoutEngine.tabButtonSize.width / 2
        addSubview(capsule)
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
            selectedTab = tab
            for (t, b) in buttons { b.isSelected = t == tab }
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
        let boxX = (frameWidth - p.boxWidth) / 2 + p.shift
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
        let animate = lastLayoutTab != nil && lastLayoutTab != tab && window != nil
        let newShift = p.shift
        if animate {
            if newShift != shift.target {
                let visible = shift.value
                shift.set(visible - newShift) // etiketler eski görünür konumdan…
                shift.animate(to: 0, spec: DeneyMotion.resize(style: style)) // …yeni yerleşime kayar
            }
        }
        lastLayoutTab = tab
        for (t, button) in buttons {
            guard let bx = layoutPositions[t] else { continue }
            button.frame = CGRect(x: bx, y: y, width: size.width, height: size.height)
        }
        let d = IconButtonView.diameter(for: 9.5)
        pin.frame = CGRect(x: pinX, y: (bounds.height - d) / 2, width: d, height: d)
        // Seçim kapsülü (matchedGeometryEffect): yerleşim değişince yeniden boyutlama yayıyla, değişmezse anında.
        if let sx = layoutPositions[tab] {
            if animate, layout.size.width != (lastBodyWidth ?? layout.size.width) {
                let visible = capsuleX.value
                capsuleX.set(visible)
                capsuleX.animate(to: sx, spec: DeneyMotion.resize(style: style))
            } else {
                capsuleX.set(sx)
            }
            capsule.frame = CGRect(x: capsuleX.value, y: y, width: size.width, height: size.height)
        }
        lastBodyWidth = layout.size.width
        applyVisualOffsets()
        if shift.isActive || capsuleX.isActive { driver.start() }
    }

    private var lastBodyWidth: CGFloat?

    private func applyVisualOffsets() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dx = shift.value
        for button in buttons.values { button.labelOffset = dx }
        pin.labelOffset = dx
        let size = IslandLayoutEngine.tabButtonSize
        capsule.frame = CGRect(x: capsuleX.value + dx, y: capsule.frame.minY, width: size.width, height: size.height)
        CATransaction.commit()
    }
}

/// Sekme düğmesi: 14 × 24 pt, 12 pt yarı kalın sembol. Seçili beyaz; değil: üçüncül ton (tek katmanlı sembollerde
/// katman opaklığı, alt yolları üst üste binen Pano/Mikser'de renk alfası — TabIconTintCheck ile aynı karar).
final class TabButtonView: FlippedView {
    let tab: ExpandedTab
    private let icon: SymbolView
    private let action: () -> Void
    var isSelected = false { didSet { if isSelected != oldValue { updateTint(); setAccessibilitySelected(isSelected) } } }
    var labelOffset: CGFloat = 0 { didSet { if labelOffset != oldValue { needsLayout = true; layoutIcon() } } }

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
        updateTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    private var usesLayerOpacity: Bool { tab != .mixer && tab != .clipboard }

    private func updateTint() {
        if usesLayerOpacity {
            icon.contentTintColor = Palette.primary
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                icon.layer?.opacity = isSelected ? 1 : Float(Palette.increasedContrast ? 0.7 : 0.48)
            }
        } else {
            icon.contentTintColor = isSelected ? Palette.primary : Palette.tertiary
        }
    }

    override func layout() { super.layout(); layoutIcon() }

    private func layoutIcon() {
        let s = icon.intrinsicContentSize
        icon.frame = CGRect(x: (bounds.width - s.width) / 2 + labelOffset, y: (bounds.height - s.height) / 2,
                            width: s.width, height: s.height)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func accessibilityPerformPress() -> Bool { action(); return true }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { action() } else { super.keyDown(with: event) }
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: bounds.width / 2, yRadius: bounds.width / 2).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// Ada içindeki yuvarlak ikon düğmesi (SwiftUI `IslandIconButton`): hover'da dolgu ve 1,06 ölçek.
final class IconButtonView: FlippedView {
    static func diameter(for size: CGFloat) -> CGFloat { size * 2.1 }

    private let circle = RoundedView(radius: 0, fill: .clear)
    private let icon: SymbolView
    private let action: () -> Void
    private let isProminent: Bool
    private var hoverArea: NSTrackingArea?
    private var isHovering = false { didSet { updateHover() } }
    var labelOffset: CGFloat = 0 { didSet { if labelOffset != oldValue { layoutContent() } } }

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
        updateHover()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func setSymbol(_ symbol: String, label: String) {
        icon.set(symbol)
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilityHelp(label)
    }

    private func updateHover() {
        circle.fill = isHovering ? Palette.fillHover : (isProminent ? Palette.fill : .clear)
        let scale: CGFloat = isHovering && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.06 : 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            ctx.allowsImplicitAnimation = true
            circle.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            icon.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        }
    }

    override func layout() { super.layout(); layoutContent() }

    private func layoutContent() {
        circle.frame = bounds.offsetBy(dx: labelOffset, dy: 0)
        circle.layer?.cornerRadius = bounds.width / 2
        let s = icon.intrinsicContentSize
        icon.frame = CGRect(x: (bounds.width - s.width) / 2 + labelOffset, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
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
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
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
        let s = icon.intrinsicContentSize
        let contentWidth = s.width + Spacing.s + (bar.isHidden ? text.naturalWidth : 120)
        let w = contentWidth + 2 * Spacing.m
        let h: CGFloat = max(s.height, 14) + 12
        capsule.frame = CGRect(x: (bounds.width - w) / 2, y: bounds.height - h, width: w, height: h)
        capsule.layer?.cornerRadius = h / 2
        icon.frame = CGRect(x: Spacing.m, y: (h - s.height) / 2, width: s.width, height: s.height)
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
