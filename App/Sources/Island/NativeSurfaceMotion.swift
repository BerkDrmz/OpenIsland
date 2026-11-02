import AppKit
import IslandCore

/// The existing surface geometry and spring, submitted as a bounded, one-shot
/// Core Animation trajectory. No display link or idle worker belongs to this
/// object: the render server can keep moving the outline when the main thread
/// is temporarily busy. Model/layout ownership remains in IslandCanvasView.
@MainActor
final class NativeSurfaceMotion {
    static let animationKey = "OpenIsland.surface.path"

    struct Pose: Equatable {
        var width: CGFloat
        var height: CGFloat
        var topRadius: CGFloat
        var bottomRadius: CGFloat
        var topInset: CGFloat
        var scale: CGFloat = 1

        func path(canvasWidth: CGFloat, style: IslandStyle) -> CGPath {
            let rect = CGRect(x: (canvasWidth - width * scale) / 2, y: topInset * scale,
                              width: width * scale, height: height * scale)
            return IslandShape(style: style, topRadius: topRadius * scale,
                               bottomRadius: bottomRadius * scale).path(in: rect).cgPath
        }
    }

    struct State: Equatable {
        var width: Spring, height: Spring, topRadius: Spring, bottomRadius: Spring, topInset: Spring, scale: Spring
        init(_ p: Pose) {
            width = Spring(p.width); height = Spring(p.height)
            topRadius = Spring(p.topRadius); bottomRadius = Spring(p.bottomRadius)
            topInset = Spring(p.topInset); scale = Spring(p.scale)
        }
        var pose: Pose {
            Pose(width: width.value, height: height.value, topRadius: topRadius.value,
                 bottomRadius: bottomRadius.value, topInset: topInset.value, scale: scale.value)
        }
        var isActive: Bool {
            width.isActive || height.isActive || topRadius.isActive || bottomRadius.isActive || topInset.isActive || scale.isActive
        }
        mutating func step(_ dt: Double) {
            width.step(dt); height.step(dt); topRadius.step(dt); bottomRadius.step(dt); topInset.step(dt); scale.step(dt)
        }
        mutating func morph(to p: Pose, spec: SpringSpec) {
            width.animate(to: p.width, spec: spec); height.animate(to: p.height, spec: spec)
            topRadius.animate(to: p.topRadius, spec: spec); bottomRadius.animate(to: p.bottomRadius, spec: spec)
            topInset.animate(to: p.topInset, spec: spec)
        }
    }

    private weak var surface: CAShapeLayer?
    private weak var mask: CAShapeLayer?
    private var state: State
    private var stamp: CFTimeInterval
    private let now: () -> CFTimeInterval
    private var canvasWidth: CGFloat
    private var style: IslandStyle
    /// Small per-surface cache, not an image cache or background precomputation.
    /// Exact full spring state (including velocity/delay/spec) is the key; never
    /// round a retarget or reuse a trajectory from a different screen geometry.
    private struct Trajectory {
        let start: State
        let paths: [CGPath]
        let keyTimes: [NSNumber]
        let duration: CFTimeInterval
    }
    private var trajectories: [Trajectory] = []
    static let trajectoryCacheLimit = 4
    private(set) var ownsPath = true
    private(set) var lastPreparationMilliseconds: Double = 0
    private(set) var lastSampleCount = 0
    private(set) var lastPreparationWasCached = false
    var cachedTrajectoryCount: Int { trajectories.count }
    private(set) var completionDeadline: CFTimeInterval = 0
    var onSettled: (@MainActor () -> Void)?
    private var generation: UInt64 = 0

    init(surface: CAShapeLayer, mask: CAShapeLayer, pose: Pose, canvasWidth: CGFloat, style: IslandStyle,
         now: @escaping () -> CFTimeInterval = CACurrentMediaTime) {
        self.surface = surface; self.mask = mask; state = State(pose)
        self.canvasWidth = canvasWidth; self.style = style
        self.now = now; stamp = now()
        setPath(pose.path(canvasWidth: canvasWidth, style: style))
    }

    func morph(to pose: Pose, spec: SpringSpec) {
        synchronize()
        state.morph(to: pose, spec: spec)
        submit()
    }

    func relax(to value: CGFloat, spec: SpringSpec) {
        synchronize()
        state.scale.animate(to: value, spec: spec)
        submit()
    }

    func update(canvasWidth: CGFloat, style: IslandStyle) {
        guard canvasWidth != self.canvasWidth || style != self.style else { return }
        synchronize()
        self.canvasWidth = canvasWidth; self.style = style
        trajectories.removeAll(keepingCapacity: true)
        submit()
    }

    func pose(at time: CFTimeInterval) -> Pose {
        snapshot(at: time).pose
    }

    func snapshot(at time: CFTimeInterval) -> State {
        var current = state
        current.step(max(0, time - stamp))
        return current
    }

    private func synchronize() {
        let time = now()
        state.step(max(0, time - stamp)); stamp = time
    }

    /// Identical element topology is required for CA's path interpolation.
    /// Unsupported geometry stays on the original renderer, never discrete jumps.
    static func topology(_ path: CGPath) -> [CGPathElementType] {
        var result: [CGPathElementType] = []
        path.applyWithBlock { result.append($0.pointee.type) }
        return result
    }

    private func submit() {
        let start = CACurrentMediaTime()
        let trajectory: Trajectory
        if let i = trajectories.firstIndex(where: { $0.start == state }) {
            trajectory = trajectories.remove(at: i)
            trajectories.insert(trajectory, at: 0)
            lastPreparationWasCached = true
        } else if let prepared = prepareTrajectory() {
            trajectory = prepared
            lastPreparationWasCached = false
            if prepared.paths.count > 1 {
                trajectories.insert(prepared, at: 0)
                if trajectories.count > Self.trajectoryCacheLimit { trajectories.removeLast() }
            }
        } else {
            ownsPath = false
            generation &+= 1
            let failedGeneration = generation
            completionDeadline = stamp
            surface?.removeAnimation(forKey: Self.animationKey)
            mask?.removeAnimation(forKey: Self.animationKey)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == failedGeneration else { return }
                self.onSettled?()
            }
            return
        }
        ownsPath = true
        generation &+= 1
        let submittedGeneration = generation
        completionDeadline = stamp + trajectory.duration
        lastSampleCount = trajectory.paths.count
        lastPreparationMilliseconds = (CACurrentMediaTime() - start) * 1000
        // Geometry samples may be reused; the animation clock is always this
        // input's absolute clock, so reuse cannot rewind or delay a retarget.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            // Cancelled/replaced animations can complete their old transaction.
            // Only the newest trajectory may perform client-side cleanup.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == submittedGeneration else { return }
                self.onSettled?()
            }
        }
        defer { CATransaction.commit() }
        setPath(trajectory.paths.last!)
        guard trajectory.paths.count > 1 else {
            surface?.removeAnimation(forKey: Self.animationKey)
            mask?.removeAnimation(forKey: Self.animationKey)
            return
        }
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = trajectory.paths
        animation.keyTimes = trajectory.keyTimes
        animation.duration = trajectory.duration
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = true
        for layer in [surface, mask].compactMap({ $0 }) {
            animation.beginTime = layer.convertTime(stamp, from: nil)
            layer.add(animation, forKey: Self.animationKey)
        }
        if FrameDriver.isLogging {
            FrameDriver.note(String(format: "native surface samples=%d prepare=%.2f ms cached=%@", trajectory.paths.count,
                                   lastPreparationMilliseconds, lastPreparationWasCached ? "yes" : "no"))
        }
    }

    private func prepareTrajectory() -> Trajectory? {
        var future = state
        var paths = [future.pose.path(canvasWidth: canvasWidth, style: style)]
        let topology = Self.topology(paths[0])
        var times = [0.0]
        // This is curve sampling, NOT a display/FPS limit. CA interpolates the
        // trajectory at the display's full rate, without client-side callbacks.
        let dt = 1.0 / 240
        var elapsed = 0.0
        while future.isActive && elapsed < 4 {
            future.step(dt); elapsed += dt
            let path = future.pose.path(canvasWidth: canvasWidth, style: style)
            guard Self.topology(path) == topology else {
                return nil
            }
            paths.append(path); times.append(elapsed)
        }
        guard !future.isActive else { return nil }
        return Trajectory(start: state, paths: paths,
                          keyTimes: elapsed > 0 ? times.map { NSNumber(value: $0 / elapsed) } : [], duration: elapsed)
    }

    private func setPath(_ path: CGPath) {
        surface?.path = path; mask?.path = path
    }
}
