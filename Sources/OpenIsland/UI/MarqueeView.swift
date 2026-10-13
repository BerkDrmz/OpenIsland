import AppKit
import QuartzCore
import SwiftUI

/// AppKit + Core Animation tabanlı kayan müzik yazısı (Marquee).
///
/// Metin kapsayıcı genişliğine sığıyorsa tamamen statik kalır (sıfır animasyon, sıfır wakeup).
/// Taşıyorsa SwiftUI `TimelineView` yerine doğrudan Core Animation render sunucusunda
/// (`CABasicAnimation` / `CAKeyframeAnimation`) döner; ana iş parçacığı kare başına uyanmaz.
/// Duraklatıldığında veya "Hareketi Azalt" etkin olduğunda kaydırma durur, metin ilk konumunda kalır.
struct MarqueeView: View, NSViewRepresentable {
    let text: String
    var font: NSFont = .systemFont(ofSize: 14, weight: .semibold)
    var color: NSColor = .white
    var speed: CGFloat = 28.0
    var delay: CFTimeInterval = 2.0
    var trailingGap: CGFloat = 36.0
    var isPaused: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> MarqueeLayerView {
        MarqueeLayerView()
    }

    func updateNSView(_ view: MarqueeLayerView, context: Context) {
        view.update(
            text: text,
            font: font,
            color: color,
            speed: speed,
            delay: delay,
            trailingGap: trailingGap,
            isPaused: isPaused || reduceMotion
        )
    }

    static func dismantleNSView(_ view: MarqueeLayerView, coordinator: ()) {
        view.stopAnimations()
    }
}

@MainActor
final class MarqueeLayerView: NSView {
    private let contentLayer = CALayer()
    private let primaryTextLayer = CATextLayer()
    private let secondaryTextLayer = CATextLayer()

    private var text: String = ""
    private var font: NSFont = .systemFont(ofSize: 14, weight: .semibold)
    private var color: NSColor = .white
    private var speed: CGFloat = 28.0
    private var delay: CFTimeInterval = 2.0
    private var trailingGap: CGFloat = 36.0
    private var isPaused: Bool = false

    private var appliedBounds: CGRect = .zero
    private var measuredTextWidth: CGFloat = 0

    private static let scrollKey = "marqueeScroll"

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ceil(font.pointSize * 1.35))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) desteklenmiyor") }

    private func setupLayers() {
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true

        contentLayer.masksToBounds = false
        layer?.addSublayer(contentLayer)

        configureTextLayer(primaryTextLayer)
        configureTextLayer(secondaryTextLayer)
        contentLayer.addSublayer(primaryTextLayer)
        contentLayer.addSublayer(secondaryTextLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    private func configureTextLayer(_ layer: CATextLayer) {
        layer.truncationMode = .none
        layer.isWrapped = false
        layer.alignmentMode = .left
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        primaryTextLayer.contentsScale = scale
        secondaryTextLayer.contentsScale = scale
    }

    func update(
        text: String,
        font: NSFont,
        color: NSColor,
        speed: CGFloat,
        delay: CFTimeInterval,
        trailingGap: CGFloat,
        isPaused: Bool
    ) {
        let textChanged = self.text != text
        let fontChanged = self.font != font
        let colorChanged = self.color != color
        let pauseChanged = self.isPaused != isPaused

        self.text = text
        self.font = font
        self.color = color
        self.speed = speed
        self.delay = delay
        self.trailingGap = trailingGap
        self.isPaused = isPaused

        setAccessibilityLabel(text)

        if textChanged || fontChanged {
            appliedBounds = .zero
            measuredTextWidth = measureWidth(text: text, font: font)
            applyTextAndFont()
            needsLayout = true
        } else if colorChanged {
            primaryTextLayer.foregroundColor = color.cgColor
            secondaryTextLayer.foregroundColor = color.cgColor
        } else if pauseChanged {
            updateAnimationState()
        }
    }

    private func measureWidth(text: String, font: NSFont) -> CGFloat {
        let attr: [NSAttributedString.Key: Any] = [.font: font]
        let size = (text as NSString).size(withAttributes: attr)
        return ceil(size.width)
    }

    private func applyTextAndFont() {
        updateScale()
        primaryTextLayer.string = text
        primaryTextLayer.font = font
        primaryTextLayer.fontSize = font.pointSize
        primaryTextLayer.foregroundColor = color.cgColor

        secondaryTextLayer.string = text
        secondaryTextLayer.font = font
        secondaryTextLayer.fontSize = font.pointSize
        secondaryTextLayer.foregroundColor = color.cgColor
    }

    override func layout() {
        super.layout()
        guard bounds != appliedBounds else { return }
        appliedBounds = bounds
        updateScale()

        let height = bounds.height
        let textWidth = measuredTextWidth
        let overflows = textWidth > bounds.width && bounds.width > 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        contentLayer.frame = bounds
        primaryTextLayer.frame = CGRect(x: 0, y: (height - font.pointSize * 1.25) / 2, width: textWidth, height: font.pointSize * 1.35)

        if overflows {
            secondaryTextLayer.isHidden = false
            secondaryTextLayer.frame = CGRect(
                x: textWidth + trailingGap,
                y: (height - font.pointSize * 1.25) / 2,
                width: textWidth,
                height: font.pointSize * 1.35
            )
        } else {
            secondaryTextLayer.isHidden = true
            contentLayer.transform = CATransform3DIdentity
        }

        CATransaction.commit()
        updateAnimationState()
    }

    private func updateAnimationState() {
        let overflows = measuredTextWidth > bounds.width && bounds.width > 0

        if !overflows || isPaused {
            stopAnimations()
            contentLayer.transform = CATransform3DIdentity
            return
        }

        startMarqueeAnimation()
    }

    private func startMarqueeAnimation() {
        contentLayer.removeAnimation(forKey: Self.scrollKey)

        let scrollDistance = measuredTextWidth + trailingGap
        let scrollDuration = Double(scrollDistance / max(speed, 1.0))
        let totalCycle = delay + scrollDuration
        let pauseFraction = delay / totalCycle

        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.keyTimes = [0.0, NSNumber(value: pauseFraction), 1.0]
        anim.values = [0.0, 0.0, -scrollDistance]
        anim.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .linear)
        ]
        anim.duration = totalCycle
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false

        contentLayer.add(anim, forKey: Self.scrollKey)
    }

    func stopAnimations() {
        contentLayer.removeAnimation(forKey: Self.scrollKey)
    }
}
