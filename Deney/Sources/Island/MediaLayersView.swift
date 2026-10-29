import AppKit
import IslandCore

/// Albüm kapağı ve müzik nabzı: durumlar arasında kimliğini koruyan kalıcı katmanlar (SwiftUI `MediaLayers`).
/// Yerleri `IslandLayoutEngine` yuvalarından gelir ve yüzeyle aynı yayla canlanır. Yuva yoksa öğe saydamlıkla
/// söner; yeniden belirince `islandReveal` girişiyle (saydamlık + bulanıklık) açılır.
@MainActor
final class MediaLayersView: FlippedView {
    private let mediaController: MediaController
    private let preferences: Preferences
    private let model: IslandViewModel
    private let artwork = ArtworkLayerView()
    private let waveform = WaveformLayerView()
    private var artworkItem = SlotItem()
    private var waveformItem = SlotItem()
    private var presentation: IslandPresentation = .idle
    private var metrics: NotchMetrics?
    private var style: MotionStyle = .expressive

    init(media: MediaController, preferences: Preferences, model: IslandViewModel) {
        mediaController = media
        self.preferences = preferences
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        let noBlur = ProcessInfo.processInfo.environment["OPENISLAND_DENEY_NOBLUR"] != nil
        layerUsesCoreImageFilters = !noBlur
        addSubview(artwork)
        addSubview(waveform)
        _ = noBlur
        // Çerçeveleri yuva yaylarıyla her karede değişir; bu görünümlerin çerçeve bildirimini dinleyen yok.
        for view in [artwork, waveform] as [NSView] { view.wantsLayer = true; view.postsFrameChangedNotifications = false }
        artwork.setAccessibilityElement(true)
        artwork.setAccessibilityRole(.image)
        waveform.setAccessibilityElement(false)
        observeMedia()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // SwiftUI `.allowsHitTesting(false)`

    private func observeMedia() {
        withObservationTracking {
            _ = mediaController.nowPlaying; _ = mediaController.artwork; _ = mediaController.isPlaying
            _ = mediaController.accentColor; _ = mediaController.pulseNSColor; _ = preferences.albumColoredPulse
            _ = model.energySaving
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.mediaDidChange() } }
        }
        refreshMedia()
    }

    private func mediaDidChange() {
        observeMedia()
        if let metrics { retarget(presentation: presentation, metrics: metrics, spec: nil) }
    }

    private func refreshMedia() {
        artwork.image = mediaController.artwork
        let color = preferences.albumColoredPulse ? (mediaController.pulseNSColor ?? Palette.pulse) : Palette.pulse
        // SwiftUI `WaveformView`: Hareketi Azalt veya enerji tasarrufunda nabız durağandır.
        waveform.update(isPlaying: mediaController.isPlaying, color: color,
                        reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || model.energySaving)
        if let info = mediaController.nowPlaying {
            artwork.setAccessibilityLabel("Şimdi çalıyor: \(info.title)" + (info.artist.isEmpty ? "" : ", \(info.artist)"))
        }
        artwork.shadowColor = NSColor(mediaController.accentColor)
    }

    /// Yeni sunuma göre yuvaları hedefler. `spec` nil ise yalnız görünürlük/veri güncellenir.
    func retarget(presentation: IslandPresentation, metrics: NotchMetrics, spec: SpringSpec?, style: MotionStyle? = nil) {
        self.presentation = presentation
        self.metrics = metrics
        let hasMedia = mediaController.nowPlaying != nil
        if let style { self.style = style }
        let artSlot = hasMedia ? IslandLayoutEngine.artworkSlot(for: presentation, metrics: metrics) : nil
        let waveSlot = hasMedia ? IslandLayoutEngine.waveformSlot(for: presentation, metrics: metrics) : nil
        artworkItem.retarget(rect: artSlot?.rect, radius: artSlot?.cornerRadius ?? 0, spec: spec, style: self.style)
        waveformItem.retarget(rect: waveSlot, radius: 0, spec: spec, style: self.style)
        artwork.shadowOpacity = presentation.isExpanded ? 0.3 : 0
        refreshMedia()
    }

    func step(_ dt: Double) -> Bool {
        let a = artworkItem.step(dt)
        let w = waveformItem.step(dt)
        return a || w
    }

    func apply(surfaceWidth: CGFloat, canvasWidth: CGFloat, topInset: CGFloat) {
        let offset = CGPoint(x: (canvasWidth - surfaceWidth) / 2, y: topInset)
        artworkItem.apply(to: artwork, offset: offset) { [artwork] radius in artwork.cornerRadius = radius }
        waveformItem.apply(to: waveform, offset: offset, radius: nil)
    }
}

/// Bir medya katmanının yuvası: konum/boyut yayları + görünürlük (islandReveal).
private struct SlotItem {
    var x = Spring(0), y = Spring(0), w = Spring(0), h = Spring(0), r = Spring(0)
    var progress = Spring(0)
    var hasSlot = false

    mutating func retarget(rect: CGRect?, radius: CGFloat, spec: SpringSpec?, style: MotionStyle) {
        guard let rect else {
            if hasSlot {
                hasSlot = false
                progress.animate(to: 0, spec: DeneyMotion.contentOut(style)) // donarak söner
            }
            return
        }
        if !hasSlot {
            // Yeni görünüm: hedef konumda belirir (önceki yerinden kaymaz).
            x.set(rect.minX); y.set(rect.minY); w.set(rect.width); h.set(rect.height); r.set(radius)
            progress.set(0)
            progress.animate(to: 1, spec: DeneyMotion.contentIn(style))
            hasSlot = true
            return
        }
        if let spec {
            x.animate(to: rect.minX, spec: spec); y.animate(to: rect.minY, spec: spec)
            w.animate(to: rect.width, spec: spec); h.animate(to: rect.height, spec: spec)
            r.animate(to: radius, spec: spec)
        } else if w.target != rect.width || x.target != rect.minX {
            x.set(rect.minX); y.set(rect.minY); w.set(rect.width); h.set(rect.height); r.set(radius)
        }
    }

    mutating func step(_ dt: Double) -> Bool {
        x.step(dt); y.step(dt); w.step(dt); h.step(dt); r.step(dt); progress.step(dt)
        return x.isActive || y.isActive || w.isActive || h.isActive || r.isActive || progress.isActive
    }

    func apply(to view: NSView, offset: CGPoint, radius: ((CGFloat) -> Void)?) {
        let p = max(0, min(1, progress.value))
        let hidden = p <= 0.001
        if view.isHidden != hidden { view.isHidden = hidden }
        guard !hidden else { return } // görünmeyen katmana yazılmaz
        let frame = CGRect(x: offset.x + x.value, y: offset.y + y.value, width: max(w.value, 0), height: max(h.value, 0))
        if view.frame != frame { view.frame = frame }
        if let layer = view.layer, layer.opacity != Float(p) { layer.opacity = Float(p) }
        RevealBlur.apply(radius: hasSlot ? (1 - p) * 6 : 0, to: view.layer)
        radius?(r.value)
    }
}

/// Albüm kapağı (SwiftUI `ArtworkView`): sürekli eğrilikli köşe, 0,5 pt beyaz %8 kontur; kapak yoksa koyu degrade +
/// nota simgesi. Genişletilmiş adada vurgu renginde yumuşak gölge.
final class ArtworkLayerView: NSView {
    private let imageLayer = CALayer()
    private let placeholder = CAGradientLayer()
    private let note = SymbolView("music.note", size: 10, weight: .semibold, color: Palette.secondary)
    private let border = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        placeholder.colors = [NSColor(white: 0.24, alpha: 1).cgColor, NSColor(white: 0.14, alpha: 1).cgColor]
        placeholder.startPoint = CGPoint(x: 0, y: 1)
        placeholder.endPoint = CGPoint(x: 1, y: 0)
        for l in [imageLayer, placeholder, border] {
            l.cornerCurve = .continuous
            l.masksToBounds = true
            l.actions = IslandCanvasView.noActions
            layer?.addSublayer(l)
        }
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.minificationFilter = .trilinear
        border.borderWidth = 0.5
        border.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        addSubview(note)
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.shadowOpacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            imageLayer.contents = image
            placeholder.isHidden = image != nil
            note.isHidden = image != nil
        }
    }

    /// Doğrudan yerleştirilir (`layout()` yok): `needsLayout` kare başına pencere yerleşim geçişi tetikliyordu.
    var cornerRadius: CGFloat = 0 { didSet { if cornerRadius != oldValue { layoutLayers() } } }
    var shadowColor: NSColor = .clear { didSet { layer?.shadowColor = shadowColor.cgColor } }
    var shadowOpacity: Float = 0 { didSet { layer?.shadowOpacity = shadowOpacity } }

    override var frame: NSRect { didSet { if frame.size != oldValue.size { layoutLayers() } } }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [imageLayer, placeholder, border] {
            l.frame = bounds
            l.cornerRadius = cornerRadius
        }
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        note.setConfiguration(size: max(bounds.width * 0.38, 6), weight: .semibold)
        note.frame = note.drawingFrame(centeredIn: bounds)
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
