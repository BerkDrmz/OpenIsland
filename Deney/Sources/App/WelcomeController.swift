import AppKit
import CoreText
import IslandCore
import QuartzCore

/// İlk kurulum karşılaması adanın içinde: ada çentikten açılır ve farklı dillerde "merhaba", el yazısı gibi çizilerek
/// belirir (uygulama simgesinin camgöbeği → mor → pembe renkleriyle). Ekranın geri kalanı örtülmez. Karşılama süresince
/// ada `IslandHold` ile açık tutulur; "Başla" karşılamayı söndürüp adanın kendi içeriğini gösterir ve tutmayı bırakır
/// (imleç dışarıdaysa ada her zamanki gibi kapanır). Esc ile ada kapanırsa karşılama da biter.
/// Bütün hareket Core Animation'da (render sunucusunda) çalışır; Hareketi Azalt açıksa çizim yerine yumuşak geçiş.
@MainActor
final class WelcomeController {
    struct Greeting {
        let text: String
        let font: String
    }

    static let greetings: [Greeting] = [
        Greeting(text: "merhaba", font: "SnellRoundhand-Bold"),
        Greeting(text: "hello", font: "SnellRoundhand-Bold"),
        Greeting(text: "bonjour", font: "SnellRoundhand-Bold"),
        Greeting(text: "こんにちは", font: "HiraMinProN-W6"),
        Greeting(text: "hola", font: "SnellRoundhand-Bold"),
        Greeting(text: "안녕하세요", font: "AppleSDGothicNeo-SemiBold"),
        Greeting(text: "ciao", font: "SnellRoundhand-Bold"),
        Greeting(text: "你好", font: "PingFangSC-Semibold"),
        Greeting(text: "hallo", font: "SnellRoundhand-Bold"),
        Greeting(text: "привет", font: "Baskerville-SemiBoldItalic"),
        Greeting(text: "olá", font: "SnellRoundhand-Bold"),
        Greeting(text: "مرحبا", font: "GeezaPro-Bold"),
    ]

    /// İlk kurulumda gösterilir; test kimliklerinde yalnız geliştirici doğrulaması (`OPENISLAND_WELCOME=1`) ister.
    static func shouldShowAtLaunch(welcomePending: Bool) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["OPENISLAND_WELCOME"] == "1" { return true }
        return welcomePending && !TestIsolationGuard.isValidationBundle && environment["OPENISLAND_DIAGNOSTICS"] == nil
    }

    /// Karşılamanın açıldığı sekme: geniş ve alçak gövde (yazıya uygun en-boy oranı).
    private static let tab: ExpandedTab = .media

    private let island: NotchWindowController
    private let hold: IslandHold
    private let view = WelcomeIslandView()
    private let onFinish: (_ completed: Bool) -> Void
    private var previousTab: ExpandedTab = WelcomeController.tab
    private var holding = false
    private var finished = false

    init(island: NotchWindowController, hold: IslandHold, onFinish: @escaping (_ completed: Bool) -> Void) {
        self.island = island
        self.hold = hold
        self.onFinish = onFinish
        view.onStart = { [weak self] in self?.complete() }
    }

    func start() {
        let model = island.model
        previousTab = model.machine.context.lastTab
        hold.begin()
        holding = true
        model.send(.selectTab(Self.tab))
        if !model.machine.isExpanded { model.send(.tapped) }
        // Tam ekran / gizli ada gibi açılamayan durumlar: karşılama bir sonraki açılışa kalır.
        guard model.machine.isExpanded else { end(completed: false); return }
        island.canvas.presentOverlay(view) { [weak self] in self?.end(completed: true) }
        view.start()
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
            .announcement: "Merhaba. OpenIsland'e hoş geldin. Başlamak için Başla düğmesine bas.",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// "Başla": karşılama söner, adanın kendi içeriği görünür, tutma bırakılır.
    private func complete() {
        guard !finished else { return }
        view.fadeOut { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.island.canvas.dismissOverlay()
                if self.previousTab != Self.tab { self.island.model.send(.selectTab(self.previousTab)) }
                self.end(completed: true)
            }
        }
    }

    private func end(completed: Bool) {
        guard !finished else { return }
        finished = true
        view.stop()
        if holding { holding = false; hold.end() }
        onFinish(completed)
    }
}

/// Açık adanın içindeki karşılama: siyah yüzey (ada gövdesi), ortada çizilen selamlama, altta karşılama yazısı ve
/// "Başla". Çevrilmemiş (y-yukarı) koordinat: glif yolları doğrudan kullanılır.
@MainActor
final class WelcomeIslandView: NSView {
    var onStart: (() -> Void)?
    private let stage = CALayer()
    private let host = NSView()
    private let subtitle = NSTextField(labelWithString: "OpenIsland'e hoş geldin")
    private let button = WelcomeButton(title: "Başla")
    private var index = 0
    private var timer: Timer?
    private var current: CALayer?
    private var running = false
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        host.layer = stage
        host.wantsLayer = true
        addSubview(host)
        subtitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        subtitle.textColor = NSColor(white: 1, alpha: 0.86)
        subtitle.alphaValue = 0
        addSubview(subtitle)
        button.alphaValue = 0
        button.action = { [weak self] in self?.onStart?() }
        addSubview(button)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("OpenIsland'e hoş geldin")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func layout() {
        super.layout()
        host.frame = bounds
        stage.contentsScale = window?.backingScaleFactor ?? 2
        subtitle.sizeToFit()
        let footerY: CGFloat = 16
        subtitle.frame = CGRect(x: 24, y: footerY + (30 - subtitle.frame.height) / 2,
                                width: subtitle.frame.width, height: subtitle.frame.height)
        button.frame = CGRect(x: bounds.width - 24 - 92, y: footerY, width: 92, height: 30)
        if let current { current.frame = greetingFrame(for: current.bounds.size) }
    }

    /// Selamlamanın alanı: çentik/başlık şeridinin altı, alt satırın üstü.
    private var greetingBox: CGRect {
        CGRect(x: 28, y: 58, width: bounds.width - 56, height: max(bounds.height - 58 - 40, 40))
    }

    private func greetingFrame(for size: CGSize) -> CGRect {
        let box = greetingBox
        return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
    }

    func start() {
        guard !running else { return }
        running = true
        layoutSubtreeIfNeeded()
        playNext()
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    func fadeOut(_ completion: @escaping @Sendable () -> Void) {
        stop()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0.15 : 0.3
            animator().alphaValue = 0
        }, completionHandler: completion)
    }

    /// Bir sonraki selamlama; ilkinden sonra alt satır belirir. "Başla"ya kadar döner.
    private func playNext() {
        guard running else { return }
        let greeting = WelcomeController.greetings[index % WelcomeController.greetings.count]
        let first = index == 0
        index += 1
        let draw: CFTimeInterval = reduceMotion ? 0 : (first ? 2.0 : 1.4)
        let hold: CFTimeInterval = first ? 1.2 : 0.9
        let fadeOut: CFTimeInterval = 0.4
        if let current { dissolve(current, duration: fadeOut) }
        let layer = makeGreetingLayer(greeting, draw: draw)
        current = layer
        stage.addSublayer(layer)
        if index == 2 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                subtitle.animator().alphaValue = 1
                button.animator().alphaValue = 1
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: draw + hold + fadeOut * 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.playNext() }
        }
    }

    private func makeGreetingLayer(_ greeting: WelcomeController.Greeting, draw: CFTimeInterval) -> CALayer {
        let raw = Self.path(for: greeting.text, fontName: greeting.font, size: 120)
        let box = raw.boundingBoxOfPath
        let area = greetingBox
        let s = min(area.width * 0.86 / max(box.width, 1), area.height * 0.92 / max(box.height, 1))
        let pad: CGFloat = 4
        var transform = CGAffineTransform(translationX: pad, y: pad).scaledBy(x: s, y: s).translatedBy(x: -box.minX, y: -box.minY)
        guard let path = raw.copy(using: &transform) else { return CALayer() }
        let size = CGSize(width: box.width * s + 2 * pad, height: box.height * s + 2 * pad)

        let group = CALayer()
        group.frame = greetingFrame(for: size)
        group.contentsScale = stage.contentsScale

        let strokeMask = CAShapeLayer()
        strokeMask.path = path
        strokeMask.fillColor = nil
        strokeMask.strokeColor = NSColor.white.cgColor
        strokeMask.lineWidth = max(1.1, min(2, size.height / 60))
        strokeMask.lineCap = .round
        strokeMask.lineJoin = .round
        let stroke = gradientLayer(frame: group.bounds, mask: strokeMask)

        let fillMask = CAShapeLayer()
        fillMask.path = path
        fillMask.fillColor = NSColor.white.cgColor
        let fill = gradientLayer(frame: group.bounds, mask: fillMask)

        group.addSublayer(stroke)
        group.addSublayer(fill)

        if draw > 0 {
            // El yazısı: dış çizgi baştan sona çizilir, sonra iç dolgu belirir.
            let trace = CABasicAnimation(keyPath: "strokeEnd")
            trace.fromValue = 0
            trace.toValue = 1
            trace.duration = draw
            trace.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0.05, 0.35, 1)
            strokeMask.add(trace, forKey: "trace")
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.beginTime = CACurrentMediaTime() + draw * 0.62
            appear.duration = draw * 0.5
            appear.fillMode = .backwards
            appear.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fill.add(appear, forKey: "appear")
        } else {
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = 0.4
            group.add(appear, forKey: "appear")
        }
        return group
    }

    private func gradientLayer(frame: CGRect, mask: CAShapeLayer) -> CAGradientLayer {
        let gradient = CAGradientLayer()
        gradient.frame = frame
        gradient.contentsScale = stage.contentsScale
        gradient.colors = [Self.color(0x36D1FF), Self.color(0x7A6CFF), Self.color(0xFF5FB8)]
        gradient.locations = [0, 0.5, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        mask.frame = gradient.bounds
        mask.contentsScale = stage.contentsScale
        gradient.mask = mask
        return gradient
    }

    /// Selamlama hafifçe yukarı kayıp küçülerek söner, sonra kaldırılır.
    private func dissolve(_ layer: CALayer, duration: CFTimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let lift = CABasicAnimation(keyPath: "transform")
        lift.fromValue = CATransform3DIdentity
        lift.toValue = reduceMotion ? CATransform3DIdentity
            : CATransform3DConcat(CATransform3DMakeScale(0.97, 0.97, 1), CATransform3DMakeTranslation(0, 6, 0))
        let group = CAAnimationGroup()
        group.animations = [fade, lift]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.opacity = 0
        layer.add(group, forKey: "dissolve")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak layer] in
            MainActor.assumeIsolated { layer?.removeFromSuperlayer() }
        }
    }

    /// Metnin glif dış hatları tek yolda (Core Text yazı tipi yedeklemesiyle; sağdan sola yazılar sağdan çizilir).
    static func path(for text: String, fontName: String, size: CGFloat) -> CGPath {
        let font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size, weight: .semibold)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let path = CGMutablePath()
        let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? (font as CTFont)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            var order = Array(0..<count)
            if CTRunGetStatus(run).contains(.rightToLeft) { order.reverse() }
            for i in order {
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                path.addPath(glyph, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
            }
        }
        return path
    }

    private static func color(_ hex: UInt32) -> CGColor {
        NSColor(displayP3Red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1).cgColor
    }
}

/// Adanın görünümünde düğme: siyah kapsül, simgedeki renkli halka, beyaz yazı. Fare ve VoiceOver ile basılır; Tab ile
/// gelen klavye odağı sistem halkasıyla görünür.
final class WelcomeButton: NSView {
    var action: (() -> Void)?
    private let ring = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private let body = CAShapeLayer()
    private let label = CATextLayer()
    private var hovering = false { didSet { updateAppearance() } }
    private var pressed = false { didSet { updateAppearance() } }

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        ring.colors = [NSColor(displayP3Red: 0.21, green: 0.82, blue: 1, alpha: 1).cgColor,
                       NSColor(displayP3Red: 0.48, green: 0.42, blue: 1, alpha: 1).cgColor,
                       NSColor(displayP3Red: 1, green: 0.37, blue: 0.72, alpha: 1).cgColor]
        ring.startPoint = CGPoint(x: 0, y: 0.5)
        ring.endPoint = CGPoint(x: 1, y: 0.5)
        ring.mask = ringMask
        body.fillColor = NSColor.black.cgColor
        label.string = title
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.fontSize = 13
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        [ring, body, label].forEach { layer?.addSublayer($0) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func layout() {
        super.layout()
        let r = bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ringMask.frame = bounds
        ringMask.path = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        let inner = bounds.insetBy(dx: 1.5, dy: 1.5)
        body.frame = bounds
        body.path = CGPath(roundedRect: inner, cornerWidth: inner.height / 2, cornerHeight: inner.height / 2, transform: nil)
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.frame = CGRect(x: 0, y: (bounds.height - 17) / 2, width: bounds.width, height: 17)
        CATransaction.commit()
    }

    private func updateAppearance() {
        body.fillColor = NSColor(white: pressed ? 0.18 : (hovering ? 0.1 : 0), alpha: 1).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override var acceptsFirstResponder: Bool { acceptsKeyboardFocus } // tıklamayla odak (mavi halka) yok
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
    override func accessibilityPerformPress() -> Bool { action?(); return true }
}
