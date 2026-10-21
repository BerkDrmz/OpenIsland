import AppKit
import IslandCore

/// Genişletilmiş medya düzeni (SwiftUI `MediaPanel`). Kapak ve dalga burada çizilmez: kalıcı katmanlar aynı
/// yuvalara yerleşir; bu görünüm onlara yer ayırır. Konum izleme yalnız panel görünürken açıktır.
@MainActor
final class MediaPanelView: FlippedView, IslandPanel {
    private let media: MediaController
    private let model: IslandViewModel
    private let artworkButton = PlainButton()
    private let titleButton = PlainButton()
    private let title = TextLabel("", font: Fonts.title)
    private let subtitle = TextLabel("", font: Fonts.body, color: Palette.secondary)
    private let scrubber: MediaScrubberView
    private let previous: IconButtonView
    private let playPause: IconButtonView
    private let next: IconButtonView
    private let empty = PlaceholderStack(symbol: "music.note.list", title: "Şu anda çalan bir şey yok",
        detail: "Spotify, Müzik veya tarayıcıda bir şey başlatın. Ada üzerinde iki parmakla yatay kaydırarak parça değiştirebilirsiniz.")
    private lazy var observer = Observer(track: { [media] in
        _ = media.nowPlaying; _ = media.accentNSColor; _ = media.canSeek; _ = media.sourceApplication
    }, apply: { [weak self] in self?.update() })
    private var watchesPosition = false

    init(media: MediaController, model: IslandViewModel) {
        self.media = media
        self.model = model
        scrubber = MediaScrubberView(media: media)
        previous = IconButtonView(symbol: "backward.fill", label: "Önceki parça", size: 12) { media.previousTrack() }
        playPause = IconButtonView(symbol: "play.fill", label: "Oynat", size: 15, isProminent: true) { media.togglePlayPause() }
        next = IconButtonView(symbol: "forward.fill", label: "Sonraki parça", size: 12) { media.nextTrack() }
        super.init(frame: .zero)
        artworkButton.action = { media.revealSourceApplication() }
        titleButton.action = { media.revealSourceApplication() }
        titleButton.addSubview(title)
        titleButton.addSubview(subtitle)
        [artworkButton, titleButton, scrubber, previous, playPause, next, empty].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() { observer.start() }

    func didHide() {
        observer.stop()
        scrubber.stop()
        setPositionWatch(false)
    }

    private func setPositionWatch(_ on: Bool) {
        guard on != watchesPosition else { return }
        watchesPosition = on
        if on { media.synchronizePosition() }
        media.setPositionWatch(on)
    }

    private func update() {
        let info = media.nowPlaying
        let hasInfo = info != nil
        [artworkButton, titleButton, scrubber, previous, playPause, next].forEach { $0.isHidden = !hasInfo }
        empty.isHidden = hasInfo
        // SwiftUI'de süre çubuğunun onAppear/onDisappear'ı: yalnız çalan parça varken konum izlenir.
        setPositionWatch(hasInfo)
        guard let info else { scrubber.stop(); return }
        title.set(info.title)
        subtitle.set(info.artist.isEmpty ? info.album : info.artist)
        let app = media.sourceApplication
        for button in [artworkButton, titleButton] {
            button.isEnabled = app != nil
            button.toolTip = app?.localizedName.map { "\($0) uygulamasında aç" }
            button.setAccessibilityHelp(app?.localizedName.map { "\($0) uygulamasını öne getirir" })
        }
        titleButton.setAccessibilityLabel(info.title)
        playPause.setSymbol(info.isPlaying ? "pause.fill" : "play.fill", label: info.isPlaying ? "Duraklat" : "Oynat")
        scrubber.update(info: info, tint: media.accentNSColor, canSeek: media.canSeek)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        empty.frame = bounds
        let metrics = model.metrics
        let art = IslandLayoutEngine.artworkSlot(for: .expanded(.media), metrics: metrics)?.rect.size ?? .zero
        let wave = IslandLayoutEngine.waveformSlot(for: .expanded(.media), metrics: metrics)?.size ?? .zero
        artworkButton.frame = CGRect(origin: .zero, size: art)
        let x = art.width + IslandLayoutEngine.mediaArtworkGap
        let width = bounds.width - x
        // Başlık bloğu: başlık + 2 pt + alt başlık; dalga yuvası sağda (en az 8 pt boşluk).
        let blockHeight = title.lineHeight + Spacing.xxs + subtitle.lineHeight
        let rowHeight = max(blockHeight, wave.height)
        let textWidth = max(width - Spacing.s - wave.width, 0)
        let titleWidth = min(max(title.naturalWidth, subtitle.naturalWidth), textWidth)
        titleButton.frame = CGRect(x: x, y: 0, width: titleWidth, height: blockHeight)
        title.frame = CGRect(x: 0, y: 0, width: titleWidth, height: title.lineHeight)
        subtitle.frame = CGRect(x: 0, y: title.lineHeight + Spacing.xxs, width: titleWidth, height: subtitle.lineHeight)
        // Dikey: satır, esnek boşluk, süre çubuğu (14), esnek boşluk, denetimler.
        let big = IconButtonView.diameter(for: 15), small = IconButtonView.diameter(for: 12)
        let gap = max((art.height - rowHeight - 14 - big) / 2, 4)
        let scrubY = rowHeight + gap
        scrubber.frame = CGRect(x: x, y: scrubY, width: width, height: 14)
        let controlsY = scrubY + 14 + gap
        let total = small + 22 + big + 22 + small
        var cx = x + (width - total) / 2
        previous.frame = CGRect(x: cx, y: controlsY + (big - small) / 2, width: small, height: small)
        cx += small + 22
        playPause.frame = CGRect(x: cx, y: controlsY, width: big, height: big)
        cx += big + 22
        next.frame = CGRect(x: cx, y: controlsY + (big - small) / 2, width: small, height: small)
    }
}

/// Satır içi süre çubuğu: `1:12 ━━━━━━━━ -2:35`. Çubuk Core Animation ile akar; etiketler tam saniye
/// sınırlarında ve yalnız çalarken güncellenir. Tıklama atlar, sürükleme sarar (çubuk kalınlaşır), bırakınca seek.
@MainActor
final class MediaScrubberView: FlippedView {
    private let media: MediaController
    private let elapsedLabel = TextLabel("", font: Fonts.numericSmall, color: Palette.tertiary)
    private let remainingLabel = TextLabel("", font: Fonts.numericSmall, color: Palette.tertiary, alignment: .right)
    private let bar = TimeProgressLayerView(style: .bar)
    private let track = FlippedView()
    private var info: NowPlayingInfo?
    private var tint: NSColor = .white
    private var canSeek = false
    private var dragProgress: Double?
    private var isHovering = false
    private var thickness = Spring(4)
    private var hoverArea: NSTrackingArea?
    private lazy var ticker = SecondTicker { [weak self] in self?.updateLabels() }
    private lazy var driver = FrameDriver(view: self) { [weak self] dt in
        guard let self else { return false }
        self.thickness.step(dt)
        self.layoutBar()
        return self.thickness.isActive
    }

    init(media: MediaController) {
        self.media = media
        super.init(frame: .zero)
        track.addSubview(bar)
        [elapsedLabel, track, remainingLabel].forEach(addSubview)
        elapsedLabel.setAccessibilityElement(false)
        remainingLabel.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Süre")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func stop() { ticker.stop() }

    func update(info: NowPlayingInfo, tint: NSColor, canSeek: Bool) {
        self.info = info
        self.tint = tint
        self.canSeek = canSeek
        track.toolTip = canSeek ? nil : "Bu kaynakta ileri/geri sarma desteklenmiyor"
        applyTiming()
        updateLabels()
        let anchor = info.timestamp.addingTimeInterval(-info.elapsed.truncatingRemainder(dividingBy: 1))
        ticker.set(running: info.isPlaying && dragProgress == nil, anchor: anchor)
        updateActive()
    }

    private func applyTiming() {
        guard let info else { return }
        let rate = info.duration > 0 ? (info.playbackRate > 0 ? info.playbackRate : 1) / info.duration : 0
        let timing: TimeProgressView.Timing = if let dragProgress {
            .init(progress: dragProgress, reference: info.timestamp, rate: 0, isRunning: false)
        } else {
            .init(progress: info.duration > 0 ? info.elapsed / info.duration : 0, reference: info.timestamp,
                  rate: rate, isRunning: info.isPlaying)
        }
        bar.configure(timing: timing, tint: tint, track: .white.withAlphaComponent(0.18))
    }

    private func updateLabels() {
        guard let info else { return }
        let elapsed = dragProgress.map { $0 * info.duration } ?? info.elapsed(at: .now)
        elapsedLabel.set(elapsed.clockString)
        remainingLabel.set("-" + max(info.duration - elapsed, 0).clockString)
        setAccessibilityValue("\(elapsed.clockString) / \(info.duration.clockString)")
        needsLayout = true
    }

    private func updateActive() {
        let target: Double = canSeek && (dragProgress != nil || isHovering) ? 6 : 4
        if thickness.target != target {
            thickness.animate(to: target, spec: DeneyMotion.control)
            driver.start()
        }
    }

    override func layout() {
        super.layout()
        let ew = max(30, elapsedLabel.naturalWidth), rw = max(34, remainingLabel.naturalWidth)
        let lh = elapsedLabel.lineHeight
        elapsedLabel.frame = CGRect(x: 0, y: (bounds.height - lh) / 2, width: ew, height: lh)
        remainingLabel.frame = CGRect(x: bounds.width - rw, y: (bounds.height - lh) / 2, width: rw, height: lh)
        track.frame = CGRect(x: ew + Spacing.s, y: 0, width: max(bounds.width - ew - rw - 2 * Spacing.s, 0), height: bounds.height)
        layoutBar()
    }

    private func layoutBar() {
        let h = thickness.value
        bar.frame = CGRect(x: 0, y: (track.bounds.height - h) / 2, width: track.bounds.width, height: h)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: track.frame, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; updateActive() }
    override func mouseExited(with event: NSEvent) { isHovering = false; updateActive() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        return track.frame.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { drag(event) }
    override func mouseDragged(with event: NSEvent) { drag(event) }
    override func mouseUp(with event: NSEvent) {
        guard canSeek, let info else { return }
        if let dragProgress, info.duration > 0 { media.seek(to: dragProgress * info.duration) }
        dragProgress = nil
        applyTiming()
        update(info: info, tint: tint, canSeek: canSeek)
    }

    private func drag(_ event: NSEvent) {
        guard canSeek else { return }
        let x = track.convert(event.locationInWindow, from: nil).x
        dragProgress = min(max(x / max(track.bounds.width, 1), 0), 1)
        ticker.stop()
        applyTiming()
        updateLabels()
        updateActive()
    }

    override func accessibilityPerformIncrement() -> Bool { step(10) }
    override func accessibilityPerformDecrement() -> Bool { step(-10) }

    private func step(_ delta: TimeInterval) -> Bool {
        guard canSeek, let info else { return false }
        media.seek(to: min(max(info.elapsed(at: .now) + delta, 0), info.duration))
        return true
    }
}
