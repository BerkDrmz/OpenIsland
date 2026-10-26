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

    /// Coordinate/presentation rebasing must not discard in-flight velocity.
    mutating func rebase(to value: Double, velocity: Double? = nil) {
        self.value = value
        if let velocity { self.velocity = velocity }
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

/// Ekran tazelemesine bağlı kare sürücüsü. Yalnız etkin yay varken çalışır; boşta uyanma yok. Aynı penceredeki
/// sürücüler tek `FrameClock` bağlantısıyla, tek Core Animation işleminde ilerler (kare başına tek commit).
@MainActor
final class FrameDriver: NSObject {
    private weak var view: NSView?
    /// Pencere dışındaki görünüm için kendi bağlantısı (pencereye bağlı saat yokken).
    private var link: CADisplayLink?
    private var linkTarget: WeakTarget?
    private weak var clock: FrameClock?
    fileprivate lazy var clockEntry = FrameClock.WeakDriver(self)
    private var lastTimestamp: CFTimeInterval?
    private let tick: (Double) -> Bool

    /// `tick(dt)` sürüş gerekiyorsa `true` döndürür.
    init(view: NSView, tick: @escaping (Double) -> Bool) {
        self.view = view
        self.tick = tick
    }

    var isRunning: Bool { link != nil || clock != nil }

    /// `body`, şu anki işlemin içeren karesi ekrana çıktıktan sonra (iki ekran tazelemesi) bir kez çalışır.
    static func afterPresentedFrame(of view: NSView, _ body: @escaping @MainActor () -> Void) {
        let waiter = FrameWaiter(frames: 2, body: body)
        let link = view.displayLink(target: waiter, selector: #selector(FrameWaiter.step(_:)))
        link.add(to: .main, forMode: .common)
    }

    func start() {
        guard !isRunning, let view else { return }
        if !FrameClock.isDisabled, let window = view.window {
            let clock = FrameClock.shared(for: window)
            clock.add(self)
            self.clock = clock
        } else {
            let target = WeakTarget(self)
            let link = view.displayLink(target: target, selector: #selector(WeakTarget.fire(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            linkTarget = target
        }
        // Animasyon şimdi başladı: ilk kare, şimdiden o karenin gösterim anına kadar ilerler.
        lastTimestamp = CACurrentMediaTime()
    }

    func stop() {
        link?.invalidate()
        link = nil
        linkTarget = nil
        clock?.remove(self)
        clock = nil
        lastTimestamp = nil
    }

    deinit {
        MainActor.assumeIsolated {
            link?.invalidate()
            clock?.remove(self)
        }
    }

    @MainActor private final class WeakTarget: NSObject {
        weak var driver: FrameDriver?
        init(_ driver: FrameDriver) { self.driver = driver }
        @objc func fire(_ link: CADisplayLink) {
            guard let driver else { link.invalidate(); return }
            driver.step(link)
        }
    }

    @objc fileprivate func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = lastTimestamp.map { max(now - $0, 0) } ?? (1.0 / 60)
        lastTimestamp = now
        guard let log = Self.frameLog else {
            if !tick(dt) { stop() }
            return
        }
        // Geliştirici tanısı (OPENISLAND_DENEY_FRAMELOG): kare aralığı, tick süresi, hedefe kalan süre.
        let start = CACurrentMediaTime()
        let active = tick(dt)
        let end = CACurrentMediaTime()
        let line = String(format: "%.3f dt=%.2f tick=%.2f slack=%.2f %@\n", start, dt * 1000, (end - start) * 1000,
                          (link.targetTimestamp - end) * 1000, String(describing: type(of: view ?? NSView())))
        log.write(Data(line.utf8))
        if !active { stop() }
    }

    private static let frameLog: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["OPENISLAND_DENEY_FRAMELOG"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static var isLogging: Bool { frameLog != nil }

    /// Tanı satırı (yalnız OPENISLAND_DENEY_FRAMELOG açıkken).
    static func note(_ text: String) {
        guard let log = frameLog else { return }
        log.write(Data(String(format: "%.3f # %@\n", CACurrentMediaTime(), text).utf8))
    }

    /// Çalışma döngüsü başına ana iş parçacığı süresi (uyanıştan uykuya; Core Animation commit'i, yerleşim ve çizim
    /// dahil). 6 ms'yi aşan döngüler yazılır.
    static func installRunLoopProbe() {
        guard frameLog != nil else { return }
        var start: CFTimeInterval = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, 0) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting { start = now; return }
            let busy = (now - start) * 1000
            if start > 0, busy > 6 { note(String(format: "runloop busy=%.2f ms", busy)) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}

/// Bir penceredeki etkin kare sürücülerinin ortak ekran tazelemesi bağlantısı. Sürücüler tek geri çağrıda ve tek açık
/// Core Animation işleminde ilerler: sürücülerin kendi `CATransaction` blokları iç içe kalır, ayrı commit yapmaz
/// (her biri ayrı yerleşim/çizim geçişi ve pencere sunucusunda ayrı işlem demekti). Etkin sürücü kalmayınca bağlantı
/// kapanır; boşta uyanma yok.
@MainActor
final class FrameClock: NSObject {
    /// Karşılaştırma ölçümü için (OPENISLAND_DENEY_NOCLOCK): sürücü başına ayrı bağlantı (önceki davranış).
    static let isDisabled = ProcessInfo.processInfo.environment["OPENISLAND_DENEY_NOCLOCK"] != nil
    private static var clocks: [ObjectIdentifier: FrameClock] = [:]
    private weak var window: NSWindow?
    private var link: CADisplayLink?
    fileprivate final class WeakDriver {
        weak var value: FrameDriver?
        init(_ driver: FrameDriver) { value = driver }
    }
    private var drivers: [WeakDriver] = []
    private var closeObserver: NSObjectProtocol?
    private let windowID: ObjectIdentifier

    static func shared(for window: NSWindow) -> FrameClock {
        let key = ObjectIdentifier(window)
        if let clock = clocks[key], clock.window === window { return clock }
        for (_, clock) in clocks where clock.window == nil { clock.shutdown() }
        let clock = FrameClock(window: window)
        clocks[key] = clock
        return clock
    }

    private init(window: NSWindow) {
        self.window = window
        windowID = ObjectIdentifier(window)
        super.init()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let closed = note.object as? NSWindow else { return }
            let closedID = ObjectIdentifier(closed)
            MainActor.assumeIsolated {
                guard let self, closedID == self.windowID else { return }
                // A cached window can reopen during an unfinished animation.
                // Preserve that driver's clock/timestamps; only idle clocks
                // may be discarded here. Owner deinit releases active drivers.
                if !self.drivers.contains(where: { $0.value != nil }) { self.shutdown() }
            }
        }
    }

    func add(_ driver: FrameDriver) {
        drivers.removeAll { $0.value == nil }
        drivers.append(driver.clockEntry)
        guard link == nil, let window else { return }
        let link = window.displayLink(target: self, selector: #selector(fire(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func remove(_ driver: FrameDriver) {
        drivers.removeAll { $0.value == nil || $0.value === driver }
        if drivers.isEmpty {
            link?.invalidate()
            link = nil
            if window?.isVisible != true { shutdown() }
        }
    }

    private func shutdown() {
        link?.invalidate()
        link = nil
        let active = drivers.compactMap(\.value)
        drivers.removeAll()
        active.forEach { $0.stop() }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if Self.clocks[windowID] === self { Self.clocks[windowID] = nil }
    }

    deinit {
        MainActor.assumeIsolated {
            link?.invalidate()
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }
    }

    @objc private func fire(_ link: CADisplayLink) {
        CATransaction.begin()
        // Kopya üzerinde: bir sürücünün adımı başkasını durdurabilir (durdurulan bu karede ilerlemez) ya da yenisini
        // başlatabilir (yenisi sonraki karede ilerler; ayrı bağlantıda da öyleydi).
        for entry in drivers {
            guard let driver = entry.value, drivers.contains(where: { $0 === entry }) else { continue }
            driver.step(link)
        }
        CATransaction.commit()
    }
}

/// SwiftUI yayının Core Animation karşılığı. `CASpringAnimation` (kütle 1, katılık (2π/response)², sönüm 4πζ/response)
/// render sunucusunda çalışır: ana iş parçacığında kare başına iş yoktur. Tek bir skaler (ör. hover miktarı 0…1) analitik
/// olarak izlenir ve katman özelliklerine `apply` ile eşlenir; hedef değişince o anki değer ve hız yeni animasyona
/// aktarılır (SwiftUI'de olduğu gibi yörünge kırılmaz). `apply` skalerde doğrusal olmalıdır (ölçek, renk karışımı).
@MainActor
final class LayerSpring {
    typealias Target = (layer: CALayer, keyPath: String, value: Any)
    private var spring: Spring
    private var stamp = CACurrentMediaTime()
    private let apply: (CGFloat) -> [Target]

    init(_ value: CGFloat, apply: @escaping (CGFloat) -> [Target]) {
        spring = Spring(Double(value))
        self.apply = apply
    }

    var target: CGFloat { CGFloat(spring.target) }
    var isActive: Bool {
        var current = spring
        current.step(max(CACurrentMediaTime() - stamp, 0))
        return current.isActive
    }

    /// `spec == nil`: animasyonsuz atama (SwiftUI'de animasyonsuz işlem).
    func animate(to target: CGFloat, spec: SpringSpec?) {
        let now = CACurrentMediaTime()
        spring.step(now - stamp)
        stamp = now
        let from = CGFloat(spring.value), velocity = CGFloat(spring.velocity)
        let targets = apply(target)
        // Model değeri ve yay animasyonu tek işlemde commit edilir. Ayrı commit'te yeni değer bir kare animasyonsuz
        // ekrana çıkıyordu (hızlı sekme geçişinde seçilen simge bir an tam parlaklığa sıçrıyordu).
        CATransaction.begin()
        defer { CATransaction.commit() }
        CATransaction.setDisableActions(true)
        for t in targets { t.layer.setValue(t.value, forKeyPath: t.keyPath) }
        guard let spec, from != target || velocity != 0 else {
            spring.set(Double(target))
            for t in targets { t.layer.removeAnimation(forKey: "spring." + t.keyPath) }
            return
        }
        spring.animate(to: Double(target), spec: spec)
        let origins = apply(from)
        for (t, o) in zip(targets, origins) {
            let a = CASpringAnimation(keyPath: t.keyPath)
            a.mass = 1
            a.stiffness = pow(2 * .pi / spec.response, 2)
            a.damping = 4 * .pi * spec.damping / spec.response
            a.fromValue = o.value
            a.toValue = t.value
            a.initialVelocity = target != from ? velocity / (target - from) : 0
            a.duration = a.settlingDuration
            a.isRemovedOnCompletion = true
            t.layer.add(a, forKey: "spring." + t.keyPath)
        }
    }

    /// Katmanı `point` çevresinde (katman koordinatları) ölçekleyen dönüşüm; çapa noktası hesaba katılır.
    static func scale(_ s: CGFloat, about point: CGPoint, in layer: CALayer) -> CATransform3D {
        let anchor = CGPoint(x: layer.anchorPoint.x * layer.bounds.width, y: layer.anchorPoint.y * layer.bounds.height)
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        return CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(dx, dy, 0), s, s, 1), -dx, -dy, 0)
    }

    /// sRGB'de doğrusal renk karışımı (SwiftUI renk animasyonu).
    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> CGColor {
        let x = a.usingColorSpace(.sRGB) ?? a, y = b.usingColorSpace(.sRGB) ?? b
        func l(_ p: CGFloat, _ q: CGFloat) -> CGFloat { p + (q - p) * t }
        return CGColor(srgbRed: l(x.redComponent, y.redComponent), green: l(x.greenComponent, y.greenComponent),
                       blue: l(x.blueComponent, y.blueComponent), alpha: l(x.alphaComponent, y.alphaComponent))
    }
}

/// Tek seferlik kare bekleyicisi (`FrameDriver.afterPresentedFrame`). Bağlantı kendini geçersiz kılınca bırakılır.
@MainActor
final class FrameWaiter: NSObject {
    private var remaining: Int
    private let body: () -> Void

    init(frames: Int, body: @escaping () -> Void) {
        remaining = frames
        self.body = body
    }

    @objc func step(_ link: CADisplayLink) {
        remaining -= 1
        guard remaining <= 0 else { return }
        link.invalidate()
        body()
    }
}

/// İçerik girişindeki bulanıklık (`.islandReveal`: opaklık + (1 − p) × 6 pt Gauss). Filtre yalnız yarıçap sıfırdan
/// büyükken katmanda durur: SwiftUI'de 0 yarıçaplı bulanıklık hiç uygulanmaz. Takılı kalan Core Image filtresi
/// katmanın her birleştirmesini (ör. sürekli canlanan nabız) pencere sunucusunda filtre yolundan geçiriyordu
/// (8 aç/kapat döngüsünde ~350 ms fazladan WindowServer süresi ölçüldü).
enum RevealBlur { // yalnız ana iş parçacığındaki katman güncellemelerinden çağrılır
    static let isDisabled = ProcessInfo.processInfo.environment["OPENISLAND_DENEY_NOBLUR"] != nil

    static func apply(radius: CGFloat, to layer: CALayer?) {
        guard let layer else { return }
        let attached = (layer.filters?.isEmpty == false)
        guard radius > 0.01, !isDisabled else {
            if attached { layer.filters = nil }
            return
        }
        if !attached, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "reveal"
            blur.setValue(radius, forKey: kCIInputRadiusKey)
            layer.filters = [blur]
        } else {
            layer.setValue(radius, forKeyPath: "filters.reveal.inputRadius")
        }
    }
}
