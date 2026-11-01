import AppKit
import IslandCore

/// Genişletilmiş ada (SwiftUI `ExpandedIslandView`): çentiğin iki yanında sekmeler + sekme içeriği.
///
/// Paneller sekme başına bir kez kurulur ve aynı açık oturum boyunca pencerede kalır; seçili olmayan panel gizlenir.
/// SwiftUI'deki `onAppear/onDisappear` anlamı panelin kendi `didShow/didHide` çağrılarıyla korunur (örnekleme,
/// konum izleme vb. yalnız panel görünürken). Ada kapanınca host gizlenip uyutulur; geçici etkileşim durumu sıfırlanır.
///
/// Açılışta kurulum/çizim donması olmasın diye bir sonraki açılışın görünümü ada kapalıyken **uyku halinde** önceden
/// kurulur (`dormant`): panel yerleşir ama `didShow` çağrılmaz, gözlem/örnekleme başlamaz; `activate()` açılış anında
/// SwiftUI'deki `onAppear` ile aynı noktada çağrılır.
@MainActor
final class ExpandedContentView: FlippedView, IslandContentView {
    private let model: IslandViewModel
    private let environment: AppEnvironment
    private let header: HeaderView
    private var panels: [ExpandedTab: PanelContainer] = [:]
    private var activeTab: ExpandedTab?
    private let banner: BannerHostView
    private(set) var isDormant: Bool
    /// Bir kez pencerede gösterildi (katmanları çizili): yeniden kullanımda ilk kare beklenmez.
    private(set) var hasBeenShown = false

    init(model: IslandViewModel, environment: AppEnvironment, dormant: Bool = false) {
        self.model = model
        self.environment = environment
        isDormant = dormant
        header = HeaderView(model: model, environment: environment)
        banner = BannerHostView(model: model)
        super.init(frame: .zero)
        addSubview(header)
        addSubview(banner)
        setAccessibilityElement(false)
        if dormant {
            prepare(model.machine.context.lastTab)
        } else {
            refresh()
        }
    }

    /// Önceden kurulmuş görünümü açılış anında devreye alır (panelin `didShow`'u burada).
    func activate() {
        guard isDormant else { return }
        isDormant = false
        defer { hasBeenShown = true }
        let t0 = CACurrentMediaTime()
        refresh()
        let t1 = CACurrentMediaTime()
        if let tab = activeTab { panels[tab]?.fadeIn(duration: 0) }
        if FrameDriver.isLogging {
            FrameDriver.note(String(format: "activate refresh %.2f ms, didShow %.2f ms", (t1 - t0) * 1000, (CACurrentMediaTime() - t1) * 1000))
        }
    }

    /// Kapanış geçişi bitince: panelin `onDisappear`'ı (`didHide`) çalışır, geçici arayüz durumu (kaydırma konumu,
    /// hover, odak) SwiftUI'deki yeni görünüm gibi sıfırlanır; görünüm katmanlarıyla birlikte saklanır ve bir sonraki
    /// açılışta `activate()` ile `onAppear` noktasında yeniden çalışır. Kurulum ve ilk çizim maliyeti tekrar ödenmez.
    func suspend() {
        guard !isDormant else { return }
        isDormant = true
        hasBeenShown = true
        panels.values.forEach { $0.suspend() }
        Self.resetTransientState(in: self)
    }

    private static func resetTransientState(in view: NSView) {
        if let resettable = view as? TransientStateResettable { resettable.resetTransientState() }
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            let origin = NSPoint(x: 0, y: document.isFlipped ? 0 : max(document.bounds.height - scroll.contentView.bounds.height, 0))
            if scroll.contentView.bounds.origin != origin {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        if let text = view as? NSTextView, text.window?.firstResponder === text { text.window?.makeFirstResponder(nil) }
        view.subviews.forEach { resetTransientState(in: $0) }
    }

    /// Uyku halinde kurulum: başlık ve son sekmenin paneli yerleşir; panel görünür ama çalışmaz.
    private func prepare(_ tab: ExpandedTab) {
        header.refresh()
        activeTab = tab
        let container = PanelContainer(panel: PanelFactory.make(tab, model: model, environment: environment))
        panels[tab] = container
        addSubview(container, positioned: .below, relativeTo: banner)
        container.panel.prewarm()
        container.prepare()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    deinit {
        MainActor.assumeIsolated { panels.values.forEach { $0.suspend() } }
    }

    /// Yükseklik sekmeden bağımsız (bütün sekmelerin en büyüğü): çocukların yerleşimi yalnız genişliğe bağlı ve görünüm
    /// AX öğesi değil. Sekmeye göre değişen yükseklik her seçimde `setFrameSize` ile bütün alt ağacın izleme alanlarını ve
    /// görünür alanını geçersiz kılıyordu. Ölçüldü (80 ms, A/B/B/A): talimat/seçim −%20, uygulama CPU'su −%13…18. Görünen
    /// alan ada maskesiyle sınırlı; ekran görüntüsü, AX çerçeveleri ve AX isabet ızgarası 8 sekmede aynı.
    func fittingFrameSize(canvas: CGSize, metrics: NotchMetrics) -> CGSize {
        guard let tab = model.presentation.expandedTab ?? activeTab else { return .zero }
        let layout = IslandLayoutEngine.layout(for: .expanded(tab), metrics: metrics)
        if tallestMetrics != metrics {
            tallestMetrics = metrics
            tallestHeight = ExpandedTab.allCases.map { IslandLayoutEngine.layout(for: .expanded($0), metrics: metrics).size.height }.max() ?? 0
        }
        return CGSize(width: max(canvas.width, layout.size.width), height: max(tallestHeight, layout.size.height))
    }
    private var tallestMetrics: NotchMetrics?
    private var tallestHeight: CGFloat = 0

    func refresh() {
        header.refresh()
        banner.refresh()
        if let tab = model.presentation.expandedTab, tab != activeTab { select(tab) }
        needsLayout = true
    }

    private func select(_ tab: ExpandedTab) {
        let style = DeneyMotion.effectiveStyle(model.motionStyle)
        let lively = style == .expressive
        let fadeIn = style == .reduced ? 0.10 : (lively ? 0.12 : 0.15)
        let fadeOut = style == .reduced ? 0.06 : (lively ? 0.08 : 0.10)
        let isFirst = activeTab == nil
        if let previous = activeTab, let old = panels[previous] {
            old.fadeOut(duration: fadeOut)
        }
        activeTab = tab
        let container = panels[tab] ?? {
            let c = PanelContainer(panel: PanelFactory.make(tab, model: model, environment: environment))
            panels[tab] = c
            addSubview(c, positioned: .below, relativeTo: banner)
            return c
        }()
        layoutPanel(container, tab: tab)
        container.fadeIn(duration: isFirst ? 0 : fadeIn)
        container.announceLayoutChange()
    }

    override func layout() {
        super.layout()
        let metrics = model.metrics
        guard let tab = activeTab else { return }
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: metrics.notchSize.height)
        header.layoutRow(tab: tab, frameWidth: bounds.width)
        if let container = panels[tab] { layoutPanel(container, tab: tab) }
        let layout = IslandLayoutEngine.layout(for: .expanded(tab), metrics: metrics)
        let bodyX = (bounds.width - layout.size.width) / 2
        banner.frame = CGRect(x: bodyX, y: 0, width: layout.size.width, height: layout.size.height - Spacing.s)
    }

    /// İçerik dikdörtgeni özgün iç yığınla aynı: genişlik gövde ile görünmez başlık iskeletinin büyüğü.
    private func layoutPanel(_ container: PanelContainer, tab: ExpandedTab) {
        guard !container.isFadingOut else { return } // sönen panel kendi dikdörtgeninde donar
        let metrics = model.metrics
        let layout = IslandLayoutEngine.layout(for: .expanded(tab), metrics: metrics)
        let side = IslandLayoutEngine.contentSideInset(for: layout, style: metrics.style, size: metrics.expandedSurfaceSize)
        let stackWidth = max(layout.size.width, header.skeletonWidth(bodyWidth: layout.size.width))
        let top = metrics.notchSize.height + IslandLayoutEngine.headerGap
        let rect = CGRect(x: (bounds.width - stackWidth) / 2 + side, y: top, width: stackWidth - 2 * side,
                          height: layout.size.height - top - IslandLayoutEngine.expandedBottomInset(for: metrics))
        if container.frame != rect { container.setFrameAligned(rect) }
    }
}

// MARK: - Paneller

/// Bir sekme paneli. `didShow/didHide`, SwiftUI'deki `onAppear/onDisappear` anlarında çağrılır.
@MainActor
protocol IslandPanel: NSView {
    func didShow()
    func didHide()
    /// Uyku hâlindeki ön kurulumda: yalnız mağazadaki mevcut veriden görsel hazırlık (gözlem/örnekleme başlatmaz).
    func prewarm()
    /// SwiftUI `accessibilitySortPriority(PanelAXOrder…)` karşılığı: panel içindeki bir görünümün VoiceOver gezinme
    /// önceliği (yüksek önce). nil: panel öncelik vermez, VoiceOver kendi geometrik sırasını kullanır.
    func axNavigationRank(of view: NSView) -> Int?
}

extension IslandPanel {
    func axNavigationRank(of view: NSView) -> Int? { nil }
    func didShow() {}
    func didHide() {}
    func prewarm() {}
}

/// Panelin solma geçişi (SwiftUI `.islandReveal(expanded: true)`: easeOut giriş, easeIn çıkış). Sönen panel kendi
/// dikdörtgeninde donar, sonunda gizlenir ve `didHide` çağrılır.
@MainActor
final class PanelContainer: FlippedView {
    let panel: IslandPanel
    private(set) var isFadingOut = false
    private var isShown = false
    private var hideWork: DispatchWorkItem?
    private var visibilityGeneration: UInt64 = 0

    init(panel: IslandPanel) {
        self.panel = panel
        super.init(frame: .zero)
        wantsLayer = true
        panel.autoresizingMask = [.width, .height]
        addSubview(panel)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func layout() {
        super.layout()
        panel.frame = bounds
    }

    /// Kapanışta: sönme iptal, gösteriliyorsa `didHide`. Etkin panel görünür kalır (açılışta `fadeIn` ile yeniden başlar).
    func suspend() {
        visibilityGeneration &+= 1
        hideWork?.cancel(); hideWork = nil
        if isFadingOut { isFadingOut = false; isHidden = true; layer?.removeAnimation(forKey: "fade") }
        if isShown { isShown = false; panel.didHide() }
    }

    /// Uyku halinde görünür kıl (`didShow` yok); `fadeIn` açılışta çalışmayı başlatır.
    func prepare() {
        isHidden = false
        layer?.opacity = 1
    }

    func fadeIn(duration: Double) {
        visibilityGeneration &+= 1
        hideWork?.cancel(); hideWork = nil
        isFadingOut = false
        let wasHidden = isHidden
        isHidden = false
        if !isShown { isShown = true; panel.didShow() }
        animateOpacity(to: 1, from: wasHidden ? 0 : nil, duration: duration, timing: .easeOut)
    }

    /// Görünür panel kümesi değişti: VoiceOver gizlenen panelin öğelerini önbellekte tutmasın (SwiftUI bunu kendiliğinden
    /// bildirir). Dinleyen yardımcı teknoloji yoksa AppKit bildirimi ucuz geçer. Bildirim pencereye değil adanın erişilebilirlik
    /// kabına gönderilir: pencere düzeyindeki bildirim Tam Klavye Erişimi ajanının konumunu sıfırlıyor, panel değişince Tab
    /// odağı başlıkta takılıyordu.
    func announceLayoutChange() {
        var node = superview
        while let current = node, !(current is AccessibleContainerView) { node = current.superview }
        if let node { NSAccessibility.post(element: node, notification: .layoutChanged) }
    }

    func fadeOut(duration: Double) {
        hideWork?.cancel()
        visibilityGeneration &+= 1
        let token = visibilityGeneration
        isFadingOut = true
        animateOpacity(to: 0, from: nil, duration: duration, timing: .easeIn)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isFadingOut, self.visibilityGeneration == token else { return }
            self.hideWork = nil
            self.isHidden = true
            self.isFadingOut = false
            if self.isShown { self.isShown = false; self.panel.didHide() }
            self.announceLayoutChange()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func animateOpacity(to target: Float, from start: Float?, duration: Double, timing: CAMediaTimingFunctionName) {
        guard let layer else { return }
        let current = start ?? layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        defer { CATransaction.commit() }
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "fade")
        layer.opacity = target
        guard duration > 0, current != target else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = current
        animation.toValue = target
        animation.duration = duration * Double(abs(target - current))
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        layer.add(animation, forKey: "fade")
    }
}

@MainActor
enum PanelFactory {
    static func make(_ tab: ExpandedTab, model: IslandViewModel, environment: AppEnvironment) -> IslandPanel {
        switch tab {
        case .media: MediaPanelView(media: environment.media, model: model)
        case .nook: NookPanelView(environment: environment, model: model)
        case .shelf: ShelfPanelView(shelf: environment.shelf)
        case .clipboard: ClipboardPanelView(history: environment.clipboard, downloader: environment.linkDownloader)
        case .focus: FocusPanelView(timer: environment.focusTimer)
        case .notes: NotesPanelView(notes: environment.notes, launcher: environment.launcher)
        case .mirror: MirrorPanelView(mirror: environment.mirror)
        case .mixer: MixerPanelView(mixer: environment.audioMixer, settings: { environment.openSettings() })
        case .system: SystemPanelView(system: environment.system)
        }
    }
}

/// Henüz AppKit'e çevrilmemiş paneller için geçici yer tutucu (bkz. Deney/README.md → Durum).
final class PlaceholderPanel: FlippedView, IslandPanel {
    private let label: TextLabel

    init(tab: ExpandedTab) {
        label = TextLabel("\(tab.title) — AppKit sürümü hazırlanıyor", font: Fonts.caption, color: Palette.tertiary, alignment: .center)
        super.init(frame: .zero)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func layout() {
        super.layout()
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
    }
}
