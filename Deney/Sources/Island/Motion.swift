import AppKit
import IslandCore
import QuartzCore

/// SwiftUI `Animation.spring(response:dampingFraction:)` ile aynı fizik: kütle 1, ω₀ = 2π / response, ζ = dampingFraction.
/// `delay`, SwiftUI `.delay(_:)` ile aynı anlamda (hedef değişimi bu süre sonra başlar).
struct SpringSpec: Equatable {
    var response: Double
    var damping: Double
    var delay: Double = 0
}

/// `IslandMotion` (UI/IslandDesign.swift) sabitlerinin AppKit karşılığı; değerler birebir aynı tutulur.
enum DeneyMotion {
    static let expand = SpringSpec(response: 0.44, damping: 0.78)
    static let collapse = SpringSpec(response: 0.5, damping: 0.94)
    static let hover = SpringSpec(response: 0.3, damping: 0.72)
    static let rest = SpringSpec(response: 0.4, damping: 0.84)
    static let notice = SpringSpec(response: 0.42, damping: 0.8)
    static let hud = SpringSpec(response: 0.3, damping: 0.86)
    static let relax = SpringSpec(response: 0.55, damping: 1)
    static let relaxScale: CGFloat = 0.994
    static let contentIn = SpringSpec(response: 0.34, damping: 1, delay: 0.06)
    static let contentOut = SpringSpec(response: 0.16, damping: 1)
    static let control = SpringSpec(response: 0.26, damping: 0.8)
    static let reduced = SpringSpec(response: 0.24, damping: 1)
    static let livelyExpand = SpringSpec(response: 0.26, damping: 0.8)
    static let livelyCollapse = SpringSpec(response: 0.19, damping: 1)
    static let livelyNotice = SpringSpec(response: 0.32, damping: 0.76)
    static let livelyHover = SpringSpec(response: 0.21, damping: 0.7)
    static let livelyContentIn = SpringSpec(response: 0.19, damping: 1, delay: 0.02)
    static let livelyContentOut = SpringSpec(response: 0.11, damping: 1)
    static let livelyResize = SpringSpec(response: 0.22, damping: 0.95)
    static let naturalResize = SpringSpec(response: 0.28, damping: 0.95)

    static func morph(from old: IslandPresentation, to new: IslandPresentation, style: MotionStyle) -> SpringSpec {
        if style == .reduced { return reduced }
        let lively = style == .expressive
        switch (old, new) {
        case (.expanded, .expanded): return resize(style: style)
        case (_, .expanded), (_, .dropTarget): return lively ? livelyExpand : expand
        case (.expanded, _), (.dropTarget, _): return lively ? livelyCollapse : collapse
        case (_, .hud), (.hud, _): return hud
        case (_, .notice): return lively ? livelyNotice : notice
        case (.notice, _): return lively ? livelyCollapse : collapse
        case (_, .peek), (.peek, _): return lively ? livelyHover : hover
        default: return rest
        }
    }

    static func resize(style: MotionStyle) -> SpringSpec {
        switch style {
        case .reduced: reduced
        case .natural: naturalResize
        case .expressive: livelyResize
        }
    }

    static func contentIn(_ style: MotionStyle) -> SpringSpec { style == .expressive ? livelyContentIn : contentIn }
    static func contentOut(_ style: MotionStyle) -> SpringSpec { style == .expressive ? livelyContentOut : contentOut }

    /// Sistemin "Hareketi Azalt" ayarı her zaman önceliklidir.
    static func effectiveStyle(_ style: MotionStyle) -> MotionStyle {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .reduced : style
    }
}

/// Tek boyutlu yay: sönümlü harmonik salınımın analitik çözümü. Hedef değişince hız korunur (SwiftUI'de olduğu gibi
/// yörünge kırılmaz). Sayısal integrasyon yok; kare süresinden bağımsız olarak aynı eğri.
struct Spring {
    private(set) var value: Double
    private(set) var velocity: Double = 0
    private(set) var target: Double
    private var spec = SpringSpec(response: 0.3, damping: 1)
    private var pendingDelay: Double = 0
    private var pendingTarget: Double?

    init(_ value: Double) {
        self.value = value
        target = value
    }

    var isActive: Bool { pendingTarget != nil || abs(value - target) > 1e-4 || abs(velocity) > 1e-3 }

    /// Animasyonsuz atama (hız sıfırlanır).
    mutating func set(_ newValue: Double) {
        value = newValue
        target = newValue
        velocity = 0
        pendingTarget = nil
    }

    mutating func animate(to newTarget: Double, spec: SpringSpec) {
        self.spec = spec
        if spec.delay > 0 {
            pendingTarget = newTarget
            pendingDelay = spec.delay
        } else {
            pendingTarget = nil
            target = newTarget
        }
    }

    /// `dt` saniye ilerletir.
    mutating func step(_ dt: Double) {
        var dt = dt
        if let pending = pendingTarget {
            if dt < pendingDelay {
                pendingDelay -= dt
                advance(dt)
                return
            }
            advance(pendingDelay)
            dt -= pendingDelay
            target = pending
            pendingTarget = nil
        }
        advance(dt)
    }

    private mutating func advance(_ t: Double) {
        guard t > 0 else { return }
        let omega = 2 * Double.pi / max(spec.response, 0.001)
        let zeta = spec.damping
        let x0 = value - target
        let v0 = velocity
        let x: Double
        let v: Double
        if zeta < 1 {
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * omega * t)
            let c = cos(wd * t), s = sin(wd * t)
            let b = (v0 + zeta * omega * x0) / wd
            x = decay * (x0 * c + b * s)
            v = decay * ((-zeta * omega) * (x0 * c + b * s) + (-x0 * wd * s + b * wd * c))
        } else {
            let a = x0, b = v0 + omega * x0
            let decay = exp(-omega * t)
            x = (a + b * t) * decay
            v = (b - omega * (a + b * t)) * decay
        }
        value = target + x
        velocity = v
        if abs(x) < 1e-4 && abs(v) < 1e-3 {
            value = target
            velocity = 0
        }
    }
}

/// Ekran tazelemesine bağlı kare sürücüsü. Yalnız etkin yay varken çalışır; boşta uyanma yok.
@MainActor
final class FrameDriver: NSObject {
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private let tick: (Double) -> Bool

    /// `tick(dt)` sürüş gerekiyorsa `true` döndürür.
    init(view: NSView, tick: @escaping (Double) -> Bool) {
        self.view = view
        self.tick = tick
    }

    func start() {
        guard link == nil, let view else { return }
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // Animasyon şimdi başladı: ilk kare, şimdiden o karenin gösterim anına kadar ilerler.
        lastTimestamp = CACurrentMediaTime()
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = lastTimestamp.map { min(max(now - $0, 0), 0.05) } ?? (1.0 / 60)
        lastTimestamp = now
        if !tick(dt) { stop() }
    }
}
