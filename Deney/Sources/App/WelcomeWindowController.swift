import AppKit
import CoreText
import QuartzCore

/// İlk kurulum karşılaması: farklı dillerde "merhaba", el yazısı gibi çizilerek belirir; renkler uygulama simgesinin
/// (koyu gece mavisi zemin, camgöbeği → mor → pembe parıltı). Ekranı kaplayan pencere adanın bir seviye altındadır:
/// ada üstte görünür kalır. Bütün hareket Core Animation'da (render sunucusunda) çalışır; ana iş parçacığı yalnız her
/// selamlamanın başında katmanları kurar. Hareketi Azalt açıksa çizim yerine yumuşak geçiş kullanılır.
/// "Başla", Return, Boşluk ya da Esc kapatır; kapanınca bir daha kendiliğinden açılmaz (menüden yeniden oynatılır).
@MainActor
final class WelcomeWindowController: NSObject {
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

    private let window: WelcomeWindow
    private let stage = CALayer()
    private let subtitle = NSTextField(labelWithString: "OpenIsland'e hoş geldin")
    private let hint = NSTextField(labelWithString: "İmleci ekranın üstündeki çentiğe getir; ada açılır.")
    private let button = WelcomeButton(title: "Başla")
    private let onFinish: () -> Void
    private var index = 0
    private var timer: Timer?
    private var current: CALayer?
    private var finished = false
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        let screen = NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main ?? NSScreen.screens[0]
        window = WelcomeWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.setFrame(screen.frame, display: false)
        // Ada `.mainMenu + 3`'te: karşılama menü çubuğunu örter, adanın altında kalır.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.alphaValue = 0
        window.onDismiss = { [weak self] in self?.finish() }
        buildContent(size: screen.frame.size, scale: screen.backingScaleFactor)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Düğme odakla açılmaz (fareyle görünür mavi halka olmasın): Return/Boşluk/Esc pencerede karşılanır, Tab ile
        // gelen klavye kullanıcısı halkayı görür, VoiceOver düğmeyi bulur.
        window.makeFirstResponder(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.25 : 0.6
            window.animator().alphaValue = 1
        }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: "Merhaba. OpenIsland'e hoş geldin. Başlamak için Başla düğmesine bas.",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        playNext()
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Sahne

    private func buildContent(size: CGSize, scale: CGFloat) {
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        content.setAccessibilityElement(true)
        content.setAccessibilityRole(.group)
        content.setAccessibilityLabel("OpenIsland'e hoş geldin")
        window.contentView = content

        // Katman barındıran görünüm: katmanları AppKit değil bu denetleyici yönetir.
        let host = NSView(frame: content.bounds)
        host.layer = stage
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        stage.contentsScale = scale

        let background = CAGradientLayer()
        background.frame = CGRect(origin: .zero, size: size)
        background.colors = [Self.color(0x07080F), Self.color(0x12152E), Self.color(0x283066)]
        background.locations = [0, 0.55, 1]
        background.startPoint = CGPoint(x: 0.5, y: 0)
        background.endPoint = CGPoint(x: 0.5, y: 1)
        stage.addSublayer(background)
        // Çentikten gelen yumuşak ışık (simgedeki hale).
        let halo = CAGradientLayer()
        halo.type = .radial
        halo.colors = [Self.color(0x7F8CFF, 0.28), Self.color(0x7F8CFF, 0)]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        let haloSize = CGSize(width: size.width * 1.1, height: size.height * 1.2)
        halo.frame = CGRect(x: (size.width - haloSize.width) / 2, y: size.height - haloSize.height * 0.62,
                            width: haloSize.width, height: haloSize.height)
        stage.addSublayer(halo)

        subtitle.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        subtitle.textColor = NSColor(white: 1, alpha: 0.88)
        hint.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        hint.textColor = NSColor(white: 1, alpha: 0.55)
        for label in [subtitle, hint] {
            label.alignment = .center
            label.sizeToFit()
            label.alphaValue = 0
            content.addSubview(label)
        }
        let base = size.height * 0.30
        subtitle.frame = CGRect(x: 0, y: base, width: size.width, height: subtitle.frame.height)
        hint.frame = CGRect(x: 0, y: base - 30, width: size.width, height: hint.frame.height)

        button.frame = CGRect(x: (size.width - 168) / 2, y: base - 112, width: 168, height: 46)
        button.alphaValue = 0
        button.action = { [weak self] in self?.finish() }
        content.addSubview(button)
    }

    /// Bir sonraki selamlama; ilk turdan sonra alt yazı ve düğme belirir. Kullanıcı Başla diyene kadar döner.
    private func playNext() {
        guard !finished else { return }
        let greeting = Self.greetings[index % Self.greetings.count]
        let first = index == 0
        index += 1
        let draw: CFTimeInterval = reduceMotion ? 0 : (first ? 2.2 : 1.5)
        let hold: CFTimeInterval = first ? 1.3 : 0.9
        let fadeOut: CFTimeInterval = 0.45

        let previous = current
        if let previous { dissolve(previous, duration: fadeOut) }
        let layer = makeGreetingLayer(greeting, draw: draw)
        current = layer
        stage.addSublayer(layer)

        if index == 2 { revealFooter() }
        timer = Timer.scheduledTimer(withTimeInterval: draw + hold + fadeOut * 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.playNext() }
        }
    }

    private func makeGreetingLayer(_ greeting: Greeting, draw: CFTimeInterval) -> CALayer {
        let bounds = stage.bounds
        let raw = Self.path(for: greeting.text, fontName: greeting.font, size: 200)
        let box = raw.boundingBoxOfPath
        let maxWidth = bounds.width * 0.62, maxHeight = bounds.height * 0.24
        let s = min(maxWidth / max(box.width, 1), maxHeight / max(box.height, 1))
        var transform = CGAffineTransform(scaleX: s, y: s).translatedBy(x: -box.minX, y: -box.minY)
        guard let path = raw.copy(using: &transform) else { return CALayer() }
        let size = CGSize(width: box.width * s, height: box.height * s)
        let pad: CGFloat = 12
        let frame = CGRect(x: (bounds.width - size.width) / 2 - pad, y: bounds.height * 0.5 - size.height * 0.35 - pad,
                           width: size.width + 2 * pad, height: size.height + 2 * pad)
        var shift = CGAffineTransform(translationX: pad, y: pad)
        let local = path.copy(using: &shift) ?? path

        let group = CALayer()
        group.frame = frame
        group.contentsScale = stage.contentsScale

        let strokeMask = CAShapeLayer()
        strokeMask.path = local
        strokeMask.fillColor = nil
        strokeMask.strokeColor = NSColor.white.cgColor
        strokeMask.lineWidth = max(1.6, min(3.2, size.height / 70))
        strokeMask.lineCap = .round
        strokeMask.lineJoin = .round
        let stroke = gradientLayer(frame: group.bounds, mask: strokeMask)

        let fillMask = CAShapeLayer()
        fillMask.path = local
        fillMask.fillColor = NSColor.white.cgColor
        let fill = gradientLayer(frame: group.bounds, mask: fillMask)

        group.addSublayer(stroke)
        group.addSublayer(fill)

        let now = CACurrentMediaTime()
        if draw > 0 {
            // El yazısı: dış çizgi baştan sona çizilir, sonra iç dolgu belirir.
            let trace = CABasicAnimation(keyPath: "strokeEnd")
            trace.fromValue = 0
            trace.toValue = 1
            trace.duration = draw
            trace.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0.05, 0.35, 1)
            strokeMask.strokeEnd = 1
            strokeMask.add(trace, forKey: "trace")
            fill.opacity = 1
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.beginTime = now + draw * 0.62
            appear.duration = draw * 0.5
            appear.fillMode = .backwards
            appear.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fill.add(appear, forKey: "appear")
        } else {
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = 0.5
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
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let lift = CABasicAnimation(keyPath: "transform")
        lift.fromValue = CATransform3DIdentity
        lift.toValue = reduceMotion ? CATransform3DIdentity
            : CATransform3DConcat(CATransform3DMakeScale(0.97, 0.97, 1), CATransform3DMakeTranslation(0, 10, 0))
        let group = CAAnimationGroup()
        group.animations = [fade, lift]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.opacity = 0
        layer.add(group, forKey: "dissolve")
        CATransaction.commit()
    }

    private func revealFooter() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            subtitle.animator().alphaValue = 1
            hint.animator().alphaValue = 1
            button.animator().alphaValue = 1
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0.2 : 0.5
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window.orderOut(nil)
                self.stage.sublayers?.forEach { $0.removeAllAnimations() }
                self.window.contentView = nil
                self.window.close()
                NSApp.deactivate()
                self.onFinish()
            }
        })
    }

    // MARK: - Yazı yolu

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

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        NSColor(displayP3Red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha).cgColor
    }
}

/// Kenarlıksız ama klavye alabilen tam ekran pencere: Return/Boşluk/Esc karşılamayı kapatır.
final class WelcomeWindow: NSWindow {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 49, 53: onDismiss?() // Return, Enter, Boşluk, Esc
        default: super.keyDown(with: event)
        }
    }
}

/// Adanın görünümünde düğme: siyah kapsül, simgedeki renkli halka, beyaz yazı. Klavye ve VoiceOver ile basılır.
final class WelcomeButton: NSView {
    var action: (() -> Void)?
    private let title: String
    private let ring = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private let body = CAShapeLayer()
    private let label = CATextLayer()
    private var hovering = false { didSet { updateAppearance() } }
    private var pressed = false { didSet { updateAppearance() } }

    init(title: String) {
        self.title = title
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
        label.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        label.fontSize = 16
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
        let scale = window?.backingScaleFactor ?? 2
        let r = bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ringMask.frame = bounds
        ringMask.path = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        let inner = bounds.insetBy(dx: 2, dy: 2)
        body.frame = bounds
        body.path = CGPath(roundedRect: inner, cornerWidth: inner.height / 2, cornerHeight: inner.height / 2, transform: nil)
        label.contentsScale = scale
        label.frame = CGRect(x: 0, y: (bounds.height - 21) / 2, width: bounds.width, height: 21)
        CATransaction.commit()
    }

    private func updateAppearance() {
        body.fillColor = NSColor(white: pressed ? 0.16 : (hovering ? 0.08 : 0), alpha: 1).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { hovering = false; NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
    override func accessibilityPerformPress() -> Bool { action?(); return true }
}
