import AppKit
import IslandCore

/// Pano panelinin içinde açılan "Bağlantıdan indir" formu. Panel boyutu değişmez (Pano içeriği 103 pt):
/// 1) bağlantı + İncele + kapat, 2) platform · başlık, 3) tür + kalite + klasör, 4) İndir/İptal + ilerleme + durum.
/// Gözlem yalnız form görünürken çalışır; iş sürerken panel kapanırsa iş sürer, yeniden açılınca güncel durum gösterilir.
@MainActor
final class LinkDownloadView: FlippedView, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    private let downloader: LinkDownloader
    private let fieldBox = RoundedView(radius: 6, fill: Palette.fill)
    private let field = NSTextField()
    private let inspect: PillButton
    private let close: PillButton
    private let info = TextLabel("Facebook, X veya TikTok video bağlantısı yapıştırın", font: Fonts.caption2, color: Palette.tertiary)
    private let videoMode: PillButton
    private let audioMode: PillButton
    private let qualityBox = RoundedView(radius: 6, fill: Palette.fill)
    private let quality = FramedPopUpButton(frame: .zero, pullsDown: false)
    private let folder: PillButton
    private let primary: PillButton
    private let reveal: PillButton
    private let shelve: PillButton
    private let track = RoundedView(radius: 2, fill: Palette.track)
    private let bar = RoundedView(radius: 2, fill: Palette.primary)
    private let status = TextLabel("", font: Fonts.caption2, color: Palette.secondary)
    private var shownOptions: [QualityOption] = []
    private lazy var observer = Observer(track: { [downloader] in
        _ = downloader.phase; _ = downloader.progress; _ = downloader.message; _ = downloader.title
        _ = downloader.videoOptions; _ = downloader.mode; _ = downloader.tier; _ = downloader.folder; _ = downloader.savedFile
    }, apply: { [weak self] in self?.update() })

    init(downloader: LinkDownloader) {
        self.downloader = downloader
        inspect = PillButton("İncele") { }
        close = PillButton(nil, symbol: "xmark") { }
        videoMode = PillButton("Video + ses") { [downloader] in downloader.mode = .videoWithAudio }
        audioMode = PillButton("Yalnız ses") { [downloader] in downloader.mode = .audioOnly }
        folder = PillButton("", symbol: "folder") { [downloader] in downloader.chooseFolder() }
        primary = PillButton("İndir", emphasized: true) { }
        reveal = PillButton("Göster") { [downloader] in downloader.revealSaved() }
        shelve = PillButton("Rafa ekle") { [downloader] in downloader.addSavedToShelf() }
        super.init(frame: .zero)
        inspect.action = { [weak self] in self?.submit() }
        close.action = { [weak self] in self?.onClose?() }
        primary.action = { [downloader] in downloader.phase.isBusy ? downloader.cancel() : downloader.download() }
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .default
        field.font = Fonts.caption
        field.textColor = Palette.primary
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.placeholderAttributedString = NSAttributedString(string: "https://… video bağlantısı",
            attributes: [.font: Fonts.caption, .foregroundColor: Palette.tertiary])
        field.setAccessibilityLabel("Video bağlantısı")
        field.delegate = self
        field.target = self
        field.action = #selector(submitFromField)
        inspect.setAccessibilityLabel("Bağlantıyı incele")
        close.setAccessibilityLabel("Pano geçmişine dön")
        close.toolTip = "Pano geçmişine dön"
        [videoMode, audioMode].forEach { $0.setAccessibilityRole(.radioButton) }
        quality.isBordered = false
        quality.font = Fonts.caption
        quality.autoenablesItems = false
        quality.target = self
        quality.action = #selector(pickQuality)
        quality.setAccessibilityLabel("Kalite")
        folder.toolTip = "Kaydetme konumu"
        primary.toolTip = "İndir"
        track.setAccessibilityElement(true)
        track.setAccessibilityRole(.progressIndicator)
        track.setAccessibilityLabel("İndirme ilerlemesi")
        bar.setAccessibilityElement(false)
        fieldBox.addSubview(field)
        qualityBox.addSubview(quality)
        track.addSubview(bar)
        [fieldBox, inspect, close, info, videoMode, audioMode, qualityBox, folder, primary, reveal, shelve, track, status].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() { observer.start() }
    func didHide() { observer.stop() }
    func focusField() { window?.makeFirstResponder(field) }

    @objc private func submitFromField() { submit() }
    private func submit() { downloader.inspect(field.stringValue) }

    @objc private func pickQuality() {
        let index = quality.indexOfSelectedItem
        guard shownOptions.indices.contains(index), shownOptions[index].isAvailable else { update(); return }
        downloader.tier = shownOptions[index].tier
    }

    private func update() {
        let d = downloader
        let busy = d.phase.isBusy
        inspect.isEnabled = !busy
        field.isEditable = !busy
        // Platform · başlık (yoksa yönerge).
        if let title = d.title, let platform = d.platform {
            info.set(platform.displayName + " · " + title)
            info.textColor = Palette.secondary
        } else {
            info.set(d.phase == .inspecting ? "Bağlantı inceleniyor…" : "Facebook, X veya TikTok video bağlantısı yapıştırın")
            info.textColor = Palette.tertiary
        }
        let inspected = d.isInspected
        [videoMode, audioMode, qualityBox, folder].forEach { $0.isHidden = !inspected }
        videoMode.setSelected(d.mode == .videoWithAudio)
        audioMode.setSelected(d.mode == .audioOnly)
        videoMode.isEnabled = !busy && d.videoOptions.contains(where: \.isAvailable)
        audioMode.isEnabled = !busy && d.audioPlan != nil
        audioMode.toolTip = d.audioPlan == nil ? "Bu videoda ses yok" : "Kaynağın ses biçimi korunur"
        if shownOptions != d.videoOptions { rebuildQuality(d.videoOptions) }
        if let i = shownOptions.firstIndex(where: { $0.tier == d.tier }) { quality.selectItem(at: i) }
        quality.isEnabled = !busy && d.mode == .videoWithAudio && !shownOptions.isEmpty
        qualityBox.isHidden = !inspected || d.mode == .audioOnly
        folder.set(title: d.folder.lastPathComponent)
        folder.isEnabled = !busy
        folder.setAccessibilityLabel("Kaydetme konumu: " + d.folder.lastPathComponent)
        // Alt satır: İndir/İptal, ilerleme, sonuç eylemleri.
        primary.isHidden = !inspected && !busy
        primary.set(title: busy ? "İptal" : "İndir")
        primary.isEnabled = busy || d.canDownload
        primary.setAccessibilityLabel(busy ? (d.phase == .inspecting ? "İncelemeyi iptal et" : "İndirmeyi iptal et") : "İndir")
        let finished = d.phase == .finished && d.savedFile != nil
        reveal.isHidden = !finished
        shelve.isHidden = !finished
        let showsBar = d.phase == .downloading || d.phase == .finalizing
        track.isHidden = !showsBar
        if let p = d.progress { track.setAccessibilityValue(String(format: "%%%d", Int((p * 100).rounded()))) } else { track.setAccessibilityValue(nil) }
        status.set(statusText())
        status.textColor = d.phase == .failed ? Palette.pulse : Palette.secondary
        needsLayout = true
    }

    private func statusText() -> String {
        let d = downloader
        switch d.phase {
        case .downloading:
            let plan = d.selectedPlan
            let format = plan.map { $0.outputExtension.uppercased() } ?? ""
            return d.progress.map { String(format: "%%%d", Int(($0 * 100).rounded())) + " · " + format } ?? format
        case .finalizing: return "Birleştiriliyor (yeniden kodlama yok)…"
        case .inspecting: return ""
        default:
            if let message = d.message { return message }
            guard let plan = d.selectedPlan else { return d.isInspected ? "Bu seçim için uygun biçim yok" : "" }
            let size = plan.estimatedBytes.map { " · ~" + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            return plan.outputExtension.uppercased() + size
        }
    }

    private func rebuildQuality(_ options: [QualityOption]) {
        shownOptions = options
        quality.removeAllItems()
        for option in options {
            quality.addItem(withTitle: option.isAvailable ? option.tier.label : option.tier.label + " — " + (option.reason ?? "kullanılamaz"))
            quality.lastItem?.isEnabled = option.isAvailable
        }
        // Kaynakta olmayan basamaklar açıkça belirtilir (büyütme yok).
        let tiers = Set(options.map(\.tier))
        var missing: [String] = []
        if !tiers.contains(.p2160) { missing.append("4K") }
        if !tiers.contains(.p1080) { missing.append("1080p") }
        quality.toolTip = missing.isEmpty ? nil : "Kaynakta yok: " + missing.joined(separator: ", ")
    }

    override func layout() {
        super.layout()
        let w = bounds.width, row: CGFloat = 22, gap: CGFloat = 6
        // 1. satır
        let closeW: CGFloat = 22
        let inspectW = inspect.preferredWidth
        close.frame = CGRect(x: w - closeW, y: 0, width: closeW, height: row)
        inspect.frame = CGRect(x: close.frame.minX - gap - inspectW, y: 0, width: inspectW, height: row)
        fieldBox.frame = CGRect(x: 0, y: 0, width: inspect.frame.minX - gap, height: row)
        let fh = TextMetrics.lineHeight(for: Fonts.caption) + 3
        field.frame = CGRect(x: 7, y: (row - fh) / 2, width: fieldBox.bounds.width - 14, height: fh)
        // 2. satır
        let y2 = row + gap
        info.frame = CGRect(x: 2, y: y2, width: w - 4, height: info.lineHeight)
        // 3. satır
        let y3 = y2 + info.lineHeight + gap
        var x: CGFloat = 0
        for b in [videoMode, audioMode] {
            b.frame = CGRect(x: x, y: y3, width: b.preferredWidth, height: row)
            x += b.preferredWidth + 4
        }
        x += gap - 4
        let folderW = min(folder.preferredWidth, 110)
        folder.frame = CGRect(x: w - folderW, y: y3, width: folderW, height: row)
        qualityBox.frame = CGRect(x: x, y: y3, width: max(0, folder.frame.minX - gap - x), height: row)
        quality.frame = qualityBox.bounds.insetBy(dx: 2, dy: 1)
        // 4. satır
        let y4 = y3 + row + gap
        let primaryW = max(primary.preferredWidth, 52)
        primary.frame = CGRect(x: 0, y: y4, width: primaryW, height: row)
        var sx = primaryW + gap
        if !reveal.isHidden {
            reveal.frame = CGRect(x: sx, y: y4, width: reveal.preferredWidth, height: row); sx += reveal.preferredWidth + 4
            shelve.frame = CGRect(x: sx, y: y4, width: shelve.preferredWidth, height: row); sx += shelve.preferredWidth + gap
        }
        if !track.isHidden {
            let tw = min(110, w - sx - 80)
            track.frame = CGRect(x: sx, y: y4 + (row - 4) / 2, width: tw, height: 4)
            bar.frame = CGRect(x: 0, y: 0, width: tw * CGFloat(downloader.progress ?? 0), height: 4)
            sx += tw + gap
        }
        status.frame = CGRect(x: sx, y: y4 + (row - status.lineHeight) / 2, width: max(0, w - sx), height: status.lineHeight)
    }

    func controlTextDidEndEditing(_ obj: Notification) {}
}

/// Dolgulu küçük düğme (simge ve/veya metin). Devre dışıyken soluk; seçili hâl daha açık dolgu.
@MainActor
final class PillButton: PlainButton {
    private let background = RoundedView(radius: 6, fill: Palette.fill)
    private let icon: SymbolView?
    private let label: TextLabel?
    private var selected = false

    init(_ title: String?, symbol: String? = nil, emphasized: Bool = false, action: @escaping () -> Void) {
        icon = symbol.map { SymbolView($0, size: 10, weight: .medium, color: Palette.primary) }
        label = title.map { TextLabel($0, font: emphasized ? Fonts.bodyEmphasized : Fonts.caption, color: Palette.primary) }
        super.init(action: action)
        addSubview(background)
        icon.map(background.addSubview)
        label.map(background.addSubview)
        label?.setAccessibilityElement(false)
        if let title { setAccessibilityLabel(title) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.4; setAccessibilityEnabled(isEnabled) } }

    func set(title: String) { label?.set(title); needsLayout = true }

    func setSelected(_ value: Bool) {
        selected = value
        background.fill = value ? Palette.fillHover : Palette.fill
        setAccessibilityValue(NSNumber(value: value ? 1 : 0))
    }

    var preferredWidth: CGFloat {
        let iconW = icon?.intrinsicContentSize.width ?? 0
        let textW = label.map { pixelCeil($0.exactWidth) } ?? 0
        return 16 + iconW + textW + (icon != nil && label != nil ? 4 : 0)
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        let iconW = icon?.intrinsicContentSize.width ?? 0
        let textW = label.map { pixelCeil($0.exactWidth) } ?? 0
        let spacing: CGFloat = icon != nil && label != nil ? 4 : 0
        var x = max(8, (bounds.width - iconW - spacing - textW) / 2)
        if let icon {
            let s = icon.intrinsicContentSize
            icon.frame = pixelRect(CGRect(x: x, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
            x += s.width + spacing
        }
        if let label {
            label.frame = CGRect(x: x, y: (bounds.height - label.lineHeight) / 2, width: min(textW, bounds.width - x - 6), height: label.lineHeight)
        }
    }
}
