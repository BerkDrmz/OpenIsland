import AppKit
import QuartzCore

/// An additive displacement response. For an unchanged spring specification,
/// superposition preserves BOTH position and velocity exactly at each retarget:
/// newTarget + (oldTarget-newTarget) + oldResponses == currentVisiblePosition.
/// Old responses continue in Core Animation; no app frame loop or input delay.
struct CapsuleImpulse {
    let displacement: Double
    var initialVelocity: Double = 0
    let started: Double
    let spec: SpringSpec
    let duration: Double
    let key: String
    func sample(at time: Double) -> (value: Double, velocity: Double) {
        guard time >= started, time < started + duration else { return (0, 0) }
        var spring = Spring(displacement)
        spring.rebase(to: displacement, velocity: initialVelocity)
        spring.animate(to: 0, spec: spec)
        spring.step(time - started)
        return (spring.value, spring.velocity)
    }

    /// CA's estimated settling duration may truncate a large displacement
    /// sooner than the original scalar spring's strict rest threshold.
    static func settlingDuration(displacement: Double, velocity: Double = 0, spec: SpringSpec) -> Double {
        let native = CASpringAnimation()
        native.mass = 1
        native.stiffness = pow(2 * .pi / spec.response, 2)
        native.damping = 4 * .pi * spec.damping / spec.response
        var duration = native.settlingDuration
        var probe = Spring(displacement)
        probe.rebase(to: displacement, velocity: velocity)
        probe.animate(to: 0, spec: spec)
        probe.step(duration)
        while probe.isActive {
            precondition(duration < 20, "Capsule spring failed to settle")
            duration += 1.0 / 240
            probe.step(1.0 / 240)
        }
        return duration
    }
}

/// Decorative capsule only. Native button endpoint frames, hit-testing and AX
/// selection remain independent of the presentation layer's animated position.
/// One animation per REAL selection, automatically removed after settling; the
/// number in flight is bounded by settling time / input interval, never by the
/// lifetime count of selections. No display link, timer or pointer polling.
@MainActor
final class NativeCapsuleMotion {
    static let keyPrefix = "OpenIsland.capsule.impulse."
    private weak var layer: CALayer?
    private var target: CGFloat?
    private var impulses: [CapsuleImpulse] = []
    private var serial: UInt64 = 0
    private var lastSpec: SpringSpec?

    init(layer: CALayer) { self.layer = layer }

    func move(to rect: CGRect, spec: SpringSpec?, now: CFTimeInterval = CACurrentMediaTime()) {
        guard let layer else { return }
        CATransaction.begin()
        defer { CATransaction.commit() }
        CATransaction.setDisableActions(true)
        if layer.bounds.size != rect.size { layer.bounds = CGRect(origin: .zero, size: rect.size) }
        if layer.position.y != rect.midY { layer.position.y = rect.midY }
        let endpoint = rect.midX
        let parametersChanged = spec != nil && lastSpec != spec
        guard target != endpoint || parametersChanged else { return }
        let previous = target
        let local = layer.convertTime(now, from: nil)
        impulses.removeAll { local >= $0.started + $0.duration }
        if target == endpoint, impulses.isEmpty {
            lastSpec = spec ?? lastSpec
            return // new coefficients on a settled target do not create motion
        }
        target = endpoint
        guard let previous, let spec else {
            clearOwnedAnimations(layer)
            layer.position.x = endpoint
            lastSpec = spec
            return
        }
        if let lastSpec, lastSpec != spec, !impulses.isEmpty {
            // Rebase BOTH position and velocity at the same layer-local instant.
            // presentation() is an approximate previous frame; mixing that
            // position with the current analytic velocity creates a discontinuity.
            impulses.removeAll { layer.animation(forKey: $0.key) == nil }
            let visible = Double(previous) + impulses.reduce(0) { $0 + $1.sample(at: local).value }
            let velocity = impulses.reduce(0) { $0 + $1.sample(at: local).velocity }
            clearOwnedAnimations(layer)
            layer.position.x = endpoint
            add(from: visible - Double(endpoint), velocity: velocity, spec: spec, time: local, layer: layer)
        } else {
            layer.position.x = endpoint
            add(from: Double(previous - endpoint), velocity: 0, spec: spec, time: local, layer: layer)
        }
        lastSpec = spec
    }

    private func add(from displacement: Double, velocity: Double, spec: SpringSpec, time: Double, layer: CALayer) {
        if abs(displacement) < 1e-9 && abs(velocity) > 1e-9 {
            // Equal endpoints with nonzero velocity still need real motion.
            // Two nonzero, opposite offsets cancel position, NOT momentum.
            add(from: 1, velocity: velocity, spec: spec, time: time, layer: layer)
            add(from: -1, velocity: 0, spec: spec, time: time, layer: layer)
            return
        }
        let animation = CASpringAnimation(keyPath: "position.x")
        animation.mass = 1
        animation.stiffness = pow(2 * .pi / spec.response, 2)
        animation.damping = 4 * .pi * spec.damping / spec.response
        animation.fromValue = displacement
        animation.toValue = 0
        animation.initialVelocity = displacement != 0 ? -velocity / displacement : 0
        animation.duration = CapsuleImpulse.settlingDuration(displacement: displacement, velocity: velocity, spec: spec)
        animation.beginTime = time
        animation.isAdditive = true
        animation.isRemovedOnCompletion = true
        serial &+= 1
        let key = Self.keyPrefix + String(serial)
        layer.add(animation, forKey: key)
        impulses.append(CapsuleImpulse(displacement: displacement, initialVelocity: velocity, started: time, spec: spec, duration: animation.duration, key: key))
    }

    private func clearOwnedAnimations(_ layer: CALayer) {
        for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.keyPrefix) { layer.removeAnimation(forKey: key) }
        impulses.removeAll()
    }

    func setVisualOffset(_ dx: CGFloat) {
        guard let layer, layer.transform.m41 != dx else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = dx == 0 ? CATransform3DIdentity : CATransform3DMakeTranslation(dx, 0, 0)
        CATransaction.commit()
    }
}
