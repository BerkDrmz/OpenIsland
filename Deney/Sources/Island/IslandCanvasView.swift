import AppKit
import IslandCore
import QuartzCore
import SwiftUI

/// Adanın AppKit kök görünümü (SwiftUI `IslandRootView` karşılığı).
///
/// Katman düzeni aynı: tek bir siyah yüzey morph eder; her durumun içeriği kendi **sabit** boyutunda yerleşir ve
/// büyüyen yüzey tarafından kırpılarak açığa çıkar. Yüzeyin boyutu ve köşe yarıçapları SwiftUI ile aynı yay
/// fiziğiyle (`Spring`) canlanır; yol her karede `IslandShape`'in kendi geometrisinden üretilir (sürekli eğrilik).
/// Animasyon yalnız sürerken ekran tazelemesine bağlı sürücü çalışır; durağan adada hiç iş yok.
@MainActor
final class IslandCanvasView: NSView {
    /// SwiftUI'nin kendi bağlam menüsü yoksa gösterilen ada menüsü (kök host ile aynı davranış).
    var fallbackMenu: (() -> NSMenu)?

    let model: IslandViewModel
    let environment: AppEnvironment

    private let surfaceView = ShapeView()     // #000000 gövde
    private let maskLayer = CAShapeLayer()    // içerik kırpması (aynı yol)
    private let contentView = FlippedView()
    private let media: MediaLayersView

    /// Ekranda çizilen (canlanan) yüzeyin hedefi; SwiftUI'deki `surface` durumunun karşılığı.
    private var surfacePresentation: IslandPresentation
    private var surfaceLayout: IslandLayout
    private var width: Spring, height: Spring, topRadius: Spring, bottomRadius: Spring, topInset: Spring
    private var relax = Spring(1)
    private var pendingOpening: DispatchWorkItem?

    private var slots: [ContentSlot] = []
    private var displayedPresentation: IslandPresentation
    private var displayedTab: ExpandedTab?

    private lazy var driver = FrameDriver(view: self) { [weak self] dt in self?.tick(dt) ?? false }

    init(model: IslandViewModel, environment: AppEnvironment) {
        self.model = model
        self.environment = environment
        let layout = model.layout
        surfacePresentation = model.presentation
        surfaceLayout = layout
        displayedPresentation = model.presentation
        width = Spring(layout.size.width)
        height = Spring(layout.size.height)
        topRadius = Spring(layout.topCornerRadius)
        bottomRadius = Spring(layout.bottomCornerRadius)
        topInset = Spring(layout.topInset)
        media = MediaLayersView(media: environment.media, preferences: environment.preferences)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false

        surfaceView.shapeLayer.fillColor = NSColor.black.cgColor
        addSubview(surfaceView)
        maskLayer.fillColor = NSColor.black.cgColor
        maskLayer.actions = Self.noActions

        contentView.wantsLayer = true
        contentView.layerUsesCoreImageFilters = true
        contentView.layer?.mask = maskLayer
        addSubview(contentView)
        contentView.addSubview(media)

        rebuildContent(animated: false)
        observeModel()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("OpenIsland")
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Genişlet") { [weak model] in
            model?.send(.tapped); return true
        }])
    }

    override func accessibilityPerformCancel() -> Bool { model.send(.escapePressed); return true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    static let noActions: [String: CAAction] = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(),
                                                 "opacity": NSNull(), "transform": NSNull(), "frame": NSNull(),
                                                 "contents": NSNull(), "hidden": NSNull(), "filters": NSNull()]

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { super.menu(for: event) ?? fallbackMenu?() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceView.frame = bounds
        contentView.frame = bounds
        maskLayer.frame = contentView.bounds
        CATransaction.commit()
        applyFrame()
    }

    // MARK: - Model gözlemi

    /// Yalnız okunan değerler değişince tek bir geri çağrı; değer uygulanıp yeniden abone olunur (yoklama yok).
    private func observeModel() {
        withObservationTracking {
            _ = model.presentation; _ = model.layout; _ = model.hud; _ = model.notice
            _ = model.isPinned; _ = model.isRelaxing; _ = model.metrics
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.modelDidChange() } }
        }
    }

    private func modelDidChange() {
        observeModel()
        let target = (layout: model.layout, presentation: model.presentation)
        morph(toLayout: target.layout, presentation: target.presentation)
        if model.presentation != displayedPresentation || model.presentation.expandedTab != displayedTab {
            rebuildContent(animated: true)
        } else {
            slots.forEach { $0.view.refresh() }
        }
        let style = DeneyMotion.effectiveStyle(model.motionStyle)
        let relaxTarget = model.isRelaxing ? Double(DeneyMotion.relaxScale) : 1
        if relax.target != relaxTarget {
            relax.animate(to: relaxTarget, spec: style == .reduced ? DeneyMotion.reduced : DeneyMotion.relax)
            driver.start()
        }
    }

    // MARK: - Yüzey morph'u (IslandRootView.morph ile aynı mantık)

    private func morph(toLayout layout: IslandLayout, presentation: IslandPresentation) {
        guard layout != surfaceLayout || presentation != surfacePresentation else { return }
        pendingOpening?.cancel()
        pendingOpening = nil
        let style = DeneyMotion.effectiveStyle(model.motionStyle)
        if presentation.isExpanded && surfacePresentation.isExpanded {
            if layout == surfaceLayout {
                surfacePresentation = presentation
            } else {
                applySurface(layout: layout, presentation: presentation, spec: DeneyMotion.resize(style: style))
            }
            return
        }
        let spec = DeneyMotion.morph(from: surfacePresentation, to: presentation, style: style)
        if presentation.isExpanded && !surfacePresentation.isExpanded {
            // Önce hedef içerik kurulup yerleşir, sonra taze bir yay saati başlar (SwiftUI sürümüyle aynı).
            let work = DispatchWorkItem { [weak self] in
                self?.applySurface(layout: layout, presentation: presentation, spec: spec)
                self?.pendingOpening = nil
            }
            pendingOpening = work
            DispatchQueue.main.async(execute: work)
        } else {
            applySurface(layout: layout, presentation: presentation, spec: spec)
        }
    }

    private func applySurface(layout: IslandLayout, presentation: IslandPresentation, spec: SpringSpec) {
        let wasExpanded = surfacePresentation.isExpanded
        surfaceLayout = layout
        surfacePresentation = presentation
        width.animate(to: layout.size.width, spec: spec)
        height.animate(to: layout.size.height, spec: spec)
        topRadius.animate(to: layout.topCornerRadius, spec: spec)
        bottomRadius.animate(to: layout.bottomCornerRadius, spec: spec)
        topInset.animate(to: layout.topInset, spec: spec)
        media.retarget(presentation: presentation, metrics: model.metrics, spec: spec, style: DeneyMotion.effectiveStyle(model.motionStyle))
        if wasExpanded != presentation.isExpanded {
            slots.first { $0.isExpanded && !$0.isRemoving }?.setVisible(presentation.isExpanded,
                spec: presentation.isExpanded ? DeneyMotion.contentIn(DeneyMotion.effectiveStyle(model.motionStyle))
                                              : DeneyMotion.contentOut(DeneyMotion.effectiveStyle(model.motionStyle)))
        }
        driver.start()
    }

    // MARK: - İçerik (IslandStateContent karşılığı)

    private func rebuildContent(animated: Bool) {
        let presentation = model.presentation
        let key = ContentKey(presentation, notice: model.notice)
        displayedPresentation = presentation
        displayedTab = presentation.expandedTab
        let style = DeneyMotion.effectiveStyle(model.motionStyle)
        if let current = slots.last(where: { !$0.isRemoving }), current.key == key {
            current.view.refresh()
            return
        }
        for slot in slots where !slot.isRemoving {
            slot.remove(spec: animated ? DeneyMotion.contentOut(style) : nil)
        }
        guard let view = IslandContentFactory.make(key, model: model, environment: environment) else { return }
        let slot = ContentSlot(key: key, view: view, blurs: style != .reduced && !key.isExpanded)
        slots.append(slot)
        contentView.addSubview(view, positioned: .below, relativeTo: media)
        if key.isExpanded {
            // Yüzey hazırlanıp hareket etmeye başlayınca belirir (surfacePresentation genişlediğinde).
            slot.begin(visible: surfacePresentation.isExpanded, animated: false, spec: nil)
        } else {
            slot.begin(visible: true, animated: animated, spec: DeneyMotion.contentIn(style))
        }
        applyFrame()
        driver.start()
    }

    // MARK: - Kare

    private func tick(_ dt: Double) -> Bool {
        width.step(dt); height.step(dt); topRadius.step(dt); bottomRadius.step(dt); topInset.step(dt); relax.step(dt)
        var active = width.isActive || height.isActive || topRadius.isActive || bottomRadius.isActive
            || topInset.isActive || relax.isActive
        active = media.step(dt) || active
        for slot in slots { active = slot.step(dt) || active }
        let finished = slots.filter { $0.isRemoving && $0.isFinished }
        finished.forEach { $0.view.removeFromSuperview() }
        slots.removeAll { slot in finished.contains { $0 === slot } }
        applyFrame()
        return active || !finished.isEmpty
    }

    /// Canlanan değerleri katmanlara uygular (tek CATransaction, örtük animasyon yok).
    private func applyFrame() {
        guard bounds.width > 0 else { return }
        let metrics = model.metrics
        let canvas = bounds.size
        let inset = topInset.value
        let surfaceSize = CGSize(width: width.value, height: height.value)
        let shape = IslandShape(style: metrics.style, topRadius: topRadius.value, bottomRadius: bottomRadius.value)
        let rect = CGRect(x: canvas.width / 2 - surfaceSize.width / 2, y: inset, width: surfaceSize.width, height: surfaceSize.height)
        // SwiftUI yolu y-aşağı koordinatta üretir; görünüm de çevrilmiş (flipped).
        let path = shape.path(in: rect).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceView.shapeLayer.path = path
        maskLayer.path = path
        // Gevşeme: bütün ada (yüzey + içerik) üst kenara sabit küçülür (SwiftUI `scaleEffect(anchor: .top)`).
        let s = CGFloat(relax.value)
        if let root = layer {
            if s == 1 {
                root.sublayerTransform = CATransform3DIdentity
            } else {
                // sublayerTransform katmanın merkezine göre uygulanır; üst kenar (y-aşağıda 0) sabit kalsın.
                let half = bounds.height / 2 * (root.contentsAreFlipped() ? -1 : 1)
                var t = CATransform3DMakeTranslation(0, half, 0)
                t = CATransform3DScale(t, s, s, 1)
                t = CATransform3DTranslate(t, 0, -half, 0)
                root.sublayerTransform = t
            }
        }
        for slot in slots {
            let size = slot.view.fittingFrameSize(canvas: canvas, metrics: metrics)
            slot.view.frame = CGRect(x: (canvas.width - size.width) / 2, y: inset, width: size.width, height: size.height)
            slot.apply()
        }
        media.frame = contentView.bounds
        media.apply(surfaceWidth: surfaceSize.width, canvasWidth: canvas.width, topInset: inset)
        CATransaction.commit()
    }
}

/// İçerik kimliği: SwiftUI'deki `.id(...)` ve `switch presentation` dallarıyla aynı ayrım. `compact(x)` ile `peek(x)`
/// aynı görünümü paylaşır (hover'da içerik değişmez, yalnız yüzey kabarır).
enum ContentKey: Equatable {
    case none
    case compact(CompactActivity)
    case hud
    case unlocked
    case audio(IslandNotice?)
    case notice(IslandNotice)
    case dropTarget
    case expanded

    init(_ presentation: IslandPresentation, notice: IslandNotice?) {
        switch presentation {
        case .idle, .peek(.none): self = .none
        case .compact(let activity), .peek(let activity?): self = .compact(activity)
        case .hud: self = .hud
        case .notice(.unlocked): self = .unlocked
        case .notice(.audioOutput): self = .audio(notice)
        case .notice(let n): self = .notice(n)
        case .dropTarget: self = .dropTarget
        case .expanded: self = .expanded
        }
    }

    var isExpanded: Bool { self == .expanded }
}

/// Durum içeriği görünümlerinin ortak arayüzü.
@MainActor
protocol IslandContentView: NSView {
    /// Görünümün sabit yerleşim boyutu (yüzey onu kırparak açar).
    func fittingFrameSize(canvas: CGSize, metrics: NotchMetrics) -> CGSize
    /// Aynı içerik kimliğinde veriler değişti.
    func refresh()
}

/// Bir içerik görünümünün giriş/çıkış geçişi (`islandReveal`): saydamlık + (Azaltılmış dışında) bulanıklık.
@MainActor
final class ContentSlot {
    let key: ContentKey
    let view: IslandContentView
    let blurs: Bool
    private var progress = Spring(0)
    private(set) var isRemoving = false

    init(key: ContentKey, view: IslandContentView, blurs: Bool) {
        self.key = key
        self.view = view
        self.blurs = blurs
        view.wantsLayer = true
        if blurs, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "reveal"
            blur.setValue(0, forKey: kCIInputRadiusKey)
            view.layer?.filters = [blur]
        }
    }

    var isExpanded: Bool { key.isExpanded }
    var isFinished: Bool { !progress.isActive && progress.value <= 0.001 }

    func begin(visible: Bool, animated: Bool, spec: SpringSpec?) {
        if animated, let spec {
            progress.set(0)
            progress.animate(to: visible ? 1 : 0, spec: spec)
        } else {
            progress.set(visible ? 1 : 0)
        }
    }

    func setVisible(_ visible: Bool, spec: SpringSpec) {
        progress.animate(to: visible ? 1 : 0, spec: spec)
    }

    func remove(spec: SpringSpec?) {
        isRemoving = true
        // Kaldırılan içerik saydamlıkla söner (bulanıklık yalnız girişte; SwiftUI `.opacity` kaldırma geçişi).
        if let filters = view.layer?.filters, !filters.isEmpty { view.layer?.filters = nil }
        if let spec { progress.animate(to: 0, spec: spec) } else { progress.set(0) }
        view.setAccessibilityElement(false)
    }

    func step(_ dt: Double) -> Bool {
        progress.step(dt)
        return progress.isActive
    }

    func apply() {
        let p = max(0, min(1, progress.value))
        view.layer?.opacity = Float(p)
        if blurs, !isRemoving {
            view.layer?.setValue((1 - p) * 6, forKeyPath: "filters.reveal.inputRadius")
        }
        view.isHidden = p <= 0.001 && isRemoving
    }
}

/// y-aşağı koordinatlı düz kap.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Katmanı `CAShapeLayer` olan, y-aşağı koordinatlı görünüm.
final class ShapeView: NSView {
    var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        shapeLayer.actions = IslandCanvasView.noActions
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override var isFlipped: Bool { true }
    override func makeBackingLayer() -> CALayer { CAShapeLayer() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
