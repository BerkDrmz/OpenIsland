import AppKit
import IslandCore

/// Genişletilmiş ada (SwiftUI `ExpandedIslandView`): çentiğin iki yanında sekmeler + sekme içeriği.
///
/// Paneller sekme başına bir kez kurulur ve aynı açık oturum boyunca pencerede kalır; seçili olmayan panel gizlenir.
/// SwiftUI'deki `onAppear/onDisappear` anlamı panelin kendi `didShow/didHide` çağrılarıyla korunur (örnekleme,
/// konum izleme vb. yalnız panel görünürken). Ada kapanınca görünüm bırakılır; her açılış özgünle aynı başlar.
@MainActor
final class ExpandedContentView: FlippedView, IslandContentView {
    private let model: IslandViewModel
    private let environment: AppEnvironment
    private let header: HeaderView
    private var panels: [ExpandedTab: PanelContainer] = [:]
    private var activeTab: ExpandedTab?
    private let banner: BannerHostView

    init(model: IslandViewModel, environment: AppEnvironment) {
        self.model = model
        self.environment = environment
        header = HeaderView(model: model, environment: environment)
        banner = BannerHostView(model: model)
        super.init(frame: .zero)
        addSubview(header)
        addSubview(banner)
        setAccessibilityElement(false)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    deinit {
        MainActor.assumeIsolated { panels.values.forEach { $0.panel.didHide() } }
    }

    func fittingFrameSize(canvas: CGSize, metrics: NotchMetrics) -> CGSize {
        guard let tab = model.presentation.expandedTab ?? activeTab else { return .zero }
        let layout = IslandLayoutEngine.layout(for: .expanded(tab), metrics: metrics)
        return CGSize(width: max(canvas.width, layout.size.width), height: layout.size.height)
    }

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
}

extension IslandPanel {
    func didShow() {}
    func didHide() {}
}

/// Panelin solma geçişi (SwiftUI `.islandReveal(expanded: true)`: easeOut giriş, easeIn çıkış). Sönen panel kendi
/// dikdörtgeninde donar, sonunda gizlenir ve `didHide` çağrılır.
@MainActor
final class PanelContainer: FlippedView {
    let panel: IslandPanel
    private(set) var isFadingOut = false
    private var isShown = false
    private var hideWork: DispatchWorkItem?

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

    func fadeIn(duration: Double) {
        hideWork?.cancel(); hideWork = nil
        isFadingOut = false
        let wasHidden = isHidden
        isHidden = false
        if !isShown { isShown = true; panel.didShow() }
        animateOpacity(to: 1, from: wasHidden ? 0 : nil, duration: duration, timing: .easeOut)
    }

    func fadeOut(duration: Double) {
        isFadingOut = true
        animateOpacity(to: 0, from: nil, duration: duration, timing: .easeIn)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isFadingOut else { return }
            self.isHidden = true
            self.isFadingOut = false
            if self.isShown { self.isShown = false; self.panel.didHide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func animateOpacity(to target: Float, from start: Float?, duration: Double, timing: CAMediaTimingFunctionName) {
        guard let layer else { return }
        let current = start ?? layer.presentation()?.opacity ?? layer.opacity
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
        default: PlaceholderPanel(tab: tab)
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
