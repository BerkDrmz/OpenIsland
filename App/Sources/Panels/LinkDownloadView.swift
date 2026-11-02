import AppKit
import IslandCore

/// Pano panelinin içinde açılan "Bağlantıdan indir" formu. Panel boyutu değişmez (Pano içeriği 103 pt):
/// 1) bağlantı + İncele + kapat, 2) platform · başlık, 3) tür (Video + ses / Yalnız video / Yalnız ses) + kalite +
/// klasör, 4) İndir/İptal + ilerleme + durum. YouTube motoru yoksa 2. ve 4. satır onay ister (Motoru indir / Vazgeç).
/// Gözlem yalnız form görünürken çalışır; iş sürerken panel kapanırsa iş sürer, yeniden açılınca güncel durum gösterilir.
@MainActor
final class LinkDownloadView: FlippedView, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    private let downloader: LinkDownloader
    private let fieldBox = RoundedView(radius: 6, fill: Palette.fill)
    private let field = NSTextField()
    private let inspect: PillButton
    private let close: PillButton
    private static let prompt = LinkPlatform.supportedNames + " bağlantısı yapıştırın"
    /// Tür seçicisi en geniş başlığa göre bir kez ölçülür (ok ve iç boşluk dahil).
    private static let modeWidth: CGFloat = pixelCeil(DownloadMode.allCases.map {
        ($0.title as NSString).size(withAttributes: [.font: Fonts.caption]).width
    }.max() ?? 60) + 30
    private let info = TextLabel(LinkDownloadView.prompt, font: Fonts.caption2, color: Palette.tertiary)
    private let modeBox = RoundedView(radius: 6, fill: Palette.fill)
    private let modePicker = FramedPopUpButton(frame: .zero, pullsDown: false)
    private let qualityBox = RoundedView(radius: 6, fill: Palette.fill)
    private let quality = FramedPopUpButton(frame: .zero, pullsDown: false)
    private let folder: PillButton
    private let primary: PillButton
    private let reveal: PillButton
    private let shelve: PillButton
    private let decline: PillButton
    private let updateEngine: PillButton
    private let track = RoundedView(radius: 2, fill: Palette.track)
    private let bar = RoundedView(radius: 2, fill: Palette.primary)
    private let status = TextLabel("", font: Fonts.caption2, color: Palette.secondary)
    private var shownOptions: [QualityOption] = []
    private lazy var observer = Observer(track: { [downloader] in
        _ = downloader.phase; _ = downloader.progress; _ = downloader.message; _ = downloader.title
        _ = downloader.videoOptions; _ = downloader.videoOnlyOptions; _ = downloader.audioPlan; _ = downloader.mode; _ = downloader.tier
        _ = downloader.folder; _ = downloader.savedFile; _ = downloader.canUpdateEngine
    }, apply: { [weak self] in self?.update() })

    init(downloader: LinkDownloader) {
        self.downloader = downloader
        inspect = PillButton("İncele") { }
        close = PillButton(nil, symbol: "xmark") { }
        folder = PillButton("", symbol: "folder") { [downloader] in downloader.chooseFolder() }
        primary = PillButton("İndir", emphasized: true) { }
        reveal = PillButton("Göster") { [downloader] in downloader.revealSaved() }
        shelve = PillButton("Rafa ekle") { [downloader] in downloader.addSavedToShelf() }
        decline = PillButton("Vazgeç") { [downloader] in downloader.declineEngine() }
        updateEngine = PillButton("Motoru güncelle") { [downloader] in downloader.updateEngine() }
        super.init(frame: .zero)
        inspect.action = { [weak self] in self?.submit() }
        close.action = { [weak self] in self?.onClose?() }
        primary.action = { [downloader] in
            if downloader.phase == .needsEngine { downloader.installEngine() }
            else if downloader.phase.isBusy { downloader.cancel() } else { downloader.download() }
        }
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
        modePicker.isBordered = false
        modePicker.font = Fonts.caption
        modePicker.autoenablesItems = false
        modePicker.target = self
        modePicker.action = #selector(pickMode)
        modePicker.setAccessibilityLabel("Tür")
        for mode in DownloadMode.allCases { modePicker.addItem(withTitle: mode.title) }
        decline.toolTip = "YouTube motoru indirilmez"
        updateEngine.toolTip = "YouTube motorunun son sürümünü indirir (GitHub, SHA-256 doğrulamalı)"
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
        modeBox.addSubview(modePicker)
        qualityBox.addSubview(quality)
        track.addSubview(bar)
        [fieldBox, inspect, close, info, modeBox, qualityBox, folder, primary, reveal, shelve, decline, updateEngine, track, status].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() { observer.start() }
    func didHide() { observer.stop() }
    func focusField() { window?.makeFirstResponder(field) }

    @objc private func submitFromField() { submit() }
    private func submit() { downloader.inspect(field.stringValue) }

    @objc private func pickMode() {
        let modes = DownloadMode.allCases, index = modePicker.indexOfSelectedItem
        guard modes.indices.contains(index) else { update(); return }
        downloader.select(modes[index])
        update()
    }

    @objc private func pickQuality() {
        let index = quality.indexOfSelectedItem
        guard shownOptions.indices.contains(index), shownOptions[index].isAvailable else { update(); return }
        downloader.tier = shownOptions[index].tier
    }

    func update() {
        let d = downloader
        let busy = d.phase.isBusy
        inspect.isEnabled = !busy
        field.isEditable = !busy
        // Platform · başlık (yoksa yönerge).
        let engineStep = d.phase == .needsEngine || d.phase == .installingEngine
        if engineStep {
            let size = ByteCountFormatter.string(fromByteCount: YouTubeEngine.downloadBytes, countStyle: .file)
            info.set(d.phase == .needsEngine ? "YouTube motoru gerekli: \(size), yalnız YouTube'da çalışır" : "YouTube motoru indiriliyor ve doğrulanıyor…")
            info.textColor = Palette.secondary
        } else if let title = d.title, let platform = d.platform {
            info.set(platform.displayName + " · " + title)
            info.textColor = Palette.secondary
        } else {
            info.set(d.phase == .inspecting ? "Bağlantı inceleniyor…" : Self.prompt)
            info.textColor = Palette.tertiary
        }
        let inspected = d.isInspected && !engineStep
        [modeBox, qualityBox, folder].forEach { $0.isHidden = !inspected }
        for (i, mode) in DownloadMode.allCases.enumerated() {
            let item = modePicker.item(at: i)
            item?.isEnabled = d.isAvailable(mode)
            item?.toolTip = d.isAvailable(mode) ? nil : (mode == .audioOnly ? "Bu videoda ses yok" : "Bu kaynakta uygun görüntü yok")
        }
        if let i = DownloadMode.allCases.firstIndex(of: d.mode), modePicker.indexOfSelectedItem != i { modePicker.selectItem(at: i) }
        modePicker.isEnabled = !busy
        modePicker.toolTip = d.mode == .audioOnly ? "Kaynağın ses biçimi korunur" : d.mode == .videoOnly ? "Sessiz video (ses izi alınmaz)" : nil
        let options = d.options(for: d.mode)
        if shownOptions != options { rebuildQuality(options) }
        if let i = shownOptions.firstIndex(where: { $0.tier == d.tier }) { quality.selectItem(at: i) }
        quality.isEnabled = !busy && d.mode.usesQuality && !shownOptions.isEmpty
        qualityBox.isHidden = !inspected || !d.mode.usesQuality
        folder.set(title: d.folder.lastPathComponent)
        folder.isEnabled = !busy
        folder.setAccessibilityLabel("Kaydetme konumu: " + d.folder.lastPathComponent)
        // Alt satır: İndir/İptal, ilerleme, sonuç eylemleri.
        let consent = d.phase == .needsEngine
        primary.isHidden = !inspected && !busy && !consent
        primary.set(title: consent ? "Motoru indir" : busy ? "İptal" : "İndir")
        primary.isEnabled = busy || consent || d.canDownload
        primary.setAccessibilityLabel(consent ? "YouTube motorunu indir" : busy ? (d.phase == .inspecting ? "İncelemeyi iptal et" : d.phase == .installingEngine ? "Motor indirmesini iptal et" : "İndirmeyi iptal et") : "İndir")
        let finished = d.phase == .finished && d.savedFile != nil
        reveal.isHidden = !finished
        shelve.isHidden = !finished
        decline.isHidden = !consent
        updateEngine.isHidden = !d.canUpdateEngine || busy
        let showsBar = d.phase == .downloading || d.phase == .finalizing || d.phase == .installingEngine
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
        case .finalizing: return "Hazırlanıyor (yeniden kodlama yok)…"
        case .inspecting: return ""
        case .needsEngine:
            return "Diskte ~" + ByteCountFormatter.string(fromByteCount: YouTubeEngine.installedBytes, countStyle: .file)
        case .installingEngine:
            return d.progress.map { String(format: "%%%d", Int(($0 * 100).rounded())) } ?? ""
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
        // 3. satır: tür (en geniş başlık "Yalnız video" + ok), kalite, klasör.
        let y3 = y2 + info.lineHeight + gap
        let modeW = Self.modeWidth
        modeBox.frame = CGRect(x: 0, y: y3, width: modeW, height: row)
        modePicker.frame = modeBox.bounds.insetBy(dx: 2, dy: 1)
        let x = modeW + gap
        let folderW = min(folder.preferredWidth, 100)
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
        for b in [decline, updateEngine] where !b.isHidden {
            b.frame = CGRect(x: sx, y: y4, width: b.preferredWidth, height: row); sx += b.preferredWidth + gap
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
