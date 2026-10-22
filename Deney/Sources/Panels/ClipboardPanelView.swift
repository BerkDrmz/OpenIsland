import AppKit
import IslandCore

/// Pano geçmişi (sol) + renk damlalığı ve son renkler (sağ) (SwiftUI `ClipboardPanel`).
/// Liste sanallaştırılmıştır: yalnız görünen satırlar kurulur ve kaydırınca yeniden kullanılır.
@MainActor
final class ClipboardPanelView: FlippedView, IslandPanel {
    private let history: ClipboardHistory
    private let colors: ColorPickerService
    private let list: ClipListView
    private let hint = TextLabel("Tıkla: kopyala", font: Fonts.caption2, color: Palette.tertiary)
    private let clear: PlainButton
    private let clearLabel = TextLabel("Geçmişi temizle", font: Fonts.caption2)
    private let placeholder = PlaceholderStack(symbol: "doc.on.clipboard", title: "", detail: "", spacing: 6)
    private let separator = SeparatorView()
    private let colorColumn: ColorColumnView
    private lazy var observer = Observer(track: { [history, colors] in
        _ = history.items; _ = history.isBlockedBySystem; _ = history.isRunning; _ = colors.recentColors
    }, apply: { [weak self] in self?.update() })

    init(history: ClipboardHistory, colors: ColorPickerService) {
        self.history = history
        self.colors = colors
        list = ClipListView(history: history)
        clear = PlainButton { history.clear() }
        colorColumn = ColorColumnView(colors: colors)
        super.init(frame: .zero)
        clear.addSubview(clearLabel)
        clear.setAccessibilityLabel("Geçmişi temizle")
        clearLabel.setAccessibilityElement(false)
        [list, hint, clear, placeholder, separator, colorColumn].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() { observer.start() }
    func didHide() { observer.stop(); list.endHover() }

    private func update() {
        let blocked = history.isBlockedBySystem
        let empty = history.items.isEmpty
        placeholder.isHidden = !(blocked || empty)
        [list, hint, clear].forEach { $0.isHidden = blocked || empty }
        if blocked {
            placeholder.update(symbol: "hand.raised.fill", title: "Pano erişimi engellendi",
                               detail: "Sistem Ayarları › Gizlilik ve Güvenlik bölümünden OpenIsland'in panoya erişimine izin verin.")
        } else if empty {
            placeholder.update(symbol: "doc.on.clipboard", title: "Pano geçmişi boş",
                               detail: history.isRunning ? "Kopyaladığınız metin, görsel ve dosyalar burada görünür." : "Pano geçmişi Ayarlar'dan kapatılmış.")
        } else {
            list.set(items: history.items)
        }
        colorColumn.update()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let colorWidth = IslandLayoutEngine.Clipboard.colorColumnWidth
        let gap = IslandLayoutEngine.columnGap
        let historyWidth = bounds.width - colorWidth - 0.5 - 2 * gap
        placeholder.frame = CGRect(x: 0, y: 0, width: historyWidth, height: bounds.height)
        let footer = hint.lineHeight // HStack: caption2 metin + caption2 düz düğme (13 pt)
        list.frame = CGRect(x: 0, y: 0, width: historyWidth, height: bounds.height - footer - 6)
        let fy = bounds.height - footer
        hint.frame = CGRect(x: 0, y: fy + (footer - hint.lineHeight) / 2, width: pixelCeil(hint.exactWidth), height: hint.lineHeight)
        let cw = pixelCeil(clearLabel.exactWidth)
        clear.frame = CGRect(x: historyWidth - cw, y: fy + (footer - clearLabel.lineHeight) / 2, width: cw, height: clearLabel.lineHeight)
        clearLabel.frame = clear.bounds
        separator.frame = pixelRect(CGRect(x: historyWidth + gap, y: 0, width: 0.5, height: bounds.height))
        colorColumn.frame = CGRect(x: bounds.width - colorWidth, y: 0, width: colorWidth, height: bounds.height)
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
        let changed = self.item?.id != item.id
        self.item = item
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(StatusMenuItem(title: "Kopyala", keyEquivalent: "") { [weak self] in self?.copyItem() })
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

/// Ekrandan renk damlalığı ve son seçilen renkler (tıklayınca HEX kopyalanır).
@MainActor
private final class ColorColumnView: FlippedView {
    private let colors: ColorPickerService
    private let picker: PlainButton
    private let pickerBackground = RoundedView(radius: Spacing.cardRadius - 4, fill: Palette.fill)
    private let pickerIcon = SymbolView("eyedropper.halffull", size: 12, weight: .medium, color: Palette.primary)
    private let pickerTitle = TextLabel("Damlalık", font: Fonts.bodyEmphasized)
    private let emptyText = TextLabel("Seçilen renkler burada", font: Fonts.caption2, color: Palette.tertiary)
    private let swatches = NSScrollView()
    private let swatchDocument = FlippedView()
    private var shown: [String] = []

    init(colors: ColorPickerService) {
        self.colors = colors
        picker = PlainButton { colors.pick() }
        super.init(frame: .zero)
        picker.addSubview(pickerBackground)
        pickerBackground.addSubview(pickerIcon)
        pickerBackground.addSubview(pickerTitle)
        picker.toolTip = "Ekrandan renk seç, HEX kodunu kopyala"
        picker.setAccessibilityLabel("Damlalık")
        picker.setAccessibilityHelp("Ekrandan renk seç, HEX kodunu kopyala")
        pickerTitle.setAccessibilityElement(false)
        emptyText.minimumScaleFactor = 0.8
        swatches.drawsBackground = false
        swatches.hasHorizontalScroller = false
        swatches.hasVerticalScroller = false
        swatches.documentView = swatchDocument
        [picker, emptyText, swatches].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func update() {
        let recent = colors.recentColors
        emptyText.isHidden = !recent.isEmpty
        swatches.isHidden = recent.isEmpty
        guard recent != shown else { return }
        shown = recent
        swatchDocument.subviews.forEach { $0.removeFromSuperview() }
        for hex in recent {
            let button = PlainButton { [colors] in colors.copy(hex) }
            let circle = RoundedView(radius: 10, fill: NSColor(hexString: hex) ?? .clear)
            circle.stroke = (NSColor.white.withAlphaComponent(0.2), 0.5)
            button.addSubview(circle)
            button.toolTip = hex
            button.setAccessibilityLabel("Renk \(hex), kopyala")
            button.setAccessibilityHelp(hex)
            swatchDocument.addSubview(button)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let titleH = pickerTitle.lineHeight
        let height = titleH + 12
        picker.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        pickerBackground.frame = picker.bounds
        let s = pickerIcon.intrinsicContentSize
        let tw = pickerTitle.naturalWidth
        let labelWidth = s.width + 6 + tw
        let x0 = (bounds.width - labelWidth) / 2
        pickerIcon.frame = pixelRect(CGRect(x: x0, y: (height - s.height) / 2, width: s.width, height: s.height))
        pickerTitle.frame = CGRect(x: x0 + s.width + 6, y: (height - titleH) / 2, width: tw, height: titleH)
        let y = height + Spacing.s
        emptyText.frame = CGRect(x: 0, y: y, width: bounds.width, height: emptyText.lineHeight)
        swatches.frame = CGRect(x: 0, y: y, width: bounds.width, height: 20)
        var x: CGFloat = 0
        for button in swatchDocument.subviews {
            button.frame = CGRect(x: x, y: 0, width: 20, height: 20)
            button.subviews.first?.frame = button.bounds
            x += 20 + 6
        }
        swatchDocument.frame = CGRect(x: 0, y: 0, width: max(x - 6, bounds.width), height: 20)
    }
}
