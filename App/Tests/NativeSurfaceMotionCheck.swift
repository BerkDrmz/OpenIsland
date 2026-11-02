import AppKit
import IslandCore

/// Actual spring/path source. No user data, privacy permissions, global input,
/// visible windows or hardware. Rendering under stalls is a separate check.
@main @MainActor struct NativeSurfaceMotionCheck {
    static func main() {
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        func compare(_ a: NativeSurfaceMotion.Pose, _ b: NativeSurfaceMotion.Pose) {
            for (x, y) in zip([a.width, a.height, a.topRadius, a.bottomRadius, a.topInset, a.scale],
                              [b.width, b.height, b.topRadius, b.bottomRadius, b.topInset, b.scale]) {
                check(abs(x - y) < 0.000001, "analytic pose/retarget changed")
            }
        }
        // Frozen pre-optimization oracle: exact equilibrium must not bypass
        // pending delays, a nonzero velocity or the existing settle thresholds.
        let specs = [AppMotion.livelyExpand, AppMotion.expand, AppMotion.collapse,
                     AppMotion.contentIn, AppMotion.livelyContentIn, AppMotion.relax]
        let steps = [0.0, 1.0 / 240, 1.0 / 60, 0.12, 0.7, 0.001, 4.0]
        for seed in 0..<40 {
            var actual = Spring(Double(seed % 7)), old = LegacySpring(Double(seed % 7))
            for i in 0..<210 {
                switch i % 11 {
                case 0, 3:
                    let target = Double((i * 7 + seed) % 31)
                    let spec = specs[(i + seed) % specs.count]
                    actual.animate(to: target, spec: spec); old.animate(to: target, spec: spec)
                case 5:
                    actual.rebase(to: actual.target + 0.00001, velocity: 0.0001)
                    old.rebase(to: old.target + 0.00001, velocity: 0.0001)
                case 7:
                    actual.set(Double(seed)); old.set(Double(seed))
                case 9:
                    actual.rebase(to: actual.target, velocity: 0.2)
                    old.rebase(to: old.target, velocity: 0.2)
                default: break
                }
                let dt = steps[(i + seed) % steps.count]
                actual.step(dt); old.step(dt)
                check(actual.value == old.value && actual.velocity == old.velocity
                      && actual.target == old.target && actual.isActive == old.isActive,
                      "spring diverged from frozen original, seed \(seed), step \(i)")
            }
        }
        for style in [IslandStyle.notch, .pill] {
            let metrics = NotchMetrics(notchSize: CGSize(width: 185, height: 33.4), style: style)
            func pose(_ layout: IslandLayout) -> NativeSurfaceMotion.Pose {
                .init(width: layout.size.width, height: layout.size.height, topRadius: layout.topCornerRadius,
                      bottomRadius: layout.bottomCornerRadius, topInset: layout.topInset)
            }
            let initial = pose(IslandLayoutEngine.layout(for: .idle, metrics: metrics))
            for motionStyle in [MotionStyle.natural, .expressive, .reduced] {
                var time = CACurrentMediaTime()
                let surface = CAShapeLayer(), mask = CAShapeLayer()
                let native = NativeSurfaceMotion(surface: surface, mask: mask, pose: initial,
                                                 canvasWidth: 900, style: style, now: { time })
                var reference = NativeSurfaceMotion.State(initial)
                let sentinel = CABasicAnimation(keyPath: "opacity")
                sentinel.fromValue = 1; sentinel.toValue = 1; sentinel.duration = 100
                surface.add(sentinel, forKey: "foreign.sentinel")
                for (i, tab) in ExpandedTab.allCases.enumerated() {
                    let target = pose(IslandLayoutEngine.layout(for: .expanded(tab), metrics: metrics))
                    let spec = AppMotion.morph(from: .idle, to: .expanded(tab), style: motionStyle)
                    compare(native.pose(at: time), reference.pose)
                    native.morph(to: target, spec: spec)
                    reference.morph(to: target, spec: spec)
                    check(native.ownsPath, "ordinary notch/pill trajectory fell back")
                    check(native.lastSampleCount < 1000, "unbounded trajectory")
                    let a = surface.animation(forKey: NativeSurfaceMotion.animationKey) as? CAKeyframeAnimation
                    let b = mask.animation(forKey: NativeSurfaceMotion.animationKey) as? CAKeyframeAnimation
                    check(a != nil && b != nil && a?.duration == b?.duration, "surface/mask clocks differ")
                    check(a?.keyTimes == b?.keyTimes, "surface/mask samples differ")
                    check(surface.animation(forKey: "foreign.sentinel") != nil, "foreign animation removed")
                    for _ in 0..<12 {
                        let dt = 1.0 / 240
                        time += dt; reference.step(dt)
                        compare(native.pose(at: time), reference.pose)
                    }
                    if i.isMultiple(of: 2) {
                        native.relax(to: 0.994, spec: AppMotion.relax)
                        reference.scale.animate(to: 0.994, spec: AppMotion.relax)
                    }
                }
                for _ in 0..<120 {
                    time += 1.0 / 120; reference.step(1.0 / 120)
                    compare(native.pose(at: time), reference.pose)
                }
                let ownKeys = surface.animationKeys()?.filter { $0 == NativeSurfaceMotion.animationKey } ?? []
                check(ownKeys.count <= 1, "retargets accumulated animations")
                native.update(canvasWidth: 1000, style: style)
                compare(native.pose(at: time), reference.pose)
                time += 3
                reference.step(3)
                compare(native.pose(at: time), reference.pose)
                native.update(canvasWidth: 1100, style: style)
                check(surface.animation(forKey: NativeSurfaceMotion.animationKey) == nil,
                      "settled geometry update started an idle animation")
                let expected = reference.pose.path(canvasWidth: 1100, style: style).boundingBoxOfPath
                check(surface.path?.boundingBoxOfPath == expected, "settled geometry changed")
            }
        }
        do {
            var time = CACurrentMediaTime()
            let body = CAShapeLayer(), mask = CAShapeLayer()
            let closed = NativeSurfaceMotion.Pose(width: 185, height: 33.4, topRadius: 6, bottomRadius: 10, topInset: 0)
            let open = NativeSurfaceMotion.Pose(width: 635, height: 129, topRadius: 12, bottomRadius: 24, topInset: 0)
            let motion = NativeSurfaceMotion(surface: body, mask: mask, pose: closed,
                                             canvasWidth: 900, style: .notch, now: { time })
            motion.morph(to: open, spec: AppMotion.livelyExpand)
            let first = body.animation(forKey: NativeSurfaceMotion.animationKey) as! CAKeyframeAnimation
            check(!motion.lastPreparationWasCached, "first trajectory should be computed")
            time += 3; motion.morph(to: closed, spec: AppMotion.livelyCollapse)
            time += 3; motion.morph(to: open, spec: AppMotion.livelyExpand)
            let cached = body.animation(forKey: NativeSurfaceMotion.animationKey) as! CAKeyframeAnimation
            check(motion.lastPreparationWasCached, "identical settled open was not reused")
            check(cached.duration == first.duration && cached.keyTimes == first.keyTimes,
                  "cached trajectory timing changed")
            let a = first.values as! [CGPath], b = cached.values as! [CGPath]
            check(a.count == b.count && zip(a, b).allSatisfy { $0 == $1 }, "cached path samples changed")
            check(cached.beginTime > first.beginTime + 5.9, "cache reused an old animation clock")
            time += 0.03; motion.morph(to: closed, spec: AppMotion.livelyCollapse)
            check(!motion.lastPreparationWasCached, "different in-flight velocity reused a settled trajectory")
            for i in 0..<12 {
                time += 3
                var target = open; target.width += CGFloat(i * 3)
                motion.morph(to: target, spec: AppMotion.livelyExpand)
                check(motion.cachedTrajectoryCount <= NativeSurfaceMotion.trajectoryCacheLimit, "cache exceeded bound")
            }
            time += 3; motion.update(canvasWidth: 1050, style: .pill)
            check(!motion.lastPreparationWasCached && motion.cachedTrajectoryCount <= 1,
                  "screen/style change did not invalidate cached geometry")
        }
        print("PASS: \(checks) native surface spring, mask, retarget, fallback-bound and ownership checks")
    }
}

// Frozen f848fde Spring implementation; keep the oracle independent of the optimized math.
private struct LegacySpring {
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
