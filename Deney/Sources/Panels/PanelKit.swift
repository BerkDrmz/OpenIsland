import AppKit
import IslandCore

/// Gözlem yardımcısı: `track` içinde okunan Observation değerlerinden biri değişince `apply` bir kez çağrılır ve
/// yeniden abone olunur. `stop()` sonrası (panel gizlendi) gelen bildirimler yok sayılır: görünmeyen panel iş yapmaz.
@MainActor
final class Observer {
    private var generation = 0
    private var active = false
    private let track: () -> Void
    private let apply: () -> Void

    init(track: @escaping () -> Void, apply: @escaping () -> Void) {
        self.track = track
        self.apply = apply
    }

    func start() {
        guard !active else { return }
        active = true
        generation += 1
        observe(generation)
        apply()
    }

    func stop() {
        active = false
        generation += 1
    }

    private func observe(_ token: Int) {
        withObservationTracking { track() } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.active, self.generation == token else { return }
                    self.observe(token)
                    self.apply()
                }
            }
        }
    }
}

/// Tam saniye sınırlarına hizalı tek seferlik zamanlayıcı zinciri (SwiftUI `PausablePeriodicSchedule`):
/// `anchor + k` anlarında tetiklenir, yalnız `running` iken.
@MainActor
final class SecondTicker {
    private var timer: Timer?
    private let fire: () -> Void
    private var anchor = Date()

    init(fire: @escaping () -> Void) { self.fire = fire }

    func set(running: Bool, anchor: Date) {
        self.anchor = anchor
        timer?.invalidate()
        timer = nil
        if running { schedule() }
    }

    private func schedule() {
        let now = Date()
        let elapsed = now.timeIntervalSince(anchor)
        let next = anchor.addingTimeInterval(floor(elapsed) + 1)
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.fire()
                self.schedule()
            }
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    isolated deinit { timer?.invalidate() }
}

/// Düz (görünmez) tıklanabilir alan: SwiftUI `.buttonStyle(.plain)` düğmesi. Çocuk görünümler çizimi yapar.
/// Kapanan genişletilmiş içerik bir sonraki açılışta yeniden kullanılır; SwiftUI'de içerik her açılışta yeni olduğu
/// için hover/sürükleme gibi geçici durumlar kapanışta animasyonsuz sıfırlanır.
@MainActor
protocol TransientStateResettable: NSView {
    func resetTransientState()
}

class PlainButton: FlippedView {
    var action: (() -> Void)?
    var isEnabled = true
    weak var inkSymbol: SymbolView?
    /// Etiketi Label olan düz düğme: AX çerçevesi etiketinkidir (mürekkep + metin).
    weak var accessibilityFrameSource: NSView?

    override func accessibilityFrame() -> NSRect {
        if let source = accessibilityFrameSource { return source.accessibilityFrame() }
        return inkSymbol?.inkScreenFrame() ?? super.accessibilityFrame()
    }

    init(action: (() -> Void)? = nil) {
        self.action = action
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, !isHidden else { return nil }
        return frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// `NSButton` ve SwiftUI düğmesi gibi: klavye odağı yalnız "Klavyeyle gezinme" açıkken. Kapalıyken tıklanan düğme
    /// odağı almaz (odak halkası belirmez, metin alanındaki odak korunur).
    override var acceptsFirstResponder: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { super.canBecomeKeyView && isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override func accessibilityPerformPress() -> Bool { action?(); return action != nil }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { action?() } else { super.keyDown(with: event) }
    }
}

/// Boş/engelli durum yer tutucusu: simge + başlık + ortalı açıklama (en çok `maxDetailWidth`).
final class PlaceholderStack: FlippedView {
    private let icon: SymbolView
    private let title: TextLabel
    private let detail: TextLabel
    private let maxDetailWidth: CGFloat
    private let iconGap: CGFloat

    init(symbol: String, symbolSize: CGFloat = 24, title: String, detail: String, maxDetailWidth: CGFloat = 380,
         titleFont: NSFont = Fonts.bodyEmphasized, spacing: CGFloat = Spacing.s) {
        icon = SymbolView(symbol, size: symbolSize, color: Palette.tertiary)
        self.title = TextLabel(title, font: titleFont, alignment: .center)
        self.detail = TextLabel(detail, font: Fonts.caption, color: Palette.secondary, alignment: .center)
        self.detail.maximumLines = 0
        self.maxDetailWidth = maxDetailWidth
        iconGap = spacing
        super.init(frame: .zero)
        icon.exposeAsImage()
        [icon, self.title, self.detail].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func update(symbol: String, title text: String, detail detailText: String) {
        icon.set(symbol, animated: false)
        title.set(text)
        detail.set(detailText)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let s = icon.layoutSize
        let th = title.lineHeight
        let dw = min(maxDetailWidth, bounds.width)
        let dh = detail.height(forWidth: dw)
        let total = s.height + iconGap + th + iconGap + dh
        var y = (bounds.height - total) / 2
        icon.frame = icon.drawingFrame(layoutOrigin: CGPoint(x: (bounds.width - s.width) / 2, y: y))
        y += s.height + iconGap
        title.frame = pixelRect(CGRect(x: 0, y: y, width: bounds.width, height: th))
        y += th + iconGap
        detail.frame = pixelRect(CGRect(x: (bounds.width - dw) / 2, y: y, width: dw, height: dh))
    }
}

extension NSAccessibility.Role {
    /// SwiftUI `LazyVStack`/`LazyVGrid` kabının AX rolü (AX ağacı eşdeğerliği için aynı rol).
    static let opaqueProviderGroup = NSAccessibility.Role(rawValue: "AXOpaqueProviderGroup")
}

/// SwiftUI `LazyVStack`/`LazyVGrid` karşılığı belge görünümü. AppKit çocukları native AX grubu olarak gezilir;
/// AX çerçevesi SwiftUI gibi gerçekleşmiş çocukların birleşimidir (belgenin tüm yüksekliği değil).
class LazyStackView: FlippedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        // AppKit supplies these NSView children itself; this is not SwiftUI's
        // opaque accessibility provider. Use the native, navigable group role.
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func accessibilityFrame() -> NSRect {
        let frames = subviews.lazy.filter { !$0.isHidden }.map(\.frame)
        guard let window, let first = frames.first else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(frames.dropFirst().reduce(first) { $0.union($1) }, to: nil))
    }
}

/// AX çerçevesi görünüm çerçevesi olan açılır düğme (SwiftUI `Menu` gibi; hücrenin iç çerçevesi değil).
final class FramedPopUpButton: NSPopUpButton {
    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}

/// Dikey ince ayırıcı (0,5 pt).
final class SeparatorView: RoundedView {
    init() { super.init(radius: 0, fill: Palette.separator) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
