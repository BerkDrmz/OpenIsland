import AppKit
import IslandCore
import QuartzCore

// Only the motion-style value used by the shared UI environment; waveform implementation is real.
enum MotionStyle { case expressive, natural, reduced }

@main
struct WaveformCheck {
    @MainActor static func main() {
        let view = WaveformLayerView()
        view.frame = CGRect(x: 0, y: 0, width: 23, height: 12)
        view.update(isPlaying: true, color: .systemOrange, reduceMotion: false)
        view.layout()
        let bars = view.layer!.sublayers!
        precondition(bars.count == CompactPulse.bars.count)
        let begins = bars.map { $0.animation(forKey: "pulse")!.beginTime }
        precondition(begins.allSatisfy { $0 == begins[0] }, "Bars must share one frame clock")
        for (index, bar) in bars.enumerated() {
            let animation = bar.animation(forKey: "pulse") as! CAKeyframeAnimation
            precondition(abs(animation.duration - CompactPulse.bars[index].cycleDuration) <= 0.5 / CompactPulse.sampleRate + 1e-9)
            for time in animation.keyTimes! {
                let frame = time.doubleValue * animation.duration * CompactPulse.sampleRate
                precondition(abs(frame - frame.rounded()) < 1e-9, "Bar updates must fall on shared frames")
            }
        }
        for _ in 0..<1000 { view.layout() }
        precondition(bars.map { $0.animation(forKey: "pulse")!.beginTime } == begins,
                     "unchanged layout must not reset the rhythm")
        let smallPositions = bars.map(\.position)
        view.frame.size = CGSize(width: 34, height: 18)
        view.layout()
        precondition(bars.map(\.position) != smallPositions)
        precondition(bars.map { $0.animation(forKey: "pulse")!.beginTime } == begins,
                     "Resize during entry must not postpone its deadline or reset the rhythm")
        for (index, bar) in bars.enumerated() {
            let animation = bar.animation(forKey: "pulse") as! CAKeyframeAnimation
            precondition(animation.calculationMode == .discrete)
            precondition(animation.keyTimes!.count == CompactPulse.sampledLevels(bar: index).count)
            let values = animation.values as! [CGFloat]
            precondition(values.allSatisfy { $0 >= 3.5 && $0 <= 18 })
            precondition(bar.position.y == 9)
        }
        // Model a pulse whose entry has completed. Repeated morph layouts must
        // retain its clock and avoid five new settle animations per layout.
        let settledBegin = CACurrentMediaTime() - 2
        for bar in bars {
            let pulse = bar.animation(forKey: "pulse")!.copy() as! CAAnimation
            pulse.beginTime = settledBegin
            bar.add(pulse, forKey: "pulse")
        }
        for index in 0..<1000 {
            view.frame.size = index.isMultiple(of: 2) ? CGSize(width: 23, height: 12) : CGSize(width: 34, height: 18)
            view.layout()
            precondition(bars.allSatisfy { $0.animation(forKey: "pulse")?.beginTime == settledBegin },
                         "Morph layouts must preserve the running phase")
            precondition(bars.allSatisfy { $0.animation(forKey: "transition") == nil },
                         "Settled playback must not restart entry transitions during a resize")
        }
        view.update(isPlaying: false, color: .systemOrange, reduceMotion: false)
        precondition(bars.allSatisfy { $0.animation(forKey: "pulse") == nil })
        view.update(isPlaying: true, color: .systemOrange, reduceMotion: true)
        precondition(bars.allSatisfy { $0.animation(forKey: "pulse") == nil })
        view.update(isPlaying: true, color: .systemOrange, reduceMotion: false)
        precondition(bars.allSatisfy { $0.animation(forKey: "pulse") != nil })
        view.stopAnimations()
        precondition(bars.allSatisfy { $0.animationKeys()?.isEmpty != false })
        view.update(isPlaying: true, color: .systemOrange, reduceMotion: false)
        precondition(bars.allSatisfy { $0.animation(forKey: "pulse") != nil })
        print("PASS: native waveform: 1000 unchanged + 1000 resize layouts preserve rhythm/entry deadline and geometry; settled resize creates no entry transitions; pause/reduced motion stop pulse; resume works")
    }
}
