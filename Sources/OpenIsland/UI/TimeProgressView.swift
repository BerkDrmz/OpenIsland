import AppKit
import QuartzCore
import SwiftUI

/// Zamana bağlı ilerleme (şarkı süresi, Pomodoro halkası).
///
/// Değer kare kare SwiftUI'da hesaplanmaz: kalan süre boyunca tek bir piksel adımlı animasyon kurulur ve
/// render sunucusunda akar. Oynatma sürerken uygulama süreci hiç uyanmaz; yalnızca durum değiştiğinde
/// (duraklat, atla, sar, parça değişimi) animasyon yeniden kurulur.
/// Zaman doğrusal aktığı için burada `.linear` zamanlama fiziksel olarak doğru olandır.
struct TimeProgressView: NSViewRepresentable {
    enum Style: Equatable {
        case bar
        case ring(lineWidth: CGFloat)
    }

    struct Timing: Equatable {
        /// `reference` anındaki ilerleme (0...1).
        var progress: Double
        var reference: Date
        /// Saniyedeki ilerleme (1 / toplam süre × hız).
        var rate: Double
        var isRunning: Bool

        func value(at date: Date) -> Double {
            let raw = progress + (isRunning ? date.timeIntervalSince(reference) * rate : 0)
            return min(max(raw, 0), 1)
        }
    }

    let style: Style
    let timing: Timing
    let tint: NSColor
    var track: NSColor = .white.withAlphaComponent(0.18)

    func makeNSView(context: Context) -> TimeProgressLayerView {
        TimeProgressLayerView(style: style)
    }

    func updateNSView(_ view: TimeProgressLayerView, context: Context) {
        view.configure(timing: timing, tint: tint, track: track)
    }

    static func dismantleNSView(_ view: TimeProgressLayerView, coordinator: ()) {
        view.stopAnimation()
    }
}

@MainActor
final class TimeProgressLayerView: NSView {
    private static let progressKey = "progress"
    private let style: TimeProgressView.Style
    private let trackLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()
    private var timing: TimeProgressView.Timing?
    private var lastBounds: CGRect = .zero
    private var lastScale: CGFloat = 0

    init(style: TimeProgressView.Style) {
        self.style = style
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        for shapeLayer in [trackLayer, fillLayer] {
            shapeLayer.fillColor = nil
            shapeLayer.lineCap = .round
            layer?.addSublayer(shapeLayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) desteklenmiyor") }

    func configure(timing: TimeProgressView.Timing, tint: NSColor, track: NSColor) {
        // SwiftUI can update labels without changing these colors. Avoid issuing
        // redundant layer mutations/transactions for that unchanged appearance.
        let trackColor = track.cgColor
        let tintColor = tint.cgColor
        if trackLayer.strokeColor != trackColor { trackLayer.strokeColor = trackColor }
        if fillLayer.strokeColor != tintColor { fillLayer.strokeColor = tintColor }
        guard timing != self.timing else { return }
        self.timing = timing
        restartAnimation()
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        guard bounds != lastBounds || scale != lastScale else { return }
        lastBounds = bounds
        lastScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        let lineWidth: CGFloat
        switch style {
        case .bar:
            lineWidth = bounds.height
            path.move(to: CGPoint(x: lineWidth / 2, y: bounds.midY))
            path.addLine(to: CGPoint(x: max(bounds.width - lineWidth / 2, lineWidth / 2), y: bounds.midY))
        case .ring(let width):
            lineWidth = width
            let radius = max(min(bounds.width, bounds.height) / 2 - width / 2, 0)
            // Saat 12'den saat yönünde (AppKit y-yukarı koordinatında clockwise: true).
            path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                        startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        }
        for shapeLayer in [trackLayer, fillLayer] {
            shapeLayer.frame = bounds
            shapeLayer.path = path
            shapeLayer.lineWidth = lineWidth
        }
        CATransaction.commit()
        // A new geometry needs a new pixel cadence, but uses the same absolute
        // clock. Resizing or moving to another display must not restart progress.
        if timing?.isRunning == true { restartAnimation() }
    }

    func stopAnimation() { fillLayer.removeAnimation(forKey: Self.progressKey) }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    private func restartAnimation() {
        guard let timing else { return }
        let current = timing.value(at: Date())
        let displayed = CGFloat(fillLayer.presentation()?.strokeEnd ?? fillLayer.strokeEnd)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.removeAnimation(forKey: Self.progressKey)
        fillLayer.strokeEnd = current
        CATransaction.commit()

        // Kesikli değerler (ör. indirme yüzdesi) sıçramasın: gösterilen değerden yeni değere yay ile.
        if !timing.isRunning, abs(displayed - current) > 0.001 {
            let spring = CASpringAnimation(keyPath: "strokeEnd")
            spring.fromValue = displayed
            spring.toValue = current
            spring.stiffness = 220
            spring.damping = 30
            spring.duration = spring.settlingDuration
            fillLayer.add(spring, forKey: Self.progressKey)
        }

        guard timing.isRunning, timing.rate > 0, current < 1 else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let length: CGFloat
        switch style {
        case .bar: length = max(bounds.width - bounds.height, 0)
        case .ring(let width): length = .pi * max(min(bounds.width, bounds.height) - width, 0)
        }
        let duration = (1 - current) / timing.rate
        let animation = ProgressPixelAnimation.make(from: current, duration: duration,
                                                    pixelLength: Double(length * (window?.backingScaleFactor ?? 2)))
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        fillLayer.add(animation, forKey: Self.progressKey)
    }
}

/// A quarter of a physical pixel is below a visible jump. Unlike a frame-rate hint
/// on a continuous animation, discrete keyframes do not change between samples.
/// This is built once on timing/geometry changes, with bounded memory and no timer.
enum ProgressPixelAnimation {
    static func make(from progress: Double, duration: Double, pixelLength: Double) -> CAKeyframeAnimation {
        let remainingPixels = max(pixelLength, 0) * max(1 - progress, 0)
        let pixelSteps = ceil(remainingPixels * 4)
        let frameSteps = floor(max(duration, 0) * 30)
        let steps = Int(min(max(min(pixelSteps, frameSteps), 1), 8192))
        let animation = CAKeyframeAnimation(keyPath: "strokeEnd")
        animation.values = (0...steps).map { progress + (1 - progress) * Double($0) / Double(steps) }
        animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        animation.duration = duration
        animation.calculationMode = .discrete
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 30, preferred: 30)
        return animation
    }
}

/// Duraklatılabilen, belirli bir çapaya hizalı periyodik `TimelineView` takvimi.
/// Örn. geri sayım metni tam saniye sınırlarında güncellenir; duraklatıldığında hiç güncellenmez.
struct PausablePeriodicSchedule: TimelineSchedule {
    let anchor: Date
    let interval: TimeInterval
    let isPaused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var emittedStart = false
        if isPaused {
            return AnyIterator {
                guard !emittedStart else { return nil }
                emittedStart = true
                return startDate
            }
        }
        let steps = (startDate.timeIntervalSince(anchor) / interval).rounded(.down) + 1
        var next = anchor.addingTimeInterval(steps * interval)
        let interval = interval
        return AnyIterator {
            if !emittedStart {
                emittedStart = true
                return startDate
            }
            defer { next = next.addingTimeInterval(interval) }
            return next
        }
    }
}
