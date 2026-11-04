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
    private let contentView = AccessibleContainerView()
    private let media: MediaLayersView

    /// Ekranda çizilen (canlanan) yüzeyin hedefi; SwiftUI'deki `surface` durumunun karşılığı.
    private var surfacePresentation: IslandPresentation
    private var surfaceTransitionFrom: IslandPresentation
    private var lastMotionStyle: MotionStyle
    private var surfaceLayout: IslandLayout
    private var width: Spring, height: Spring, topRadius: Spring, bottomRadius: Spring, topInset: Spring
    private var relax = Spring(1)
    /// A bounded CA trajectory owns only the surface/mask. All native views,
    /// input, panel lifecycle and media ownership stay unchanged.
    private lazy var nativeSurface: NativeSurfaceMotion? = {
        // Explicit developer fallback for controlled A/B, not a benchmark-only
        // path. The normal application uses the same compositor renderer.
        guard ProcessInfo.processInfo.environment["OPENISLAND_APPKIT_SURFACE_CLIENT"] != "1" else { return nil }
        let motion = NativeSurfaceMotion(surface: surfaceView.shapeLayer, mask: maskLayer,
            pose: .init(width: width.value, height: height.value, topRadius: topRadius.value,
                        bottomRadius: bottomRadius.value, topInset: topInset.value, scale: relax.value),
            canvasWidth: bounds.width, style: model.metrics.style)
        motion.onSettled = { [weak self] in self?.compositorDidSettle() }
        return motion
    }()
    private(set) var compositorOnlyMotion = false
    private var hasSurfaceMotion: Bool { driver.isRunning || compositorOnlyMotion }
    private var pendingOpening: DispatchWorkItem?
    /// Hızlı hover'da yüzey açılışa peek sırasında başladı; içerik açılış kesinleşince belirir.
    private var anticipatedOpening = false

    private var slots: [ContentSlot] = []
    private var lastShapeKey: [CGFloat] = []
    var spareExpanded: ExpandedContentView?
    /// Kapanışta sönen açık içerik: kapatma işi (`suspend`) yüzey durunca yapılır (bkz. `tick`).
    private var pendingSuspend: ExpandedContentView?
    /// Uyuyan içerik ön çizim için bir-iki kare görünür (%0,4 opak, kapalı adada kırpılmış): kasıtlıdır.
    private(set) var isWarmingSpare = false
    /// Açılıştan sonraki ilk saniyeler: ön çizim kompakt adadaki canlı etkinliği beklemez (ilk hover önceliklidir).
    private let warmupDeadline = CACurrentMediaTime() + 15
    /// Açık adanın içeriğinin üstünde tek görünüm (ilk kurulum karşılaması); bkz. `presentOverlay`.
    private var overlay: NSView?
    private var onOverlayCollapse: (() -> Void)?
    var didWarmDrawing = false
    /// Sürükleme sırasında etkin bölge (SwiftUI `@State dropZone`).
    var dropZone: DropZone? {
        didSet {
            guard dropZone != oldValue else { return }
            for slot in slots { (slot.view as? DropZoneContentView)?.zone = dropZone }
        }
    }
    private var displayedPresentation: IslandPresentation
    private var displayedTab: ExpandedTab?

    private lazy var driver = FrameDriver(view: self) { [weak self] dt in self?.tick(dt) ?? false }

    init(model: IslandViewModel, environment: AppEnvironment) {
        self.model = model
        self.environment = environment
        let layout = model.layout
        surfacePresentation = model.presentation
        surfaceTransitionFrom = model.presentation
        lastMotionStyle = AppMotion.effectiveStyle(model.motionStyle)
        surfaceLayout = layout
        displayedPresentation = model.presentation
        width = Spring(layout.size.width)
        height = Spring(layout.size.height)
        topRadius = Spring(layout.topCornerRadius)
        bottomRadius = Spring(layout.bottomCornerRadius)
        topInset = Spring(layout.topInset)
        media = MediaLayersView(media: environment.media, preferences: environment.preferences, model: model)
        super.init(frame: .zero)
        media.onNeedsClientFrames = { [weak self] in self?.driveSurfaceMotion() }
        // SwiftUI kökü `.environment(\.colorScheme, .dark)`: barındırılan AppKit denetimleri koyu görünümle çizilir.
        appearance = NSAppearance(named: .darkAqua)
        registerForDraggedTypes(Self.draggedTypes)
        FrameDriver.installRunLoopProbe()
        DisplayProbe.installIfRequested()
        ImageRedrawProbe.install()
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false

        surfaceView.shapeLayer.fillColor = NSColor.black.cgColor
        addSubview(surfaceView)
        maskLayer.fillColor = NSColor.black.cgColor
        maskLayer.actions = Self.noActions

        contentView.wantsLayer = true
        let env = ProcessInfo.processInfo.environment
        contentView.layerUsesCoreImageFilters = env["OPENISLAND_APPKIT_NOBLUR"] == nil
        if env["OPENISLAND_APPKIT_NOMASK"] == nil { contentView.layer?.mask = maskLayer }
        addSubview(contentView)
        contentView.addSubview(media)

        rebuildContent(animated: false)
        observeModel()
        // AX yapısı SwiftUI ile aynı: etiketsiz host grubu → "OpenIsland" kapsayıcısı → içerik öğeleri.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        contentView.setAccessibilityElement(true)
        contentView.setAccessibilityRole(.group)
        contentView.setAccessibilityLabel("OpenIsland")
        contentView.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Genişlet") { [weak model] in
            model?.send(.tapped); return true
        }])
        contentView.onCancel = { [weak model] in model?.send(.escapePressed) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    static let noActions: [String: CAAction] = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(),
                                                 "opacity": NSNull(), "transform": NSNull(), "frame": NSNull(),
                                                 "contents": NSNull(), "hidden": NSNull(), "filters": NSNull()]

    nonisolated override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, spareExpanded == nil { scheduleSpareExpanded(after: 1) } // açılıştan sonra boşta
    }

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
            _ = model.isPinned; _ = model.isRelaxing; _ = model.metrics; _ = model.nativeDropZone; _ = model.motionStyle
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.modelDidChange() } }
        }
    }

    static func anticipatesOpening(_ configuration: IslandConfiguration) -> Bool {
        configuration.expandsOnHover && configuration.hoverExpandDelay <= 0.12
    }

    private func modelDidChange() {
        observeModel()
        let revealsExpanded = model.presentation.isExpanded && !displayedPresentation.isExpanded
        let style = AppMotion.effectiveStyle(model.motionStyle)
        if lastMotionStyle != style {
            lastMotionStyle = style
            if hasSurfaceMotion {
                applySurface(layout: surfaceLayout, presentation: surfacePresentation,
                             spec: AppMotion.morph(from: surfaceTransitionFrom, to: surfacePresentation, style: style))
            }
        }
        if let zone = model.nativeDropZone {
            dropZone = zone == .shelf ? .shelf : .airDrop
        } else if !model.machine.context.isFileDragActive {
            dropZone = nil
        }
        // Hızlı hover (hover ile açılma açık, gecikme ≤ 120 ms): peek, açılış yayının başlangıcıdır. İmleç girer girmez
        // yüzey açık boyuta tek yayla ilerler (Ayarlar önizlemesindeki gibi); açılış kesinleşince içerik belirir, imleç
        // gecikme dolmadan çıkarsa yüzey aynı yaydan geri kapanır. Ayrı peek yayı açılışı "yavaş büyü → fırla" kırığıyla
        // başlatıyordu (gerçek fareyle kare kare ölçüldü, 2 Kasım).
        if case .peek = model.presentation, model.hud == nil, model.notice == nil {
            if anticipatedOpening { return }
            if !surfacePresentation.isExpanded, Self.anticipatesOpening(model.machine.configuration) {
                let tab = model.machine.context.lastTab
                let opening = IslandPresentation.expanded(tab)
                anticipatedOpening = true
                if FrameDriver.isLogging { FrameDriver.note("opening anticipated (fast hover) \(tab)") }
                applySurface(layout: IslandLayoutEngine.layout(for: opening, metrics: model.metrics), presentation: opening,
                             spec: AppMotion.morph(from: surfacePresentation, to: opening, style: AppMotion.effectiveStyle(model.motionStyle)))
                return
            }
        }
        if !model.presentation.isExpanded { anticipatedOpening = false } // gecikme dolmadan çıkıldı: yüzey geri kapanır
        let target = (layout: model.layout, presentation: model.presentation)
        if FrameDriver.isLogging {
            FrameDriver.note("model \(model.presentation) \(Int(model.layout.size.width))x\(Int(model.layout.size.height)) pinned=\(model.isPinned) relax=\(model.isRelaxing) hud=\(model.hud != nil) notice=\(model.notice != nil) content=\(model.metrics.content) hovering=\(model.machine.context.isHovering)")
        }
        let readyOpening = morph(toLayout: target.layout, presentation: target.presentation)
        if model.presentation != displayedPresentation || model.presentation.expandedTab != displayedTab {
            let t0 = CACurrentMediaTime()
            rebuildContent(animated: true)
            if FrameDriver.isLogging { FrameDriver.note(String(format: "rebuildContent %.2f ms", (CACurrentMediaTime() - t0) * 1000)) }
        } else {
            slots.forEach { $0.view.refresh() }
        }
        // A previously displayed, still-attached host needs no run-loop hop.
        // Activate/refresh it first, then start the original spring in this event.
        if let readyOpening, !readyOpening.isCancelled { readyOpening.perform() }
        if let overlay, !model.presentation.isExpanded {
            // Ada kapandı (Esc, kısayol): üst görünüm içerikle birlikte söner, sonra kaldırılır.
            let collapsed = onOverlayCollapse
            self.overlay = nil
            onOverlayCollapse = nil
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.22; overlay.animator().alphaValue = 0 },
                                                 completionHandler: { MainActor.assumeIsolated { overlay.removeFromSuperview() } })
            collapsed?()
        }
        let relaxTarget = model.isRelaxing ? Double(AppMotion.relaxScale) : 1
        if relax.target != relaxTarget {
            let spec = style == .reduced ? AppMotion.reduced : AppMotion.relax
            nativeSurface?.relax(to: relaxTarget, spec: spec)
            relax.animate(to: relaxTarget, spec: spec)
            driveSurfaceMotion()
        }
        // A warmed host is unhidden in this event. Submit its reveal together
        // with the outline before another main-queue task can block the next
        // implicit run-loop commit. Once per opening, never once per frame.
        if revealsExpanded, nativeSurface?.ownsPath == true { CATransaction.flush() }
    }

    // MARK: - Yüzey morph'u (IslandRootView.morph ile aynı mantık)

    private func morph(toLayout layout: IslandLayout, presentation: IslandPresentation) -> DispatchWorkItem? {
        guard layout != surfaceLayout || presentation != surfacePresentation else { return nil }
        pendingOpening?.cancel()
        pendingOpening = nil
        let style = AppMotion.effectiveStyle(model.motionStyle)
        if presentation.isExpanded && surfacePresentation.isExpanded {
            if layout == surfaceLayout {
                surfacePresentation = presentation
            } else {
                applySurface(layout: layout, presentation: presentation, spec: AppMotion.resize(style: style))
            }
            return nil
        }
        let spec = AppMotion.morph(from: surfacePresentation, to: presentation, style: style)
        // Already displayed content can start in this input event after refresh,
        // but only while its host is still attached. A new host keeps its first
        // presented-frame preparation, so no cold texture draw interrupts motion.
        let contentIsDrawn = spareExpanded?.hasBeenShown == true || slots.contains { $0.isExpanded && $0.isRemoving }
        if presentation.isExpanded && !surfacePresentation.isExpanded && contentIsDrawn {
            let work = DispatchWorkItem { [weak self] in
                if FrameDriver.isLogging { FrameDriver.note("opening spring start (drawn content)") }
                self?.applySurface(layout: layout, presentation: presentation, spec: spec)
                self?.pendingOpening = nil
            }
            pendingOpening = work
            let attached = window != nil && (spareExpanded?.window === window || slots.contains { $0.isExpanded && $0.isRemoving && $0.view.window === window })
            if attached { return work }
            DispatchQueue.main.async(execute: work)
        } else if presentation.isExpanded && !surfacePresentation.isExpanded {
            // Önce hedef içerik kurulup yerleşir ve ilk karesi ekrana çıkar (katman dokuları render sunucusuna yüklenir),
            // sonra taze bir yay saati başlar. SwiftUI'de de ağır ilk çizim hareketten önce biter; hareket kesintisiz.
            let work = DispatchWorkItem { [weak self] in
                if FrameDriver.isLogging { FrameDriver.note("opening spring start") }
                self?.applySurface(layout: layout, presentation: presentation, spec: spec)
                self?.pendingOpening = nil
            }
            pendingOpening = work
            FrameDriver.afterPresentedFrame(of: self) { if !work.isCancelled { work.perform() } }
        } else {
            applySurface(layout: layout, presentation: presentation, spec: spec)
        }
        return nil
    }

    private func applySurface(layout: IslandLayout, presentation: IslandPresentation, spec: SpringSpec) {
        let wasExpanded = surfacePresentation.isExpanded
        if surfaceLayout != layout || surfacePresentation != presentation { surfaceTransitionFrom = surfacePresentation }
        surfaceLayout = layout
        surfacePresentation = presentation
        nativeSurface?.update(canvasWidth: bounds.width, style: model.metrics.style)
        nativeSurface?.morph(to: .init(width: layout.size.width, height: layout.size.height,
                                     topRadius: layout.topCornerRadius, bottomRadius: layout.bottomCornerRadius,
                                     topInset: layout.topInset, scale: relax.target), spec: spec)
        width.animate(to: layout.size.width, spec: spec)
        height.animate(to: layout.size.height, spec: spec)
        topRadius.animate(to: layout.topCornerRadius, spec: spec)
        bottomRadius.animate(to: layout.bottomCornerRadius, spec: spec)
        topInset.animate(to: layout.topInset, spec: spec)
        media.retarget(presentation: presentation, metrics: model.metrics, spec: spec, style: AppMotion.effectiveStyle(model.motionStyle))
        if wasExpanded != presentation.isExpanded {
            slots.first { $0.isExpanded && !$0.isRemoving }?.setVisible(presentation.isExpanded,
                spec: presentation.isExpanded ? AppMotion.contentIn(AppMotion.effectiveStyle(model.motionStyle))
                                              : AppMotion.contentOut(AppMotion.effectiveStyle(model.motionStyle)))
        }
        driveSurfaceMotion()
    }

    // MARK: - İçerik (IslandStateContent karşılığı)

    private func rebuildContent(animated: Bool) {
        let presentation = model.presentation
        let key = ContentKey(presentation, notice: model.notice)
        displayedPresentation = presentation
        displayedTab = presentation.expandedTab
        let style = AppMotion.effectiveStyle(model.motionStyle)
        if let current = slots.last(where: { !$0.isRemoving }), current.key == key {
            current.view.refresh()
            return
        }
        for slot in slots where !slot.isRemoving {
            slot.remove(spec: animated ? AppMotion.contentOut(style) : nil)
        }
        // Kapanış geçişi bitmeden yeniden açılırsa aynı içerik geri döner (SwiftUI'de görünüm geçiş bitince kalkar).
        if key == .expanded, let removing = slots.last(where: { $0.isExpanded && $0.isRemoving }) {
            for slot in slots where !slot.isRemoving { slot.remove(spec: animated ? AppMotion.contentOut(style) : nil) }
            // Fast hover may already have retargeted the surface during peek.
            // In that case applySurface will not run again after revival: the
            // outgoing content must reverse its own fade here, not stay at 0.
            removing.revive(spec: surfacePresentation.isExpanded ? AppMotion.contentIn(style) : nil)
            anticipatedOpening = false
            slots.removeAll { $0 === removing }
            slots.append(removing)
            removing.view.refresh() // saydamlık bulunduğu yerden açılış yayıyla geri gelir (applySurface → setVisible)
            applyFrame()
            driveSurfaceMotion()
            return
        }
        let spare = key == .expanded ? takeSpareExpanded() : nil
        guard let view = spare ?? IslandContentFactory.make(key, model: model, environment: environment) else { return }
        let slot = ContentSlot(key: key, view: view, blurs: style != .reduced && !key.isExpanded)
        slot.onRemovalFinished = { [weak self] in
            guard let self, self.compositorOnlyMotion else { return }
            // The host must leave hit-testing/focus at its fade's end, not at
            // the longer outline spring's end. One event replaces frame polls;
            // panel suspension still waits for the outline to settle.
            self.synchronizeNativeGeometry()
            _ = self.tick(0)
        }
        slots.append(slot)
        (view as? DropZoneContentView)?.zone = dropZone
        if view.superview === contentView {
            // Reorder without unlinking the cached host from its window. A
            // remove/add cycle invalidates the entire native drawing subtree.
            var order = contentView.subviews.filter { $0 !== view }
            order.insert(view, at: order.firstIndex(where: { $0 === media }) ?? order.count)
            var ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { (ObjectIdentifier($0.element), $0.offset) })
            withUnsafeMutablePointer(to: &ranks) { context in
                contentView.sortSubviews({ a, b, context in
                    let ranks = context!.assumingMemoryBound(to: [ObjectIdentifier: Int].self).pointee
                    let a = ranks[ObjectIdentifier(a)]!, b = ranks[ObjectIdentifier(b)]!
                    return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
                }, context: context)
            }
        } else {
            contentView.addSubview(view, positioned: .below, relativeTo: media)
        }
        spare?.activate()
        if key.isExpanded, anticipatedOpening {
            // Yüzey peek'ten beri açılıyor: içerik şimdi, açılış yayının giriş eğrisiyle belirir.
            anticipatedOpening = false
            slot.begin(visible: false, animated: false, spec: nil)
            slot.setVisible(true, spec: AppMotion.contentIn(style))
        } else if key.isExpanded {
            // Yüzey hazırlanıp hareket etmeye başlayınca belirir (surfacePresentation genişlediğinde).
            slot.begin(visible: surfacePresentation.isExpanded, animated: false, spec: nil)
        } else {
            slot.begin(visible: true, animated: animated, spec: AppMotion.contentIn(style))
        }
        applyFrame()
        driveSurfaceMotion()
    }

    // MARK: - Kare

    /// Do not run a second, client-side frame loop for a surface and reveal
    /// already owned by CA. Media, blur/HUD, moving host insets and invisible
    /// windows retain the original full-rate client renderer.
    private func driveSurfaceMotion() {
        let previous = compositorOnlyMotion
        let native = nativeSurface
        let canOffload = ProcessInfo.processInfo.environment["OPENISLAND_APPKIT_CLIENT_TICKS"] != "1"
            && native?.ownsPath == true && window?.isVisible == true
            && model.metrics.style == .notch && topInset.value == topInset.target
            && overlay == nil && !media.requiresClientFrames
            && slots.allSatisfy { $0.isExpanded && (!$0.isRemoving || $0.revealDeadline <= (native?.completionDeadline ?? 0)) }
        if canOffload || previous { synchronizeNativeGeometry() }
        compositorOnlyMotion = canOffload
        if canOffload {
            driver.stop()
            // An event may arrive after the last CA completion has already
            // fired (e.g. a media preference change while idle). Do not leave
            // the warmup/cleanup ownership flag waiting for a past completion.
            if (native?.completionDeadline ?? 0) <= CACurrentMediaTime() { compositorDidSettle() }
        } else { driver.start() }
    }

    private func synchronizeNativeGeometry() {
        guard let state = nativeSurface?.snapshot(at: CACurrentMediaTime()) else { return }
        width = state.width; height = state.height; topRadius = state.topRadius
        bottomRadius = state.bottomRadius; topInset = state.topInset; relax = state.scale
    }

    private func compositorDidSettle() {
        guard compositorOnlyMotion else { return }
        guard nativeSurface?.ownsPath == true else { driveSurfaceMotion(); return }
        synchronizeNativeGeometry()
        compositorOnlyMotion = false
        _ = tick(0) // settle slot clocks and park the outgoing host once
        if pendingSuspend != nil { _ = tick(0) } // original deferred cleanup, no extra display link
    }

    private func tick(_ dt: Double) -> Bool {
        width.step(dt); height.step(dt); topRadius.step(dt); bottomRadius.step(dt); topInset.step(dt); relax.step(dt)
        var surface = width.isActive || height.isActive || topRadius.isActive || bottomRadius.isActive
            || topInset.isActive || relax.isActive
        for slot in slots { surface = slot.step(dt) || surface }
        let mediaActive = media.step(dt)
        let finished = slots.filter { $0.isRemoving && $0.isFinished }
        for slot in finished {
            if slot.isExpanded, spareExpanded == nil, let view = slot.view as? ExpandedContentView {
                // Keep the already retained cache attached: hiding excludes it
                // from mouse/keyboard/AX navigation while preserving its layers.
                // Kapatma işi (panellerin `didHide`'ı, gözlemlerin durması, geçici durum sıfırlama) bu karede
                // yapılmaz: kapanış hareketi sürerken karenin işlenmesini geciktiriyordu (Instruments: kapanışın
                // ~60 ms'sinde tek kare takılma). Yüzey durunca, son kare sunulduktan sonra çalışır.
                view.isHidden = true
                spareExpanded = view
                pendingSuspend = view
            } else {
                slot.view.removeFromSuperview()
            }
        }
        slots.removeAll { slot in finished.contains { $0 === slot } }
        applyFrame()
        // Müzik nabzı kanatta sürekli canlanabilir: kapatma işi yalnız yüzeyin durmasını bekler.
        if !surface, finished.isEmpty, let view = pendingSuspend {
            pendingSuspend = nil
            DispatchQueue.main.async { [weak self, weak view] in
                MainActor.assumeIsolated {
                    guard let self, let view, self.spareExpanded === view, view.isHidden else { return }
                    view.suspend()
                    self.scheduleSparePanelWarmup(after: 1) // açılış yarıda kaldıysa kurulmamış paneller
                }
            }
        }
        return surface || mediaActive || !finished.isEmpty
    }

    /// Canlanan değerleri katmanlara uygular (tek CATransaction, örtük animasyon yok).
    private func applyFrame() {
        guard bounds.width > 0 else { return }
        let metrics = model.metrics
        let canvas = bounds.size
        let inset = topInset.value
        let surfaceSize = CGSize(width: width.value, height: height.value)
        // Gevşeme (SwiftUI `scaleEffect(anchor: .top)`): yalnız yüzey şekli ve içerik maskesi tuvalin üst ortasına sabit
        // küçülür. Önceden kök katmana `sublayerTransform` uygulanıyordu; ölçek her karede değişince AppKit bütün
        // panellerdeki simge/resim görünümlerini her karede yeniden çiziyordu (kapanışta ~0,55 sn boyunca karede 34+
        // görüntü; gerçek veriyle kare hazırlığı 22–39 ms, kapanışta kare atlama — 2 Kasım, Instruments + çizim sayacı).
        // İçerik ölçeklenmez; aynı maskeyle kırpıldığı için %0,6'lık fark görünmez.
        let s = CGFloat(relax.value)
        let shape = IslandShape(style: metrics.style, topRadius: topRadius.value * s, bottomRadius: bottomRadius.value * s)
        let rect = CGRect(x: canvas.width / 2 - surfaceSize.width * s / 2, y: inset * s,
                          width: surfaceSize.width * s, height: surfaceSize.height * s)
        if FrameDriver.isLogging { FrameDriver.note(String(format: "geo w=%.2f h=%.2f", surfaceSize.width, surfaceSize.height)) }
        // SwiftUI yolu y-aşağı koordinatta üretir; görünüm de çevrilmiş (flipped).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Yalnız değişince yazılır: aynı yolu yeniden atamak bile katmanı kirletir; maske yolu değişince maskelenen
        // bütün içerik pencere sunucusunda ekran dışında yeniden birleştirilir.
        let shapeKey: [CGFloat] = [rect.minX, rect.minY, rect.width, rect.height, CGFloat(topRadius.value) * s, CGFloat(bottomRadius.value) * s, metrics.style == .notch ? 1 : 0]
        nativeSurface?.update(canvasWidth: canvas.width, style: metrics.style)
        if nativeSurface?.ownsPath != true, shapeKey != lastShapeKey {
            lastShapeKey = shapeKey
            let path = shape.path(in: rect).cgPath
            surfaceView.shapeLayer.path = path
            maskLayer.path = path
        }
        if let root = layer, !CATransform3DIsIdentity(root.sublayerTransform) { root.sublayerTransform = CATransform3DIdentity }
        for slot in slots {
            let size = slot.view.fittingFrameSize(canvas: canvas, metrics: metrics)
            let frame = CGRect(x: (canvas.width - size.width) / 2, y: inset, width: size.width, height: size.height)
            if slot.view.frame != frame { slot.view.frame = frame }
            slot.apply()
        }
        if media.frame != contentView.bounds { media.frame = contentView.bounds }
        if let overlay {
            // Hedef açık yüzeyin dikdörtgeni: ada maskesi açılırken görünümü kademeli ortaya çıkarır.
            let target = model.presentation.isExpanded ? model.layout : surfaceLayout
            let frame = CGRect(x: (canvas.width - target.size.width) / 2, y: target.topInset,
                               width: target.size.width, height: target.size.height)
            if overlay.frame != frame { overlay.frame = frame }
        }
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
    static let revealAnimationKey = "OpenIsland.content.reveal"
    let key: ContentKey
    let view: IslandContentView
    let blurs: Bool
    private var progress = Spring(0)
    private var progressStamp = CACurrentMediaTime()
    private let nativeOpacity: Bool
    private(set) var revealDeadline: CFTimeInterval = 0
    var onRemovalFinished: (@MainActor () -> Void)?
    private var revealGeneration: UInt64 = 0
    private(set) var isRemoving = false

    init(key: ContentKey, view: IslandContentView, blurs: Bool) {
        self.key = key
        self.view = view
        self.blurs = blurs
        nativeOpacity = key.isExpanded && !blurs
            && ProcessInfo.processInfo.environment["OPENISLAND_APPKIT_SURFACE_CLIENT"] != "1"
        view.wantsLayer = true
    }

    var isExpanded: Bool { key.isExpanded }
    var isFinished: Bool { !progress.isActive && progress.value <= 0.001 }

    func begin(visible: Bool, animated: Bool, spec: SpringSpec?) {
        progressStamp = CACurrentMediaTime()
        if animated, let spec {
            progress.set(0)
            progress.animate(to: visible ? 1 : 0, spec: spec)
        } else {
            progress.set(visible ? 1 : 0)
        }
        if nativeOpacity { publishOpacity() }
    }

    func setVisible(_ visible: Bool, spec: SpringSpec) {
        if nativeOpacity { synchronizeProgress() }
        progress.animate(to: visible ? 1 : 0, spec: spec)
        if nativeOpacity { publishOpacity() }
    }

    /// Kaldırma geçişini iptal eder (yeniden açılış).
    func revive(spec: SpringSpec? = nil) {
        isRemoving = false
        view.isHidden = false
        if let spec { setVisible(true, spec: spec) }
    }

    func remove(spec: SpringSpec?) {
        if nativeOpacity { synchronizeProgress() }
        isRemoving = true
        // Kaldırılan içerik saydamlıkla söner (bulanıklık yalnız girişte; SwiftUI `.opacity` kaldırma geçişi).
        RevealBlur.apply(radius: 0, to: view.layer)
        if let spec { progress.animate(to: 0, spec: spec) } else { progress.set(0) }
        if nativeOpacity { publishOpacity() }
        view.setAccessibilityElement(false)
    }

    func step(_ dt: Double) -> Bool {
        if nativeOpacity { synchronizeProgress() } else { progress.step(dt) }
        return progress.isActive
    }

    private func synchronizeProgress() {
        let now = CACurrentMediaTime()
        progress.step(max(0, now - progressStamp)); progressStamp = now
    }

    /// Expanded content has no reveal blur. Its exact delayed spring can be
    /// submitted once, so a busy main thread cannot freeze the fade while the
    /// compositor continues opening the shell. Logical lifetime stays local.
    private func publishOpacity() {
        guard let layer = view.layer else { return }
        let floor: Double = isRemoving ? 0 : 0.004
        func opacity(_ value: Double) -> NSNumber { NSNumber(value: max(floor, min(1, value))) }
        var future = progress
        var values = [opacity(future.value)]
        var times = [0.0]
        let dt = 1.0 / 240
        var elapsed = 0.0
        while future.isActive && elapsed < 4 {
            future.step(dt); elapsed += dt
            values.append(opacity(future.value)); times.append(elapsed)
        }
        revealDeadline = progressStamp + elapsed
        revealGeneration &+= 1
        let submittedGeneration = revealGeneration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revealGeneration == submittedGeneration, self.isRemoving else { return }
                self.onRemovalFinished?()
            }
        }
        defer { CATransaction.commit() }
        layer.opacity = values.last!.floatValue
        guard values.count > 1 else {
            layer.removeAnimation(forKey: Self.revealAnimationKey)
            return
        }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.keyTimes = times.map { NSNumber(value: $0 / elapsed) }
        animation.duration = elapsed
        animation.beginTime = layer.convertTime(progressStamp, from: nil)
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: Self.revealAnimationKey)
    }

    func apply() {
        let p = max(0, min(1, progress.value))
        // Açılacak genişletilmiş içerik görünmeden önce de çok düşük opaklıkla birleştirilir (%0,4, göz ayırt etmez):
        // ilk doku yüklemesi yüzey hareketinden önce olur, hareketin ortasında kare kaçmaz.
        let opacity = Float(isExpanded && !isRemoving ? max(p, 0.004) : p)
        if !nativeOpacity, let layer = view.layer, layer.opacity != opacity { layer.opacity = opacity }
        if blurs, !isRemoving { RevealBlur.apply(radius: (1 - p) * 6, to: view.layer) }
        let hidden = p <= 0.001 && isRemoving
        if view.isHidden != hidden { view.isHidden = hidden }
    }
}

/// y-aşağı koordinatlı düz kap.
class FlippedView: NSView {
    /// `nonisolated`: AppKit bunu her koordinat dönüşümünde sorar; ana aktöre bağlı @objc köprüsü her çağrıda çalışma
    /// zamanı yürütücü denetimi yapıyordu (sekme geçişinde uygulama CPU'sunun ~%3'ü).
    nonisolated override var isFlipped: Bool { true }
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

    nonisolated override var isFlipped: Bool { true }
    override func makeBackingLayer() -> CALayer { CAShapeLayer() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// "OpenIsland" kapsayıcısı: Escape (AXCancel) eylemini taşır.
final class AccessibleContainerView: FlippedView {
    var onCancel: (() -> Void)?
    override func accessibilityPerformCancel() -> Bool { onCancel?(); return onCancel != nil }

    /// SwiftUI'de sütunlu paneller (`PanelAXOrder`) VoiceOver'da sütun sütun okunur; AppKit'te VoiceOver düz kapsayıcıyı
    /// geometrik (satır satır) gezer ve sütunları karıştırır. Görünür panel öncelik veriyorsa gezinme sırası SwiftUI ile aynı
    /// kurulur: panel dışı öğeler (başlık) özgün sırada, sonra panel öğeleri öncelik (yüksek önce) ve her grup içinde
    /// geometrik sırada (üstten alta, soldan sağa). Öncelik vermeyen panellerde nil: VoiceOver'ın varsayılan sırası.
    override func accessibilityChildrenInNavigationOrder() -> [NSAccessibilityElementProtocol]? {
        guard let children = accessibilityChildren(), !children.isEmpty else { return nil }
        func view(of element: Any) -> NSView? {
            var current: Any? = element
            for _ in 0..<12 {
                if let view = current as? NSView { return view }
                if let cell = current as? NSCell, let control = cell.controlView { return control } // sürgü, açılır düğme
                current = (current as? NSAccessibilityElementProtocol)?.accessibilityParent()
            }
            return nil
        }
        var leading: [NSAccessibilityElementProtocol] = []
        var ranked: [(rank: Int, top: CGFloat, x: CGFloat, element: NSAccessibilityElementProtocol)] = []
        for case let child as NSAccessibilityElementProtocol in children {
            guard let v = view(of: child) else { leading.append(child); continue }
            var ancestor: NSView? = v
            var panel: IslandPanel?
            while let a = ancestor { if let p = a as? IslandPanel { panel = p; break }; ancestor = a.superview }
            guard let panel, let rank = panel.axNavigationRank(of: v) else { leading.append(child); continue }
            let frame = child.accessibilityFrame()
            ranked.append((rank, (frame.maxY / 4).rounded(), frame.minX, child))
        }
        guard !ranked.isEmpty else { return nil }
        ranked.sort { a, b in a.rank != b.rank ? a.rank > b.rank : (a.top != b.top ? a.top > b.top : a.x < b.x) }
        return leading + ranked.map(\.element)
    }
}

// MARK: - Sürükle-bırak

/// Adanın tek bırakma hedefi (SwiftUI `IslandDropDelegate` ile aynı akış): giriş/çıkış durum makinesine gider, bırakma
/// hedefi görünümünde sol yarı Raf, sağ yarı AirDrop'tur; bölge değişimi `IslandMotion.control` ile canlanır (kutucuk).
/// Global fare izleyicisi yok: sürükleme pencereye girdiğinde sistem çağırır.
extension IslandCanvasView {
    static let draggedTypes: [NSPasteboard.PasteboardType] = {
        var utis: [String] = ShelfStore.acceptedTypes.map { $0.identifier }
        utis += ["public.png", "public.tiff", "public.jpeg", "public.heic", "com.adobe.pdf", "public.utf8-plain-text", "public.html", "public.rtf"]
        utis += NSFilePromiseReceiver.readableDraggedTypes
        return utis.map { NSPasteboard.PasteboardType($0) }
    }()

    private func accepts(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadItem(withDataConformingToTypes: ShelfStore.acceptedTypes.map { $0.identifier })
            || info.draggingPasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    private func zone(at info: NSDraggingInfo) -> DropZone {
        guard model.presentation == .dropTarget else { return .shelf }
        let location = convert(info.draggingLocation, from: nil)
        return location.x < IslandLayoutEngine.canvasSize(for: model.metrics).width / 2 ? .shelf : .airDrop
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        model.send(.fileDragEntered)
        dropZone = zone(at: sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        let current = zone(at: sender)
        if current != dropZone { dropZone = current }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard dropZone != nil else { return }
        dropZone = nil
        model.send(.fileDragExited)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let target = zone(at: sender)
        let pasteboard = sender.draggingPasteboard
        dropZone = nil
        let shelf = environment.shelf
        let providers = Self.itemProviders(from: pasteboard)
        if target == .airDrop {
            ShelfStore.loadFileURLs(from: providers) { urls in shelf.airDrop(urls) }
            model.send(.fileDragEnded(dropped: false))
            return true
        }
        // Dosya vaadi (Fotoğraflar, Mail) yalnız AppKit panosundan alınabilir; geri kalan SwiftUI'deki gibi sağlayıcılarla.
        let accepted: Bool
        if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil),
           !pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            accepted = shelf.ingest(pasteboard: pasteboard)
        } else {
            accepted = shelf.ingest(providers)
        }
        model.send(.fileDragEnded(dropped: accepted))
        return accepted
    }

    /// Pano öğelerinden `NSItemProvider` (SwiftUI `DropInfo.itemProviders` karşılığı): her tür, veri isteğe bağlı okunur.
    static func itemProviders(from pasteboard: NSPasteboard) -> [NSItemProvider] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let provider = NSItemProvider()
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            if let url = item.string(forType: .fileURL).flatMap(URL.init(string:)) { provider.suggestedName = url.lastPathComponent }
            return provider
        }
    }
}

// MARK: - Açık adanın üstündeki görünüm

extension IslandCanvasView {
    /// İlk kurulum karşılaması gibi tek bir görünümü açık adanın içeriğinin üstüne koyar: ada maskesiyle kırpılır,
    /// yüzeyle birlikte açılır. Ada kapanırsa görünüm söner, kaldırılır ve `onCollapse` çağrılır.
    func presentOverlay(_ view: NSView, onCollapse: @escaping () -> Void) {
        dismissOverlay()
        overlay = view
        onOverlayCollapse = onCollapse
        contentView.addSubview(view)
        applyFrame()
        driveSurfaceMotion()
    }

    func dismissOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
        onOverlayCollapse = nil
        if compositorOnlyMotion { driveSurfaceMotion() }
    }
}

// MARK: - Önceden kurulan genişletilmiş içerik

extension IslandCanvasView {
    /// Ada kapalıyken boşta bir sonraki açılışın içeriğini uyku halinde kurar (SwiftUI'deki gibi her açılış yeni bir
    /// görünümle başlar; yalnız kurulum maliyeti açılış anından alınır). İlk kurulum ekran dışı bir kez çizilerek yazı
    /// tipi/sembol önbellekleri ısıtılır.
    func scheduleSpareExpanded(after delay: Double = 0.35) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.prepareSpareExpanded() }
        }
    }

    private func prepareSpareExpanded() {
        guard spareExpanded == nil, window != nil, !model.presentation.isExpanded, !hasSurfaceMotion else {
            if spareExpanded == nil, window != nil, !model.presentation.isExpanded { scheduleSpareExpanded(after: 0.25) }
            return
        }
        let t0 = CACurrentMediaTime()
        let view = ExpandedContentView(model: model, environment: environment, dormant: true)
        let canvas = bounds.size
        // Açılışta `applyFrame`'in vereceği çerçeve: yeniden kullanımda katmanlar yeniden boyutlanıp çizilmez.
        let size = view.fittingFrameSize(canvas: canvas, metrics: model.metrics)
        view.frame = CGRect(x: (canvas.width - size.width) / 2, y: topInset.value, width: size.width, height: size.height)
        view.layoutSubtreeIfNeeded()
        if !didWarmDrawing, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep) // önbellek ısıtma; sonuç kullanılmaz
            didWarmDrawing = true
        }
        spareExpanded = view
        if FrameDriver.isLogging { FrameDriver.note(String(format: "spare expanded ready %.2f ms", (CACurrentMediaTime() - t0) * 1000)) }
        presentSpare(view) { [weak self] in self?.scheduleSparePanelWarmup(after: 0.2) }
    }

    /// Uyku hâlindeki içeriği pencerede bir kez, göz ayırt etmeyecek opaklıkla (%0,4; bkz. `ContentSlot.apply`)
    /// birleştirir: katman dokuları kullanıcı adaya gelmeden önce çizilir, ilk hover açılışı da önceden çizilmiş içerikle
    /// hemen başlar. Ada maskesi içeriği kapalı yüzeyle sınırlar. İki sunulan kareden sonra görünüm yeniden gizlenir;
    /// bu arada açılış başlarsa (`takeSpareExpanded`) görünüm açılışa devredilir ve burada dokunulmaz.
    private func presentSpare(_ view: ExpandedContentView, then next: @escaping @MainActor () -> Void) {
        isWarmingSpare = true
        view.wantsLayer = true
        if view.superview !== contentView { contentView.addSubview(view, positioned: .below, relativeTo: media) }
        view.layer?.opacity = 0.004
        view.isHidden = false
        FrameDriver.afterPresentedFrame(of: self) { [weak self, weak view] in
            self?.isWarmingSpare = false
            guard let self, let view, self.spareExpanded === view else { return }
            view.isHidden = true
            view.layer?.opacity = 0
            view.endPanelPrewarm()
            view.markPresented()
            next()
        }
    }

    /// Diğer sekmelerin panelleri boşta, her seferinde bir tane kurulup çizilir (ada kapalı ve hareketsizken).
    /// Böylece bir sekmeye ilk geçiş ya da başka sekmede açılış da soğuk kurulum/çizim beklemez.
    func scheduleSparePanelWarmup(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.warmNextSparePanel() }
        }
    }

    private func warmNextSparePanel() {
        guard let spare = spareExpanded, spare.isDormant, spare.hasBeenShown, spare.hasUnbuiltPanels, window != nil else { return }
        guard !model.machine.isEngaged, !model.presentation.isExpanded, !hasSurfaceMotion else {
            scheduleSparePanelWarmup(after: 0.5)
            return
        }
        // Açılış penceresinden sonra kompakt adada canlı etkinlik (müzik nabzı) varken ağır bir birleştirme nabızda
        // tek kare kaçırabilir: ada boşta kalana kadar beklenir. Kurulmamış panel ilk ziyarette çizilir.
        guard model.presentation == .idle || CACurrentMediaTime() < warmupDeadline else {
            scheduleSparePanelWarmup(after: 2)
            return
        }
        let t0 = CACurrentMediaTime()
        guard let tab = spare.prewarmNextPanel() else { return }
        if FrameDriver.isLogging { FrameDriver.note(String(format: "panel prewarm %@ %.2f ms", "\(tab)", (CACurrentMediaTime() - t0) * 1000)) }
        presentSpare(spare) { [weak self] in self?.scheduleSparePanelWarmup(after: 0.15) }
    }

    func takeSpareExpanded() -> ExpandedContentView? {
        defer { spareExpanded = nil }
        if pendingSuspend === spareExpanded { pendingSuspend = nil } // kapatma işi yapılmadan yeniden açıldı
        return spareExpanded
    }
}
