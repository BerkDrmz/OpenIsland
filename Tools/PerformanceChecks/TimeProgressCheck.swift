import AppKit
import QuartzCore

@main
struct TimeProgressCheck {
    @MainActor static func main() {
        for (pixels, duration) in [(520.0, 180.0), (600, 1500), (600, 60), (100_000, 3600)] {
            let animation = ProgressPixelAnimation.make(from: 0.25, duration: duration, pixelLength: pixels)
            let values = animation.values as! [Double]
            let times = animation.keyTimes!.map(\.doubleValue)
            precondition(animation.calculationMode == .discrete)
            precondition(values.count == times.count && values.count <= 8193)
            precondition(values.first == 0.25 && values.last == 1)
            precondition(times.first == 0 && times.last == 1)
            for index in 1..<values.count {
                precondition(values[index] > values[index - 1])
                precondition(times[index] > times[index - 1])
                // Same linear clock as the original continuous animation.
                precondition(abs(values[index] - (0.25 + 0.75 * times[index])) < 1e-12)
                if pixels < 10_000 {
                    precondition((values[index] - values[index - 1]) * pixels <= 0.250001)
                }
            }
            precondition(Double(values.count - 1) / duration <= 30)
        }

        let view = TimeProgressLayerView(style: .bar)
        view.frame = CGRect(x: 0, y: 0, width: 264, height: 4)
        let timing = TimeProgressView.Timing(progress: 0.2, reference: Date(), rate: 1 / 180, isRunning: true)
        view.configure(timing: timing, tint: .white, track: .gray)
        view.layout()
        let fill = view.layer!.sublayers![1] as! CAShapeLayer
        let animation = fill.animation(forKey: "progress") as! CAKeyframeAnimation
        precondition(animation.duration > 140 && animation.duration < 145)
        for _ in 0..<1000 {
            view.configure(timing: timing, tint: .white, track: .gray)
            view.layout()
        }
        precondition(fill.animation(forKey: "progress")!.duration == animation.duration,
                     "Unchanged updates must not restart the animation")
        view.configure(timing: timing, tint: .systemOrange, track: .black)
        precondition(fill.strokeColor == NSColor.systemOrange.cgColor)
        precondition((view.layer!.sublayers![0] as! CAShapeLayer).strokeColor == NSColor.black.cgColor)
        precondition(fill.animation(forKey: "progress")!.duration == animation.duration,
                     "Changing colors must not restart progress")
        view.frame.size.width = 364
        view.layout()
        precondition((fill.animation(forKey: "progress") as! CAKeyframeAnimation).values!.count > animation.values!.count,
                     "Resize must adapt the pixel cadence")
        view.configure(timing: .init(progress: 0.2, reference: Date(), rate: 0, isRunning: false), tint: .white, track: .gray)
        precondition(!(fill.animation(forKey: "progress") is CAKeyframeAnimation), "Pause must stop scheduled progress")
        view.stopAnimation()
        precondition(fill.animationKeys()?.isEmpty != false)

        let media = ProgressPixelAnimation.make(from: 0, duration: 180, pixelLength: 520)
        let focus = ProgressPixelAnimation.make(from: 0, duration: 1500, pixelLength: 600)
        print("PASS: pixel-paced progress preserves clock/endpoints; <=0.25 physical-pixel steps; bounded storage; resize, pause and cleanup; 1000 unchanged updates")
        print("SCHEDULED CADENCE: media \(Double(media.values!.count - 1) / media.duration) changes/s; focus \(Double(focus.values!.count - 1) / focus.duration) changes/s")
    }
}
