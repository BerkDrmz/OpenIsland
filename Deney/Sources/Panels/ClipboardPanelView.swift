import AppKit
import IslandCore

/// Pano geçmişi (sol) + "Bağlantıdan indir" girişi (sağ). İndirme formu aynı panel alanında açılır
/// (panel boyutu değişmez); kapatılınca geçmiş geri gelir.
/// Liste sanallaştırılmıştır: yalnız görünen satırlar kurulur ve kaydırınca yeniden kullanılır.
@MainActor
final class ClipboardPanelView: FlippedView, IslandPanel {
    /// SwiftUI `ClipboardPanel`: geçmiş sütunu önce (`PanelAXOrder.first`), indirme girişi sonra.
    func axNavigationRank(of view: NSView) -> Int? { view.isDescendant(of: downloadEntry) ? 0 : 3 }
    private let history: ClipboardHistory
    private let list: ClipListView
    private let hint = TextLabel("Tıkla: kopyala", font: Fonts.caption2, color: Palette.tertiary)
    private let clear: PlainButton
    private let clearLabel = TextLabel("Geçmişi temizle", font: Fonts.caption2)
    /// macOS 27.2+ pano izni "Sor": bekleyen kopyayı kullanıcı isteğiyle ekler / izin ayarını açar.
    private let addPending: PlainButton
    private let addPendingLabel = TextLabel("Yeni kopyayı ekle", font: Fonts.caption2, color: Palette.primary)
    private let pasteSettings = PlainButton { NSWorkspace.shared.open(PermissionsCenter.Pane.pasteboard.url) }
    private let pasteSettingsLabel = TextLabel("İzin ayarı", font: Fonts.caption2)
    private let placeholder = PlaceholderStack(symbol: "doc.on.clipboard", title: "", detail: "", spacing: 6)
    private let separator = SeparatorView()
    private let downloadEntry: DownloadEntryView
    private let downloadView: LinkDownloadView
    private var showsDownload = false
    private var isShown = false
    private lazy var observer = Observer(track: { [history, downloader] in
        _ = history.items; _ = history.isBlockedBySystem; _ = history.isRunning; _ = history.needsPasteAccess
        _ = downloader.phase; _ = downloader.progress
    }, apply: { [weak self] in self?.update() })
    private let downloader: LinkDownloader

    init(history: ClipboardHistory, downloader: LinkDownloader) {
        self.history = history
        self.downloader = downloader
        list = ClipListView(history: history)
        clear = PlainButton { history.clear() }
        addPending = PlainButton { history.addPendingCopy() }
        downloadEntry = DownloadEntryView(downloader: downloader)
        downloadView = LinkDownloadView(downloader: downloader)
        super.init(frame: .zero)
        clear.addSubview(clearLabel)
        clear.setAccessibilityLabel("Geçmişi temizle")
        clearLabel.setAccessibilityElement(false)
        addPending.addSubview(addPendingLabel)
        addPending.setAccessibilityLabel("Yeni kopyayı ekle")
        addPending.setAccessibilityHelp("macOS panodan okumak için izin isteyebilir")
        addPendingLabel.setAccessibilityElement(false)
        pasteSettings.addSubview(pasteSettingsLabel)
        pasteSettings.setAccessibilityLabel("Pano izin ayarını aç")
        pasteSettings.toolTip = "\"Her zaman izin ver\" seçilirse macOS bir daha sormaz"
        pasteSettings.setAccessibilityHelp("\"Her zaman izin ver\" seçilirse macOS bir daha sormaz")
        pasteSettingsLabel.setAccessibilityElement(false)
        downloadView.isHidden = true
        downloadEntry.onDownload = { [weak self] in self?.setShowsDownload(true) }
        downloadView.onClose = { [weak self] in self?.setShowsDownload(false) }
        [list, hint, clear, addPending, pasteSettings, placeholder, separator, downloadEntry, downloadView].forEach(addSubview)
    }

    /// Form ile geçmiş arasında geçiş (animasyonsuz, aynı alan). Sürmekte olan indirme etkilenmez.
    private func setShowsDownload(_ value: Bool) {
        guard showsDownload != value else { return }
        showsDownload = value
        if isShown { value ? downloadView.didShow() : downloadView.didHide() }
        update()
        if value { downloadView.focusField() } else { window?.makeFirstResponder(nil) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    /// Uyku hâlindeki ön kurulum: geçmiş satırları mevcut veriden kurulur (gözlem başlamaz).
    func prewarm() { update() }

    func didShow() {
        isShown = true
        observer.start()
        if showsDownload { downloadView.didShow() }
    }

    func didHide() {
        isShown = false
        observer.stop(); list.endHover()
        if showsDownload { downloadView.didHide() }
    }

    private func update() {
        downloadView.isHidden = !showsDownload
        downloadEntry.isHidden = showsDownload
        separator.isHidden = showsDownload
        let blocked = history.isBlockedBySystem
        let empty = history.items.isEmpty
        let pending = history.needsPasteAccess && !blocked
        placeholder.isHidden = !(blocked || empty) || showsDownload
        list.isHidden = blocked || empty || showsDownload
        [hint, clear].forEach { $0.isHidden = blocked || empty || pending || showsDownload }
        [addPending, pasteSettings].forEach { $0.isHidden = !pending || showsDownload }
        if blocked {
            placeholder.update(symbol: "hand.raised.fill", title: "Pano erişimi engellendi",
                               detail: "Sistem Ayarları › Gizlilik ve Güvenlik bölümünden OpenIsland'in panoya erişimine izin verin.")
        } else if empty && pending {
            placeholder.update(symbol: "doc.on.clipboard", title: "Yeni kopya izin bekliyor",
                               detail: "macOS okumadan önce izin ister.")
        } else if empty {
            placeholder.update(symbol: "doc.on.clipboard", title: "Pano geçmişi boş",
                               detail: history.isRunning ? "Kopyaladığınız metin, görsel ve dosyalar burada görünür." : "Pano geçmişi Ayarlar'dan kapatılmış.")
        } else {
            list.set(items: history.items)
        }
        downloadEntry.update()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let colorWidth = IslandLayoutEngine.Clipboard.colorColumnWidth
        let gap = IslandLayoutEngine.columnGap
        let historyWidth = bounds.width - colorWidth - 0.5 - 2 * gap
        let footer = hint.lineHeight // HStack: caption2 metin + caption2 düz düğme (13 pt)
        placeholder.frame = CGRect(x: 0, y: 0, width: historyWidth, height: bounds.height - (addPending.isHidden ? 0 : footer + 6))
        list.frame = CGRect(x: 0, y: 0, width: historyWidth, height: bounds.height - footer - 6)
        let fy = bounds.height - footer
        hint.frame = CGRect(x: 0, y: fy + (footer - hint.lineHeight) / 2, width: pixelCeil(hint.exactWidth), height: hint.lineHeight)
        let cw = pixelCeil(clearLabel.exactWidth)
        clear.frame = CGRect(x: historyWidth - cw, y: fy + (footer - clearLabel.lineHeight) / 2, width: cw, height: clearLabel.lineHeight)
        clearLabel.frame = clear.bounds
        let aw = pixelCeil(addPendingLabel.exactWidth)
        addPending.frame = CGRect(x: 0, y: fy + (footer - addPendingLabel.lineHeight) / 2, width: aw, height: addPendingLabel.lineHeight)
        addPendingLabel.frame = addPending.bounds
        let sw = pixelCeil(pasteSettingsLabel.exactWidth)
        pasteSettings.frame = CGRect(x: historyWidth - sw, y: fy + (footer - pasteSettingsLabel.lineHeight) / 2, width: sw, height: pasteSettingsLabel.lineHeight)
        pasteSettingsLabel.frame = pasteSettings.bounds
        separator.frame = pixelRect(CGRect(x: historyWidth + gap, y: 0, width: 0.5, height: bounds.height))
        downloadEntry.frame = CGRect(x: bounds.width - colorWidth, y: 0, width: colorWidth, height: bounds.height)
        downloadView.frame = bounds
    }
}

/// Sanallaştırılmış dikey liste (gösterge çubuğu yok). Satır yüksekliği 25 pt, aralık 4 pt.
@MainActor
private final class ClipListView: NSScrollView {
    private let history: ClipboardHistory
    private let document = LazyStackView()
    private var items: [ClipItem] = []
    private var rows: [UUID: ClipRowView] = [:]
    private var pool: [ClipRowView] = []
    private static let rowHeight = IslandLayoutEngine.Clipboard.rowHeight
    private static let spacing = IslandLayoutEngine.Clipboard.rowSpacing

    init(history: ClipboardHistory) {
        self.history = history
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        verticalScrollElasticity = .allowed
        documentView = document
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func set(items newItems: [ClipItem]) {
        guard newItems != items else { return } // panel her gösterildiğinde aynı liste gelir
        items = newItems
        let ids = Set(items.map(\.id))
        for (id, row) in rows where !ids.contains(id) { row.removeFromSuperview(); rows[id] = nil; pool.append(row) }
        // Yeni içerik: görünen satırlar mevcut nesnelerini korur, verisi güncellenir.
        for (id, row) in rows { if let item = items.first(where: { $0.id == id }) { row.configure(item) } }
        layoutRows()
    }

    func endHover() { rows.values.forEach { $0.endHover() } }

    @objc private func scrolled() { layoutRows() }

    override func layout() {
        super.layout()
        layoutRows()
    }

    private func layoutRows() {
        let width = contentView.bounds.width
        let total = CGFloat(items.count) * (Self.rowHeight + Self.spacing) - (items.isEmpty ? 0 : Self.spacing)
        let size = CGSize(width: width, height: max(total, contentView.bounds.height))
        if document.frame.size != size { document.frame.size = size }
        // LazyVStack gibi: görünen alan + aşağıda bir görünür yükseklik kadar önceden kurulur.
        var visible = contentView.bounds
        visible.size.height *= 2
        var keep = Set<UUID>()
        for (index, item) in items.enumerated() {
            let y = CGFloat(index) * (Self.rowHeight + Self.spacing)
            let frame = CGRect(x: 0, y: y, width: width, height: Self.rowHeight)
            guard frame.intersects(visible) else { continue }
            keep.insert(item.id)
            let row = rows[item.id] ?? dequeue(item)
            if row.frame != frame { row.frame = frame }
        }
        for (id, row) in rows where !keep.contains(id) { row.removeFromSuperview(); rows[id] = nil; pool.append(row) }
    }

    private func dequeue(_ item: ClipItem) -> ClipRowView {
        let row = pool.popLast() ?? ClipRowView(history: history)
        row.configure(item)
        document.addSubview(row)
        rows[item.id] = row
        return row
    }
}

/// Pano satırı (SwiftUI `ClipRow`): önizleme, hover'da sil düğmesi, kopyala simgesi (kopyalanınca onay işareti 1,2 sn).
@MainActor
private final class ClipRowView: RoundedView, TransientStateResettable {
    func resetTransientState() {
        resetWork?.cancel()
        guard isHovering || didCopy else { return }
        didCopy = false
        isHovering = false
        updateState(animated: false)
    }

    private let history: ClipboardHistory
    private var item: ClipItem?
    private let text = TextLabel("", font: Fonts.body)
    private let thumbnail = DecorativeImageView()
    private let fileIcon = SymbolView("doc", size: 12, color: Palette.primary)
    private let trash: PlainButton
    private let copyIcon = SymbolView("doc.on.doc", size: 10, weight: .semibold, color: Palette.tertiary)
    private var hoverArea: NSTrackingArea?
    private var isHovering = false { didSet { if isHovering != oldValue { updateState(animated: true) } } }
    private var didCopy = false { didSet { if didCopy != oldValue { updateState(animated: true) } } }
    private var resetWork: DispatchWorkItem?
    private var didResolveCleanLink = false
    private var cleanLink: String?

    init(history: ClipboardHistory) {
        self.history = history
        let trashIcon = SymbolView("trash", size: 10, color: Palette.secondary)
        trash = PlainButton()
        super.init(radius: Spacing.cardRadius - 4, fill: Palette.fill)
        trash.addSubview(trashIcon)
        trash.setAccessibilityLabel("Geçmişten sil")
        trash.isHidden = true
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 4
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.contentsGravity = .resizeAspectFill
        thumbnail.setAccessibilityElement(false)
        [text, thumbnail, fileIcon, trash, copyIcon].forEach(addSubview)
        trash.action = { [weak self] in self?.delete() }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Panoya kopyalar")
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Geçmişten sil") { [weak self] in self?.delete(); return true }])
        text.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func configure(_ item: ClipItem) {
        guard item != self.item else { return }
        let changed = self.item?.id != item.id
        self.item = item
        didResolveCleanLink = false
        cleanLink = nil
        if changed { resetWork?.cancel(); didCopy = false; isHovering = false }
        switch item.content {
        case .text(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            text.set(Self.visiblePrefix(trimmed))
            setAccessibilityLabel(trimmed)
            thumbnail.isHidden = true
            fileIcon.isHidden = true
        case .image(let data):
            text.set("Görsel")
            thumbnail.image = ClipThumbnails.image(for: item, data: data)
            thumbnail.isHidden = thumbnail.image == nil
            fileIcon.isHidden = true
            setAccessibilityLabel("Görsel")
        case .files(let urls):
            let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) dosya"
            text.set(name)
            thumbnail.isHidden = true
            fileIcon.isHidden = false
            setAccessibilityLabel(name)
        }
        needsLayout = true
    }

    /// Satır tek satırdır; CoreText'in bütün dizgiyi şekillendirmemesi için yalnız görünen kısım verilir: ilk 512 görünür
    /// karakter (satır genişliğinin birkaç katı) ve devamı varsa ilk satır sonu, böylece kesme ve "…" aynı kalır.
    static func visiblePrefix(_ text: String) -> String {
        var visible = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if !character.isWhitespace { visible += 1 }
            if visible >= 512 { break }
        }
        return index < text.endIndex ? String(text[..<index]) + "\n…" : text
    }

    private func updateState(animated: Bool) {
        fill = isHovering ? Palette.fillHover : Palette.fill
        trash.isHidden = !isHovering
        copyIcon.set(didCopy ? "checkmark" : "doc.on.doc", animated: animated)
        copyIcon.contentTintColor = isHovering || didCopy ? Palette.primary : Palette.tertiary
        needsLayout = true
    }

    func endHover() { isHovering = false }

    private func copyItem() {
        guard let item else { return }
        history.copy(item)
        confirmCopy()
    }

    // Resolve only when the user opens the menu or queries this row's AX actions,
    // not on hover, panel animation frames, or in a clipboard/background monitor.
    private func resolvedCleanLink() -> String? {
        if !didResolveCleanLink {
            didResolveCleanLink = true
            if let item, case .text(let value) = item.content { cleanLink = TrackingURLCleaner.clean(value) }
        }
        return cleanLink
    }

    @discardableResult
    private func copyCleanLink() -> Bool {
        guard let item, let value = resolvedCleanLink() else { return false }
        history.copy(ClipItem(content: .text(value), date: Date(), sourceApp: item.sourceApp))
        confirmCopy()
        return true
    }

    private func confirmCopy() {
        didCopy = true
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.didCopy = false }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func delete() {
        guard let item else { return }
        history.remove(item)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var right = bounds.width - 10
        let cs = copyIcon.layoutSize
        right -= cs.width
        copyIcon.frame = copyIcon.drawingFrame(layoutOrigin: CGPoint(x: right, y: (h - cs.height) / 2))
        if !trash.isHidden, let icon = trash.subviews.first as? SymbolView {
            let ts = icon.layoutSize
            right -= 10 + ts.width
            icon.place(asLabelOf: trash, layoutOrigin: CGPoint(x: right, y: (h - ts.height) / 2))
        }
        var x: CGFloat = 10
        if !thumbnail.isHidden {
            thumbnail.frame = CGRect(x: x, y: (h - 20) / 2, width: 30, height: 20)
            x += 30 + 8
        } else if !fileIcon.isHidden {
            let s = fileIcon.layoutSize
            fileIcon.frame = fileIcon.drawingFrame(layoutOrigin: CGPoint(x: x, y: (h - s.height) / 2))
            x += s.width + 5
        }
        // HStack(spacing: 10) { metin, Spacer(minLength: 8), [çöp], simge }: metin ile simge arasında 10 + 8 + 10.
        let maxText = right - 10 - 8 - 10 - x
        text.frame = CGRect(x: x, y: (h - text.lineHeight) / 2, width: min(text.naturalWidth, max(maxText, 0)), height: text.lineHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        if !trash.isHidden, let hit = trash.hitTest(convert(point, from: superview)) { return hit }
        return self
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { copyItem() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { copyItem(); return true }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions = super.accessibilityCustomActions() ?? []
        if resolvedCleanLink() != nil {
            actions.append(NSAccessibilityCustomAction(name: "Takipsiz bağlantıyı kopyala") { [weak self] in
                self?.copyCleanLink() ?? false
            })
        }
        return actions
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(StatusMenuItem(title: "Kopyala", keyEquivalent: "") { [weak self] in self?.copyItem() })
        if resolvedCleanLink() != nil {
            menu.addItem(StatusMenuItem(title: "Takipsiz bağlantıyı kopyala", keyEquivalent: "") { [weak self] in self?.copyCleanLink() })
        }
        menu.addItem(StatusMenuItem(title: "Geçmişten sil", keyEquivalent: "") { [weak self] in self?.delete() })
        return menu
    }
}

@MainActor
private enum ClipThumbnails {
    private static let cache = NSCache<NSUUID, NSImage>()

    static func image(for item: ClipItem, data: Data) -> NSImage? {
        let key = item.id as NSUUID
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// "Bağlantıdan indir" girişi (eski damlalık düğmesinin ölçüsü), sütunda dikey ortalı. İndirme sürerken düğme
/// ilerlemeyi gösterir.
@MainActor
private final class DownloadEntryView: FlippedView {
    var onDownload: (() -> Void)?
    private let downloader: LinkDownloader
    private let picker: PlainButton
    private let pickerBackground = RoundedView(radius: Spacing.cardRadius - 4, fill: Palette.fill)
    private let pickerIcon = SymbolView("arrow.down.circle", size: 12, weight: .medium, color: Palette.primary)
    private let pickerTitle = TextLabel("İndir", font: Fonts.bodyEmphasized)

    init(downloader: LinkDownloader) {
        self.downloader = downloader
        picker = PlainButton()
        super.init(frame: .zero)
        picker.action = { [weak self] in self?.onDownload?() }
        picker.addSubview(pickerBackground)
        pickerBackground.addSubview(pickerIcon)
        pickerBackground.addSubview(pickerTitle)
        picker.toolTip = "Bağlantıdan video veya ses indir"
        picker.setAccessibilityLabel("Bağlantıdan indir")
        picker.setAccessibilityHelp("Bağlantıdan video veya ses indir")
        pickerTitle.setAccessibilityElement(false)
        addSubview(picker)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func update() {
        let title: String
        switch downloader.phase {
        case .inspecting: title = "İnceleniyor…"
        case .downloading: title = downloader.progress.map { String(format: "%%%d", Int(($0 * 100).rounded())) } ?? "İndiriliyor"
        case .finalizing: title = "Hazırlanıyor"
        case .installingEngine: title = downloader.progress.map { "Motor " + String(format: "%%%d", Int(($0 * 100).rounded())) } ?? "Motor"
        default: title = "İndir"
        }
        if pickerTitle.stringValue != title { pickerTitle.set(title); needsLayout = true }
        picker.setAccessibilityValue(downloader.phase.isBusy ? title : nil)
    }

    override func layout() {
        super.layout()
        let titleH = pickerTitle.lineHeight
        let height = titleH + 12
        picker.frame = pixelRect(CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height))
        pickerBackground.frame = picker.bounds
        let s = pickerIcon.intrinsicContentSize
        let tw = pickerTitle.naturalWidth
        let labelWidth = s.width + 6 + tw
        let x0 = (bounds.width - labelWidth) / 2
        pickerIcon.frame = pixelRect(CGRect(x: x0, y: (height - s.height) / 2, width: s.width, height: s.height))
        pickerTitle.frame = CGRect(x: x0 + s.width + 6, y: (height - titleH) / 2, width: tw, height: titleH)
    }
}
