import AppKit
import IslandCore
import SwiftUI

/// İçerik kimliğinden AppKit görünümü üretir (SwiftUI `IslandStateContent` dalları).
@MainActor
enum IslandContentFactory {
    static func make(_ key: ContentKey, model: IslandViewModel, environment: AppEnvironment) -> IslandContentView? {
        switch key {
        case .none: nil
        case .compact(let activity): CompactContentView(activity: activity, model: model, environment: environment)
        case .hud: HUDContentView(model: model)
        case .unlocked: UnlockContentView(model: model)
        case .audio: AudioNoticeContentView(model: model)
        case .notice(let notice): NoticeContentView(notice: notice, model: model)
        case .dropTarget: DropZoneContentView(model: model)
        case .expanded: ExpandedContentView(model: model, environment: environment)
        }
    }
}

/// Kanat ızgarası (SwiftUI `DeneyWingGrid`): öğeler gövde kenarından dikeyde eşit boşlukla konumlanır.
struct DeneyWingGrid {
    let layout: IslandLayout
    let metrics: NotchMetrics
    let iconSize: CGFloat

    var sideInset: CGFloat { IslandLayoutEngine.bodyInset(for: layout, style: metrics.style) + (layout.size.height - iconSize) / 2 }
    var centerGap: CGFloat { metrics.style == .notch ? metrics.notchSize.width : Spacing.s }
}

// MARK: - Kompakt

/// Kapalı adanın "kanatları": donanım çentiğinin solunda ve sağında canlı etkinlik.
final class CompactContentView: FlippedView, IslandContentView {
    private let activity: CompactActivity
    private let model: IslandViewModel
    private let environment: AppEnvironment
    private var leading: NSView?
    private var trailing: NSView?
    private let value = TextLabel("", font: Fonts.numeric, alignment: .right)
    private var countdown: CountdownTicker?

    init(activity: CompactActivity, model: IslandViewModel, environment: AppEnvironment) {
        self.activity = activity
        self.model = model
        self.environment = environment
        super.init(frame: .zero)
        switch activity {
        case .media:
            break // kalıcı kapak ve dalga katmanları
        case .transfer:
            let ring = TimeProgressLayerView(style: .ring(lineWidth: 2.5))
            let arrow = SymbolView("arrow.down", size: 7, weight: .bold, color: .systemBlue)
            ring.addSubview(arrow)
            leading = ring
            value.textColor = .systemBlue
            trailing = value
        case .timer:
            leading = TimeProgressLayerView(style: .ring(lineWidth: 2.5))
            trailing = value
            countdown = CountdownTicker { [weak self] in self?.refresh() }
        case .shelf:
            leading = SymbolView("tray.full.fill", size: 13, weight: .semibold)
            trailing = value
        }
        [leading, trailing].compactMap { $0 }.forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func fittingFrameSize(canvas: CGSize, metrics: NotchMetrics) -> CGSize {
        IslandLayoutEngine.layout(for: .compact(activity), metrics: metrics).size
    }

    func refresh() {
        switch activity {
        case .media: break
        case .transfer:
            let t = environment.transfers
            (leading as? TimeProgressLayerView)?.configure(
                timing: .init(progress: t.fraction, reference: .distantPast, rate: 0, isRunning: false),
                tint: .systemBlue, track: .white.withAlphaComponent(0.18))
            value.set("%\(Int((t.fraction * 100).rounded(.down)))")
            setAccessibilityLabel("\(t.primaryName ?? "Aktarım"), yüzde \(Int(t.fraction * 100))")
        case .timer:
            let timer = environment.focusTimer
            (leading as? TimeProgressLayerView)?.configure(timing: timer.progressTiming, tint: NSColor(timer.phase.tint),
                                                           track: .white.withAlphaComponent(0.18))
            let remaining = timer.remaining(at: .now).rounded(.up)
            value.set(remaining.clockString)
            value.textColor = NSColor(timer.phase.tint)
            setAccessibilityLabel("\(timer.phase.title), kalan \(remaining.clockString)")
            countdown?.set(running: timer.isRunning)
        case .shelf:
            let count = environment.shelf.items.count
            value.set("\(count)")
            setAccessibilityLabel("Rafta \(count) öğe")
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let layout = IslandLayoutEngine.layout(for: .compact(activity), metrics: model.metrics)
        let grid = DeneyWingGrid(layout: layout, metrics: model.metrics, iconSize: 18)
        let h = bounds.height
        if let leading {
            if let symbol = leading as? SymbolView {
                let size = symbol.layoutSize
                symbol.frame = symbol.drawingFrame(layoutOrigin: CGPoint(x: grid.sideInset, y: (h - size.height) / 2))
            } else {
                let size: CGSize = leading is TimeProgressLayerView ? CGSize(width: 16, height: 16) : leading.intrinsicContentSize
                leading.frame = CGRect(x: grid.sideInset, y: (h - size.height) / 2, width: size.width, height: size.height)
            }
            if let arrow = leading.subviews.first as? SymbolView {
                arrow.frame = arrow.drawingFrame(centeredIn: CGRect(x: 0, y: 0, width: 16, height: 16))
            }
        }
        if trailing != nil {
            let width = (bounds.width - grid.centerGap) / 2 - grid.sideInset
            let lineHeight = ceil(value.intrinsicContentSize.height)
            value.frame = CGRect(x: bounds.width - grid.sideInset - width, y: (h - lineHeight) / 2, width: width, height: lineHeight)
        }
    }
}

/// Tam saniye sınırlarında tetiklenen tek seferlik zamanlayıcı zinciri (SwiftUI `PausablePeriodicSchedule` karşılığı).
@MainActor
final class CountdownTicker {
    private var timer: Timer?
    private let fire: () -> Void

    init(fire: @escaping () -> Void) { self.fire = fire }

    func set(running: Bool) {
        if running { schedule() } else { timer?.invalidate(); timer = nil }
    }

    private func schedule() {
        guard timer == nil else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let next = Date(timeIntervalSinceReferenceDate: floor(now) + 1)
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = nil
                self?.fire()
            }
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    isolated deinit { timer?.invalidate() }
}

// MARK: - HUD

/// Native HUD'un yerini alan kompakt gösterge: solda ikon, sağda seviye çubuğu ve değer.
final class HUDContentView: FlippedView, IslandContentView {
    private let model: IslandViewModel
    private let icon = SymbolView("speaker.wave.2.fill", size: 13, weight: .semibold)
    private let bar = LevelBarView()
    private let value = TextLabel("", font: Fonts.numericSmall, color: Palette.secondary, alignment: .right)

    init(model: IslandViewModel) {
        self.model = model
        super.init(frame: .zero)
        [icon, bar, value].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func fittingFrameSize(canvas: CGSize, metrics: NotchMetrics) -> CGSize {
        guard let payload = model.hud else { return .zero }
        return IslandLayoutEngine.layout(for: .hud(payload), metrics: metrics).size
    }

    func refresh() {
        guard let payload = model.hud else { return }
        icon.set(Self.symbol(payload))
        let muted: Bool = if case .volume(muted: true) = payload.kind { true } else { false }
        bar.tint = muted ? Palette.tertiary : Palette.primary
        bar.setLevel(payload.level, animated: true)
        value.set("\(Int((payload.level * 100).rounded()))")
        setAccessibilityLabel(Self.title(payload))
        setAccessibilityValue("%\(Int((payload.level * 100).rounded()))")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let payload = model.hud else { return }
        let layout = IslandLayoutEngine.layout(for: .hud(payload), metrics: model.metrics)
        let grid = DeneyWingGrid(layout: layout, metrics: model.metrics, iconSize: 18)
        let h = bounds.height
        icon.frame = icon.drawingFrame(centeredIn: CGRect(x: grid.sideInset, y: 0, width: 18, height: h))
        let groupX = bounds.width - grid.sideInset - 92
        let lineHeight = ceil(value.intrinsicContentSize.height)
        value.frame = CGRect(x: groupX + 92 - 22, y: (h - lineHeight) / 2, width: 22, height: lineHeight)
        bar.frame = CGRect(x: groupX, y: (h - 5) / 2, width: 92 - 22 - Spacing.s, height: 5)
    }

    static func symbol(_ payload: HUDPayload) -> String {
        switch payload.kind {
        case .volume(let muted):
            if muted || payload.level == 0 { return "speaker.slash.fill" }
            if payload.level < 0.33 { return "speaker.wave.1.fill" }
            if payload.level < 0.66 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness: return payload.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .keyboardBacklight: return payload.level < 0.5 ? "light.min" : "light.max"
        }
    }

    static func title(_ payload: HUDPayload) -> String {
        switch payload.kind {
        case .volume(let muted): muted ? "Ses kapalı" : "Ses"
        case .brightness: "Ekran parlaklığı"
        case .keyboardBacklight: "Klavye aydınlatması"
        }
    }
}

/// HUD seviye çubuğu (SwiftUI `LevelBar`): kapsül iz + kapsül dolgu; değişim HUD yayıyla.
final class LevelBarView: FlippedView {
    private let track = CALayer()
    private let fillLayer = CALayer()
    private var level = Spring(0)
    var tint: NSColor = Palette.primary { didSet { applyColors() } }
    var trackColor: NSColor = Palette.track { didSet { applyColors() } }
    private lazy var driver = FrameDriver(view: self) { [weak self] dt in
        guard let self else { return false }
        self.level.step(dt)
        self.layoutBars()
        return self.level.isActive
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [track, fillLayer] { l.actions = IslandCanvasView.noActions; layer?.addSublayer(l) }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func setLevel(_ value: Double, animated: Bool) {
        if animated && window != nil { level.animate(to: value, spec: DeneyMotion.hud); driver.start() } else { level.set(value) }
        layoutBars()
    }

    override func layout() { super.layout(); layoutBars() }
    override func viewDidChangeEffectiveAppearance() { applyColors() }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = trackColor.cgColor
            fillLayer.backgroundColor = tint.cgColor
        }
    }

    private func layoutBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = bounds.height
        track.frame = bounds
        track.cornerRadius = h / 2
        let w = max(h, bounds.width * level.value)
        fillLayer.frame = CGRect(x: 0, y: 0, width: w, height: h)
        fillLayer.cornerRadius = h / 2
        fillLayer.opacity = level.value > 0 ? 1 : 0
        CATransaction.commit()
    }
}

// MARK: - Bildirimler

/// Geçici olay bildirimi: kanat satırı (solda simge, sağda değer) + çentiğin altında tek satır açıklama.
final class NoticeContentView: FlippedView, IslandContentView {
    private let notice: IslandNotice
    private let model: IslandViewModel
    private var leading: NSView?
    private var trailing: NSView?
    private let caption = TextLabel("", font: Fonts.caption, color: Palette.secondary, alignment: .center, truncation: .byTruncatingMiddle)

    init(notice: IslandNotice, model: IslandViewModel) {
        self.notice = notice
        self.model = model
        super.init(frame: .zero)
        let p = NoticePresentation(notice)
        switch p.leading {
        case let .symbol(name, color):
            let v = SymbolView(name, size: 14, weight: .semibold, color: NSColor(color))
            v.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                .applying(.init(hierarchicalColor: NSColor(color)))
            leading = v
        case .battery(let event):
            leading = BatteryGlyphView(level: event.level, isCharging: event.isCharging || event.kind == .pluggedIn,
                                       tint: NSColor(event.tint))
        case .swatch(let hex):
            let v = RoundedView(radius: 8, fill: NSColor(hexString: hex) ?? .white)
            v.stroke = (NSColor.white.withAlphaComponent(0.25), 0.5)
            leading = v
        case .artworkLayer:
            leading = nil
        }
        switch p.trailing {
        case let .value(text, color):
            trailing = TextLabel(text, font: Fonts.numeric, color: NSColor(color), alignment: .right)
        case .symbol(let name):
            trailing = SymbolView(name, size: 11, weight: .semibold, color: Palette.secondary)
        case .waveformLayer:
            trailing = nil
        }
        caption.set(p.caption)
        [leading, trailing, caption].compactMap { $0 }.forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(p.caption)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func fittingFrameSize(canvas: CGSize, metrics: NotchMetrics) -> CGSize {
        IslandLayoutEngine.layout(for: .notice(notice), metrics: metrics).size
    }

    func refresh() {}

    override func layout() {
        super.layout()
        let metrics = model.metrics
        let layout = IslandLayoutEngine.layout(for: .notice(notice), metrics: metrics)
        let wingHeight = metrics.notchSize.height
        let side = IslandLayoutEngine.bodyInset(for: layout, style: metrics.style) + (wingHeight - 20) / 2
        let gap = metrics.style == .notch ? metrics.notchSize.width : Spacing.s
        let wingWidth = (bounds.width - 2 * side - gap) / 2
        if let leading {
            if let symbol = leading as? SymbolView {
                let size = symbol.layoutSize
                symbol.frame = symbol.drawingFrame(layoutOrigin: CGPoint(x: side, y: (wingHeight - size.height) / 2))
            } else {
                let size: CGSize = switch leading {
                case is BatteryGlyphView: CGSize(width: 28.5, height: 12)
                case is RoundedView: CGSize(width: 16, height: 16)
                default: leading.intrinsicContentSize
                }
                leading.frame = CGRect(x: side, y: (wingHeight - size.height) / 2, width: size.width, height: size.height)
            }
        }
        if let trailing {
            if let label = trailing as? TextLabel {
                let lh = ceil(label.intrinsicContentSize.height)
                label.frame = CGRect(x: bounds.width - side - wingWidth, y: (wingHeight - lh) / 2, width: wingWidth, height: lh)
            } else if let symbol = trailing as? SymbolView {
                let s = symbol.layoutSize
                symbol.frame = symbol.drawingFrame(layoutOrigin: CGPoint(x: bounds.width - side - s.width, y: (wingHeight - s.height) / 2))
            } else {
                let s = trailing.intrinsicContentSize
                trailing.frame = CGRect(x: bounds.width - side - s.width, y: (wingHeight - s.height) / 2, width: s.width, height: s.height)
            }
        }
        let lh = ceil(caption.intrinsicContentSize.height)
        let rest = bounds.height - wingHeight - Spacing.xxs
        caption.frame = CGRect(x: Spacing.l, y: wingHeight + (rest - lh) / 2, width: bounds.width - 2 * Spacing.l, height: lh)
    }
}

/// Dolum animasyonlu pil simgesi: görünür olduğu an bir kez yayla dolar.
final class BatteryGlyphView: FlippedView {
    private let body = RoundedView(radius: 3.5, fill: .clear)
    private let fillView: RoundedView
    private let tip = RoundedView(radius: 1, fill: NSColor.white.withAlphaComponent(0.45))
    private let bolt: SymbolView?
    private let target: Double
    private var level = Spring(0)
    private lazy var driver = FrameDriver(view: self) { [weak self] dt in
        guard let self else { return false }
        self.level.step(dt)
        self.needsLayout = true
        return self.level.isActive
    }

    init(level: Double, isCharging: Bool, tint: NSColor) {
        target = level
        fillView = RoundedView(radius: 2, fill: tint)
        bolt = isCharging ? SymbolView("bolt.fill", size: 8, weight: .bold, color: .white) : nil
        super.init(frame: .zero)
        body.stroke = (NSColor.white.withAlphaComponent(0.45), 1)
        [body, fillView, tip].forEach(addSubview)
        if let bolt {
            bolt.wantsLayer = true
            bolt.layer?.shadowColor = NSColor.black.cgColor
            bolt.layer?.shadowOpacity = 0.6
            bolt.layer?.shadowRadius = 1
            addSubview(bolt)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, level.target != target else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { level.set(target) } else {
            level.animate(to: target, spec: SpringSpec(response: 0.8, damping: 0.86, delay: 0.12))
            driver.start()
        }
    }

    override func layout() {
        super.layout()
        body.frame = CGRect(x: 0, y: 0, width: 25, height: 12)
        fillView.frame = CGRect(x: 2, y: 2, width: max(2, 21 * level.value), height: 8)
        tip.frame = CGRect(x: 26.5, y: 4, width: 1.5, height: 4)
        if let bolt {
            bolt.frame = bolt.drawingFrame(centeredIn: CGRect(x: 0, y: 0, width: 25, height: 12))
        }
    }
}

/// Ses aygıtı bildirimi: yalnız kanatlar kullanılır (solda aygıt simgesi, sağda ad + durum).
final class AudioNoticeContentView: FlippedView, IslandContentView {
    private let model: IslandViewModel
    private let notice: IslandNotice?
    private let icon = SymbolView("airpods", size: 17, weight: .medium)
    private let name = TextLabel("", font: NSFont.systemFont(ofSize: 11, weight: .medium), alignment: .center, truncation: .byTruncatingMiddle)
    private let status = TextLabel("", font: NSFont.systemFont(ofSize: 9), color: Palette.secondary, alignment: .center)

    init(model: IslandViewModel) {
        self.model = model
        notice = model.notice
        super.init(frame: .zero)
        [icon, name, status].forEach(addSubview)
        if case let .audioOutput(n, kind, connected) = notice {
            icon.set(kind.symbol, animated: false)
            name.set(n)
            status.set(connected ? "Bağlandı" : "Bağlantı kesildi")
            setAccessibilityLabel(NoticePresentation(notice!).caption)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func fittingFrameSize(canvas: CGSize, metrics: NotchMetrics) -> CGSize {
        guard let notice else { return .zero }
        return IslandLayoutEngine.layout(for: .notice(notice), metrics: metrics).size
    }

    func refresh() {}

    override func layout() {
        super.layout()
        let metrics = model.metrics
        let wing = (bounds.width - metrics.notchSize.width) / 2
        icon.setConfiguration(size: min(bounds.height * 0.48, 17), weight: .medium)
        icon.frame = icon.drawingFrame(centeredIn: CGRect(x: 0, y: 0, width: wing, height: bounds.height))
        let x = wing + metrics.notchSize.width + 10
        let w = wing - 20
        let h1 = ceil(name.intrinsicContentSize.height), h2 = ceil(status.intrinsicContentSize.height)
        let top = (bounds.height - h1 - 1 - h2) / 2
        name.frame = CGRect(x: x, y: top, width: w, height: h1)
        status.frame = CGRect(x: x, y: top + h1 + 1, width: w, height: h2)
    }
}

/// Kilit açılma geri bildirimi: sembol sol kanadın ortasında, adanın genişlemesiyle aynı yayla kayar; kilit
/// genişlemenin tepesinde açılır (`lock.fill` → `lock.open.fill`).
final class UnlockContentView: FlippedView, IslandContentView {
    private let model: IslandViewModel
    private let symbol: SymbolView
    private var expansion = Spring(0)
    private var unlock = Spring(0)
    private var isUnlocked = false
    private lazy var driver = FrameDriver(view: self) { [weak self] dt in
        guard let self else { return false }
        self.expansion.step(dt); self.unlock.step(dt)
        self.needsLayout = true
        return self.expansion.isActive || self.unlock.isActive
    }

    init(model: IslandViewModel) {
        self.model = model
        let size = min(model.metrics.notchSize.height * 0.48, 18).rounded()
        symbol = SymbolView("lock.fill", size: size, weight: .medium)
        super.init(frame: .zero)
        symbol.wantsLayer = true
        addSubview(symbol)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Kilit açıldı")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func fittingFrameSize(canvas: CGSize, metrics: NotchMetrics) -> CGSize {
        IslandLayoutEngine.layout(for: .notice(.unlocked), metrics: metrics).size
    }

    func refresh() {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, expansion.target == 0 else { return }
        let style = DeneyMotion.effectiveStyle(model.motionStyle)
        expansion.animate(to: 1, spec: DeneyMotion.morph(from: .idle, to: .notice(.unlocked), style: style))
        unlock.animate(to: 1, spec: style == .reduced ? SpringSpec(response: 0.12, damping: 1, delay: 0.18)
                                                      : SpringSpec(response: 0.16, damping: 0.85, delay: 0.18))
        driver.start()
    }

    override func layout() {
        super.layout()
        let metrics = model.metrics
        let layout = IslandLayoutEngine.layout(for: .notice(.unlocked), metrics: metrics)
        let wingWidth = max((layout.size.width - metrics.notchSize.width) / 2, 0)
        let visibleWing = max(wingWidth * expansion.value - layout.topCornerRadius, 0)
        let centerX = bounds.midX - (metrics.notchSize.width / 2 + visibleWing / 2)
        if unlock.value > 0.01 && !isUnlocked {
            isUnlocked = true
            symbol.set("lock.open.fill", animated: model.motionStyle != .reduced)
        }
        let reduced = DeneyMotion.effectiveStyle(model.motionStyle) == .reduced
        let scale = reduced ? 1 : 0.7 + 0.3 * unlock.value
        symbol.layer?.opacity = Float(0.6 + 0.4 * unlock.value)
        let s = symbol.layoutSize
        symbol.frame = symbol.drawingFrame(centeredIn: CGRect(x: centerX - s.width / 2, y: 0, width: s.width, height: bounds.height))
        if let l = symbol.layer {
            l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            l.position = CGPoint(x: symbol.frame.midX, y: symbol.frame.midY)
            l.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        }
    }
}

// MARK: - Bırakma bölgesi

/// Sürükleme sırasında: "Rafa bırak" ve "AirDrop" kutucukları (kesikli kenarlı).
final class DropZoneContentView: FlippedView, IslandContentView {
    private let model: IslandViewModel
    private let shelfTile = DropTile(title: "Rafa bırak", symbol: "tray.and.arrow.down.fill")
    private let airDropTile = DropTile(title: "AirDrop", symbol: "antenna.radiowaves.left.and.right")
    var zone: DropZone? { didSet { shelfTile.isActive = zone == .shelf; airDropTile.isActive = zone == .airDrop } }

    init(model: IslandViewModel) {
        self.model = model
        super.init(frame: .zero)
        [shelfTile, airDropTile].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func fittingFrameSize(canvas: CGSize, metrics: NotchMetrics) -> CGSize {
        IslandLayoutEngine.layout(for: .dropTarget, metrics: metrics).size
    }

    func refresh() {}

    override func layout() {
        super.layout()
        let metrics = model.metrics
        let layout = IslandLayoutEngine.layout(for: .dropTarget, metrics: metrics)
        let side = IslandLayoutEngine.contentSideInset(for: layout, style: metrics.style)
        let top = metrics.notchSize.height + IslandLayoutEngine.headerGap
        let h = bounds.height - top - IslandLayoutEngine.contentInset
        let w = (bounds.width - 2 * side - Spacing.m) / 2
        shelfTile.frame = CGRect(x: side, y: top, width: w, height: h)
        airDropTile.frame = CGRect(x: side + w + Spacing.m, y: top, width: w, height: h)
    }
}

final class DropTile: FlippedView {
    private let background = CAShapeLayer()
    private let icon: SymbolView
    private let title: TextLabel
    var isActive = false { didSet { if isActive != oldValue { update(); if isActive { icon.addSymbolEffect(.bounce) } } } }

    init(title text: String, symbol: String) {
        icon = SymbolView(symbol, size: 20, weight: .semibold)
        title = TextLabel(text, font: Fonts.bodyEmphasized, alignment: .center)
        super.init(frame: .zero)
        wantsLayer = true
        background.lineWidth = 1
        background.lineDashPattern = [5, 4]
        background.actions = IslandCanvasView.noActions
        layer?.addSublayer(background)
        [icon, title].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    /// Etkinlik miktarı (0…1): dolgu, kesikli kenar rengi ve 1,02 ölçek `.animation(IslandMotion.control)` ile.
    private lazy var activity = LayerSpring(0) { [weak self] a in
        guard let self, let layer = self.layer else { return [] }
        var fill = CGColor.clear, stroke = CGColor.clear
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = LayerSpring.mix(Palette.fill, Palette.fillHover, a)
            stroke = LayerSpring.mix(Palette.separator, Palette.secondary, a)
        }
        let center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        return [(layer, "transform", LayerSpring.scale(1 + 0.02 * a, about: center, in: layer)),
                (self.background, "fillColor", fill), (self.background, "strokeColor", stroke)]
    }

    private func update() {
        setAccessibilitySelected(isActive)
        activity.animate(to: isActive ? 1 : 0, spec: window != nil ? DeneyMotion.control : nil)
    }

    override func layout() {
        super.layout()
        let radius = Spacing.cardRadius
        background.frame = bounds
        background.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil)
        let s = icon.layoutSize
        let th = title.lineHeight
        let total = s.height + Spacing.s + th
        let top = (bounds.height - total) / 2
        icon.frame = icon.drawingFrame(layoutOrigin: CGPoint(x: (bounds.width - s.width) / 2, y: top))
        title.frame = pixelRect(CGRect(x: 0, y: top + s.height + Spacing.s, width: bounds.width, height: th))
        activity.animate(to: activity.target, spec: nil) // ölçek merkezi yeni sınırlara göre
    }
}
