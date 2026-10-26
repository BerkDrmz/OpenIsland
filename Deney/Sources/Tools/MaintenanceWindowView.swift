import AppKit
import IslandCore

/// Araçlar penceresi (SwiftUI `MaintenanceView` karşılığı): solda 220 pt kenar çubuğu, ince ayırıcı, sağda bölüm.
/// Pencere sistem görünüşünü izler. Denetleyici gözlenir; yalnız okunan değerler değişince yeniden uygulanır.
@MainActor
final class MaintenanceWindowView: FlippedView {
    private let controller: MaintenanceController
    private let sidebar = MaintenanceSidebarView()
    private let divider = MaintenanceDividerView()
    private let main = FlippedView()
    private let title = TextLabel("", font: .systemFont(ofSize: 17, weight: .bold), color: .labelColor)
    private let refresh = MaintenanceButton(title: "", symbol: "arrow.clockwise")
    private let summary = TextLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let content = FlippedView()
    private let bottomDivider = MaintenanceDividerView()
    private let statusRow = MaintenanceStatusView()
    private var sectionView: MaintenanceSectionView?
    private var shownSection: MaintenanceController.Section?
    /// Kurulan bölümler saklanır: geçişte yalnız gizlenir/gösterilir (her geçişte yeniden kurmak SwiftUI'den pahalıydı).
    private var sectionViews: [MaintenanceController.Section: MaintenanceSectionView] = [:]
    private var generation = 0

    init(controller: MaintenanceController) {
        self.controller = controller
        super.init(frame: CGRect(x: 0, y: 0, width: 880, height: 590))
        // SwiftUI kökü (barındırma görünümü) bir AX grubudur.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        summary.maximumLines = 0
        title.lineHeightOverride = 20.5 // SwiftUI `.title2.bold()` (ölçüldü)
        refresh.target = self
        refresh.action = #selector(reload)
        sidebar.onSelect = { [weak controller] section in controller?.select(section) }
        statusRow.onCancel = { [weak controller] in controller?.cancel() }
        [title, refresh, summary, content, bottomDivider, statusRow].forEach(main.addSubview)
        [sidebar, divider, main].forEach(addSubview)
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    private func observe() {
        generation += 1
        let token = generation
        withObservationTracking { update() } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    self.observe()
                }
            }
        }
    }

    private func update() {
        let section = controller.section
        sidebar.update(selected: section, enabled: !controller.busy)
        title.set(section.rawValue)
        refresh.isHidden = section == .cleaner
        refresh.setTitle("Listeyi yenile")
        refresh.isEnabled = !controller.busy
        summary.set(Self.description(section))
        if shownSection != section {
            shownSection = section
            sectionView?.isHidden = true
            let view = sectionViews[section] ?? {
                let view: MaintenanceSectionView = switch section {
                case .uninstaller: MaintenanceUninstallView(controller: controller)
                case .cleaner: MaintenanceCleanerView(controller: controller)
                }
                sectionViews[section] = view
                content.addSubview(view)
                return view
            }()
            view.isHidden = false
            sectionView = view
        }
        sectionView?.update()
        statusRow.update(busy: controller.busy, status: controller.status.isEmpty ? "Hazır." : controller.status)
        needsLayout = true
    }

    @objc private func reload() { controller.loadApplications() }

    /// Açıklama yüksekliği bölüm ve genişlik başına bir kez ölçülür (bölüm geçişinde metin değişir).
    private var summaryHeights: [String: CGFloat] = [:]
    private func summaryHeight(forWidth width: CGFloat) -> CGFloat {
        let key = "\(summary.stringValue.hashValue)|\(width)"
        if let height = summaryHeights[key] { return height }
        let height = summary.height(forWidth: width)
        summaryHeights[key] = height
        return height
    }

    private static func description(_ section: MaintenanceController.Section) -> String {
        switch section {
        case .uninstaller:
            "Uygulamayı seç, kalıntılarını tara ve kaldırılacak öğeleri denetle. Kişisel veriler ve ada göre eşleşen klasörler ayrıca seçilir. Paylaşılan grup klasörlerine ve sistem yardımcılarına dokunulmaz."
        case .cleaner:
            "Kullanıcı önbelleklerini isteğe bağlı tara. Açık uygulamalara ait bilinen önbellekler korunur. Önce ilgili uygulamaları kapat; önbellekler daha sonra yeniden oluşabilir."
        }
    }

    override func layout() {
        super.layout()
        sidebar.frame = CGRect(x: 0, y: 0, width: 220, height: bounds.height)
        divider.frame = CGRect(x: 220, y: 0, width: 1, height: bounds.height)
        main.frame = CGRect(x: 221, y: 0, width: bounds.width - 221, height: bounds.height)
        // VStack(spacing: 14).padding(20): başlık, açıklama, bölüm, ayırıcı, durum (54 pt).
        let pad: CGFloat = 20
        let width = main.bounds.width - 2 * pad
        let titleHeight = title.lineHeight
        let summaryHeight = summaryHeight(forWidth: width)
        let statusHeight: CGFloat = 54
        // Bölüm sıkıştırılamazsa SwiftUI VStack'i taşar ve pencerede ortalanır: tüm sütun yarı taşma kadar yukarı kayar.
        let fixed = titleHeight + 14 + summaryHeight + 14 + 14 + 1 + 14 + statusHeight
        let available = main.bounds.height - 2 * pad
        let minimum = sectionView?.minimumHeight ?? 0
        let contentHeight = max(available - fixed, minimum)
        let top = pad + min(0, (available - fixed - minimum) / 2)
        title.frame = CGRect(x: pad, y: top, width: pixelCeil(title.exactWidth), height: titleHeight)
        if !refresh.isHidden {
            let s = refresh.alignmentSize
            refresh.setAlignmentFrame(pixelRect(CGRect(x: pad + width - s.width, y: top + (titleHeight - s.height) / 2, width: s.width, height: s.height)))
        }
        var y = top + titleHeight + 14
        summary.frame = CGRect(x: pad, y: y, width: width, height: summaryHeight)
        y += summaryHeight + 14
        content.frame = pixelRect(CGRect(x: pad, y: y, width: width, height: contentHeight))
        y += contentHeight + 14
        bottomDivider.frame = pixelRect(CGRect(x: pad, y: y, width: width, height: 1))
        y += 1 + 14
        statusRow.frame = pixelRect(CGRect(x: pad, y: y, width: width, height: statusHeight))
        sectionView?.frame = content.bounds
    }
}

// MARK: - Kenar çubuğu

/// Kenar çubuğu: "Araçlar" başlığı (headline), bölüm düğmeleri (seçili: vurgu rengi %15, 8 pt köşe), altta not.
@MainActor
private final class MaintenanceSidebarView: FlippedView {
    var onSelect: ((MaintenanceController.Section) -> Void)?
    private let header = IconLabelView("Araçlar", symbol: "wrench.and.screwdriver", font: .systemFont(ofSize: 13, weight: .bold),
                                       color: .labelColor)
    private var buttons: [MaintenanceController.Section: MaintenanceSectionButton] = [:]
    private let note = TextLabel("Yalnızca ihtiyaç olduğunda çalışır.", font: .systemFont(ofSize: 10), color: .secondaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        header.text.lineHeightOverride = 16.4 // SwiftUI `.headline` (ölçüldü)
        header.icon.setConfiguration(size: 13, weight: .bold) // Label simgesi yazının kalınlığını alır
        header.textNudge = -0.5 // SwiftUI kalın simgeyi metne göre 0,5 pt aşağıda çizer (ölçüldü)
        addSubview(header)
        for section in MaintenanceController.Section.allCases {
            let button = MaintenanceSectionButton(section: section) { [weak self] in self?.onSelect?(section) }
            buttons[section] = button
            addSubview(button)
        }
        addSubview(note)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    nonisolated override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor }
    }

    func update(selected: MaintenanceController.Section, enabled: Bool) {
        for (section, button) in buttons { button.setSelected(section == selected); button.isEnabled = enabled }
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 16
        let width = bounds.width - 2 * pad
        let headerSize = header.fittingSize
        header.frame = CGRect(x: pad, y: pad + 0.5, width: headerSize.width, height: headerSize.height)
        // VStack(spacing: 8): başlık + 12 pt alt boşluk, düğmeler (Label + 10 pt dolgu).
        var y = pad + 0.5 + headerSize.height + 12 + 8
        for section in MaintenanceController.Section.allCases {
            guard let button = buttons[section] else { continue }
            let h = button.preferredHeight
            button.frame = pixelRect(CGRect(x: pad, y: y, width: width, height: h))
            y += h + 8
        }
        note.frame = CGRect(x: pad, y: bounds.height - pad - note.lineHeight, width: pixelCeil(note.exactWidth), height: note.lineHeight)
    }
}

/// Bölüm düğmesi: Label (body) 10 pt dolgulu, tam genişlik; seçiliyse vurgu rengi %15 zemin.
@MainActor
private final class MaintenanceSectionButton: PlainButton {
    private let label: IconLabelView
    private let background = MaintenanceFillView(radius: 8)
    private var selected = false

    init(section: MaintenanceController.Section, action: @escaping () -> Void) {
        label = IconLabelView(section.rawValue, symbol: section.symbol, font: .systemFont(ofSize: 13), color: .labelColor)
        super.init(action: action)
        addSubview(background)
        addSubview(label)
        setAccessibilityLabel(section.rawValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    /// Label yüksekliği piksele aşağı yuvarlanır (SwiftUI; simgeye göre 16,5 ya da 16 pt, ölçüldü) + 2 × 10 pt dolgu.
    private var labelHeight: CGFloat { (label.fittingSize.height * 2).rounded(.down) / 2 }
    var preferredHeight: CGFloat { labelHeight + 20 }

    func setSelected(_ value: Bool) {
        guard value != selected else { return }
        selected = value
        background.isHidden = !value
        setAccessibilitySelected(value)
    }

    /// SwiftUI: etiket düğmenin içindedir (ayrı AX öğesi yok); zeminsiz düğmenin AX çerçevesi etiketinkidir.
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityFrame() -> NSRect { selected ? super.accessibilityFrame() : label.accessibilityFrame() }

    override var isEnabled: Bool { didSet { label.alphaValue = isEnabled ? 1 : 0.5 } }

    override func layout() {
        super.layout()
        background.frame = bounds
        let s = label.fittingSize
        // SwiftUI metni yuvarlanmış etiket yüksekliğinin dibine oturtur (ölçüldü).
        label.textNudge = label.text.lineHeight - labelHeight
        label.frame = CGRect(x: 10, y: 10, width: s.width, height: s.height)
    }
}

/// Yuvarlak köşeli vurgu zemini (`Color.accentColor.opacity(0.15)`).
final class MaintenanceFillView: NSView {
    private let radius: CGFloat
    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    nonisolated override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// SwiftUI `Divider`: 1 pt ayırıcı rengi.
private final class MaintenanceDividerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    nonisolated override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.separatorColor.cgColor }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Ortak denetimler

/// SwiftUI `Button(title, systemImage:)` (normal boy): simge + başlık; hizalama dikdörtgeniyle yerleşir, AX çerçevesi
/// hizalama dikdörtgenidir.
final class MaintenanceButton: NSButton, AlignedControl {
    private var symbolWidth: CGFloat = 0

    override class var cellClass: AnyClass? {
        get { MaintenanceButtonCell.self }
        set {}
    }

    convenience init(title: String, symbol: String?) {
        self.init(frame: .zero)
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        self.title = title
        setAccessibilityLabel(title)
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            self.image = image
            imagePosition = .imageLeading
            symbolWidth = image.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))?.alignmentRect.width ?? 0
        }
    }

    func setTitle(_ value: String) {
        guard title != value else { return }
        title = value
        setAccessibilityLabel(value)
    }

    /// SwiftUI düğmesinin hizalama genişliği (ölçüldü): metin + 16 pt; simgeliyse + simge + 8 pt; piksele yukarı.
    /// Başlık ve yazı tipi değişmedikçe önbellekten (`fittingSize` her yerleşimde yerleşim motorunu çalıştırıyordu).
    var alignmentSize: CGSize {
        if let cachedSize, cachedSize.title == title, cachedSize.font == font { return cachedSize.size }
        let i = alignmentRectInsets
        let size = CGSize(width: pixelCeil(contentWidth), height: fittingSize.height - i.top - i.bottom)
        cachedSize = (title, font, size)
        return size
    }

    private var cachedSize: (title: String, font: NSFont?, size: CGSize)?

    private var contentWidth: CGFloat {
        let text = (title as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 13)]).width
        return text + 16 + (symbolWidth > 0 ? symbolWidth + 8 : 0)
    }

    override func accessibilityFrame() -> NSRect { alignmentScreenFrame() ?? super.accessibilityFrame() }
}

/// SwiftUI düğme başlığı: kökeni piksele yukarı yuvarlanır; simgeliyse simge ile arası NSButton'dakinden 3 pt geniştir
/// (simge yerinde kalır, ölçüldü).
private final class MaintenanceButtonCell: NSButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        // SwiftUI başlığın kökenini piksele yukarı yuvarlar; NSButton ortaladığı kesirli konumda çizer (ölçüldü).
        let shifted = frame.offsetBy(dx: image == nil ? 0 : 3, dy: 0)
        let x = shifted.midX - title.size().width / 2
        return super.drawTitle(title, withFrame: shifted.offsetBy(dx: pixelCeil(x) - x, dy: 0), in: controlView)
    }
}

/// Durum satırı: meşgulken küçük dönen gösterge, kaydırılabilir seçilebilir durum metni (caption, ikincil), Durdur.
@MainActor
private final class MaintenanceStatusView: FlippedView {
    var onCancel: (() -> Void)?
    private let spinner = NSProgressIndicator()
    private let scroll = NSScrollView()
    private let text = MaintenanceStatusField(wrappingLabelWithString: "")
    private let stop = MaintenanceButton(title: "Durdur", symbol: nil)
    private var busy = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        text.font = .systemFont(ofSize: 10)
        text.textColor = .secondaryLabelColor
        text.isSelectable = true
        text.drawsBackground = false
        text.isBordered = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = FlippedView()
        document.addSubview(text)
        scroll.documentView = document
        stop.target = self
        stop.action = #selector(cancel)
        [spinner, scroll, stop].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    @objc private func cancel() { onCancel?() }

    func update(busy: Bool, status: String) {
        if busy != self.busy {
            self.busy = busy
            if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
        stop.isHidden = !busy
        if text.stringValue != status { text.stringValue = status }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // HStack(alignment: .top, spacing: 10): [gösterge] metin alanı [Durdur].
        var x: CGFloat = 0
        if busy {
            let s = spinner.fittingSize
            spinner.frame = CGRect(x: 0, y: 0, width: s.width, height: s.height)
            x = s.width + 10
        }
        var right = bounds.width
        if busy {
            let s = stop.alignmentSize
            stop.setAlignmentFrame(CGRect(x: right - s.width, y: 0, width: s.width, height: s.height))
            right -= s.width + 10
        }
        scroll.frame = CGRect(x: x, y: 0, width: right - x, height: bounds.height)
        let width = scroll.contentSize.width
        // NSTextField metni 2 pt içeriden çizer; SwiftUI `Text` kenardan başlar ve tam genişlikte sarar.
        let size = text.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width + 4, height: .greatestFiniteMagnitude)) ?? .zero
        text.frame = CGRect(x: -2, y: 0, width: width + 4, height: ceil(size.height))
        scroll.documentView?.frame = CGRect(x: 0, y: 0, width: width, height: max(ceil(size.height), scroll.contentSize.height))
    }
}

/// Seçilebilir durum metni: AX çerçevesi metnin kullandığı alan (SwiftUI `Text`), alanın tamamı değil.
final class MaintenanceStatusField: NSTextField {
    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 10)]
        let used = (stringValue as NSString).boundingRect(with: CGSize(width: bounds.width - 4, height: .greatestFiniteMagnitude),
                                                         options: [.usesLineFragmentOrigin], attributes: attributes)
        let lines = max(1, (used.height / TextMetrics.lineHeight(for: font ?? .systemFont(ofSize: 10))).rounded())
        let rect = CGRect(x: 2, y: 0, width: pixelCeil(used.width), height: lines * TextMetrics.lineHeight(for: font ?? .systemFont(ofSize: 10)))
        return window.convertToScreen(convert(rect, to: nil))
    }
}

// MARK: - Bölümler

@MainActor
class MaintenanceSectionView: FlippedView {
    let controller: MaintenanceController
    init(controller: MaintenanceController) {
        self.controller = controller
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func update() {}

    /// SwiftUI'de sıkıştırılamayan içerik yüksekliği; ana sütun bundan kısaysa içerik taşar (0: tamamen esnek).
    var minimumHeight: CGFloat { 0 }
}

/// Dosya listesi alanı (metin arka plan rengi, 8 pt köşe): boşken bölüm simgesi + yönerge ortada; dosya varsa SwiftUI
/// `List` gibi iç içe stilli anahat görünümü (AX: kaydırma alanı → anahat → satır → hücre).
@MainActor
final class MaintenanceFileListView: FlippedView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let controller: MaintenanceController
    private let symbol: SymbolView
    private let hint = TextLabel("Dosyaları görmek için taramayı başlat.", font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
    private let scroll = NSScrollView()
    private let outline = MaintenanceOutlineView()
    private var files: [MaintenanceFile] = []
    private var ids: [NSString] = []

    init(controller: MaintenanceController, symbol name: String) {
        self.controller = controller
        symbol = SymbolView(name, size: 30, color: .secondaryLabelColor)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        symbol.exposeAsImage()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .inset
        outline.selectionHighlightStyle = .none
        outline.backgroundColor = .controlBackgroundColor // SwiftUI `List` (ListCoreScrollView) ile aynı ayarlar (ölçüldü)
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 0
        outline.dataSource = self
        outline.delegate = self
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .controlBackgroundColor
        [symbol, hint, scroll].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    nonisolated override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        // Liste varken SwiftUI `List` kendi (yarı saydam) zeminini pencere zemini üstüne çizer; metin zemini yalnız
        // boş durumda görünür (ölçüldü).
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = files.isEmpty ? NSColor.textBackgroundColor.cgColor : NSColor.clear.cgColor
        }
    }

    func update() {
        let wasEmpty = files.isEmpty
        defer { if wasEmpty != files.isEmpty { needsDisplay = true } }
        let newFiles = controller.files
        let newIDs = newFiles.map { $0.id as NSString }
        if newIDs != ids {
            files = newFiles
            ids = newIDs
            outline.reloadData()
        } else {
            files = newFiles
            for row in 0..<outline.numberOfRows {
                (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? MaintenanceFileCell)?.update()
            }
        }
        let empty = files.isEmpty
        symbol.isHidden = !empty
        hint.isHidden = !empty
        scroll.isHidden = empty
        needsLayout = true
    }

    // MARK: Veri kaynağı

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? ids.count : 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ids[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let file = file(for: item) else { return 48 }
        return 8 + 8 + MaintenanceFileCell.contentHeight(lines: hasThirdLine(file) ? 3 : 2)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let file = file(for: item) else { return nil }
        let cell = (outlineView.makeView(withIdentifier: MaintenanceFileCell.identifier, owner: nil) as? MaintenanceFileCell)
            ?? MaintenanceFileCell(controller: controller)
        cell.configure(file)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { MaintenanceFileRowView() }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }

    private func file(for item: Any) -> MaintenanceFile? {
        guard let id = item as? NSString else { return nil }
        return files.first { $0.id == id as String }
    }

    private func hasThirdLine(_ file: MaintenanceFile) -> Bool {
        controller.blocked(file) || (!file.verifiedIdentity && controller.section == .uninstaller)
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        // Boş durum: VStack(spacing: 10), ortalı.
        let s = symbol.layoutSize
        let hw = pixelCeil(hint.exactWidth)
        let total = s.height + 10 + hint.lineHeight
        let top = (bounds.height - total) / 2
        symbol.frame = symbol.drawingFrame(layoutOrigin: CGPoint(x: (bounds.width - s.width) / 2, y: top))
        hint.frame = CGRect(x: (bounds.width - hw) / 2, y: top + s.height + 10, width: hw, height: hint.lineHeight)
    }
}

/// SwiftUI `List` anahattı: AX çerçevesi görünür kaydırma alanıdır (belgenin tamamı değil).
final class MaintenanceOutlineView: NSOutlineView {
    override func accessibilityFrame() -> NSRect { enclosingScrollView?.accessibilityFrame() ?? super.accessibilityFrame() }
}

/// Satır: seçim vurgusu yok; altında, metin başlangıcından hücre sonuna 1 pt ayırıcı (son satır hariç).
private final class MaintenanceFileRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override func draw(_ dirtyRect: NSRect) {
        guard let outline = superview as? NSOutlineView else { return }
        let row = outline.row(for: self)
        guard row >= 0, row < outline.numberOfRows - 1 else { return }
        // Liste koordinatlarında metnin başından (35) 588'e kadar (SwiftUI ayırıcısı, ölçüldü).
        let origin = enclosingScrollView.map { convert(CGPoint.zero, to: $0) } ?? .zero
        let x = MaintenanceFileCell.textX - origin.x
        NSColor.separatorColor.setFill()
        NSRect(x: x, y: bounds.height - 1, width: 588 - origin.x - x, height: 1).fill()
    }
}

/// Dosya satırının hücresi (SwiftUI satırı: Toggle(checkbox){ad + tür / yol / uyarı}, boyut, Finder düğmesi).
@MainActor
private final class MaintenanceFileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("MaintenanceFileCell")
    /// Liste (kaydırma alanı) koordinatlarında ölçülen yerler: onay kutusu kabının başı, metnin başı, satır içeriğinin
    /// sonu (Finder düğmesinin sağ kenarı).
    static let toggleX: CGFloat = 16
    static let textX: CGFloat = 16 + 19
    static let contentMaxX: CGFloat = 588
    static let toggleInset: CGFloat = 6
    static let textInset: CGFloat = 6 + 19
    static func contentHeight(lines: Int) -> CGFloat { lines == 3 ? 48 : 32 }

    private let controller: MaintenanceController
    private var file: MaintenanceFile?
    private let toggle = MaintenanceToggleView()
    private let size = TextLabel("", font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular), color: .secondaryLabelColor)
    private let reveal = PlainButton()
    private let revealSymbol = SymbolView("folder", size: 13, color: .secondaryLabelColor) // kenarlıksız düğme: ikincil renk (ölçüldü)

    init(controller: MaintenanceController) {
        self.controller = controller
        super.init(frame: .zero)
        identifier = Self.identifier
        reveal.addSubview(revealSymbol)
        reveal.toolTip = "Finder'da göster"
        reveal.action = { [weak self] in self?.showInFinder() }
        toggle.onToggle = { [weak self] on in self?.setSelected(on) }
        size.setAccessibilityElement(true)
        [toggle, size, reveal].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override var isFlipped: Bool { true }

    func configure(_ file: MaintenanceFile) {
        self.file = file
        update()
        if bounds.width > 0 { layoutSubtreeIfNeeded() } // yeniden kullanılan hücre eski genişliği bildirmesin
    }

    func update() {
        guard let file else { return }
        let blocked = controller.blocked(file)
        var third: (String, NSColor)?
        if blocked { third = ("Açık uygulama: korunuyor", .systemOrange) }
        else if !file.verifiedIdentity, controller.section == .uninstaller {
            third = ("Ad eşleşmesi; başka bir uygulama ile paylaşılabilir.", .secondaryLabelColor)
        }
        toggle.configure(name: file.url.lastPathComponent, kind: Self.kind(file),
                         kindColor: file.containsPersonalData ? .systemOrange : .secondaryLabelColor,
                         path: file.url.path, third: third,
                         on: controller.selectedFiles.contains(file.id), enabled: !(controller.busy || blocked))
        size.set((file.fullyMeasured ? "" : "≥ ") + MaintenanceController.size(file.bytes))
        size.toolTip = file.fullyMeasured ? "Dosyaların toplam boyutu; fiziksel boşalacak alan farklı olabilir." : "Bazı dosyalar okunamadı; bilinen boyut gösteriliyor."
        reveal.setAccessibilityLabel("\(file.url.lastPathComponent) öğesini Finder'da göster")
        needsLayout = true
    }

    private func setSelected(_ on: Bool) {
        guard let file else { return }
        if on { controller.selectedFiles.insert(file.id) } else { controller.selectedFiles.remove(file.id) }
    }

    private func showInFinder() { if let file { controller.reveal(file) } }

    static func kind(_ file: MaintenanceFile) -> String {
        if file.isApplication { return "Uygulama" }
        switch file.kind {
        case .cache: return "Önbellek"
        case .preferences: return "Tercihler"
        case .logs: return "Günlükler"
        case .savedState: return "Pencere durumu"
        case .data: return "Kişisel veriler"
        case nil: return "Dosya"
        }
    }

    override func layout() {
        super.layout()
        // Hücre içi: 4 pt dikey dolgu (+ satır payı); HStack(spacing: 10) ortalı.
        let h = bounds.height
        // Hücrenin listedeki konumu stile göre değişir; içerik liste koordinatlarında ölçülen yerlere oturur.
        let origin = enclosingScrollView.map { convert(CGPoint.zero, to: $0) } ?? .zero
        let left = Self.toggleX - origin.x, right = Self.contentMaxX - origin.x
        let symbolSize = revealSymbol.layoutSize
        let buttonOrigin = CGPoint(x: right - symbolSize.width, y: (h - symbolSize.height) / 2)
        revealSymbol.place(asLabelOf: reveal, layoutOrigin: buttonOrigin)
        let sw = pixelCeil(size.exactWidth)
        size.frame = CGRect(x: reveal.frame.minX - 10 - sw, y: (h - size.lineHeight) / 2, width: sw, height: size.lineHeight)
        let toggleHeight = toggle.contentHeight
        let toggleWidth = min(toggle.fittingWidth, size.frame.minX - 10 - left)
        toggle.frame = CGRect(x: left, y: (h - toggleHeight) / 2, width: max(toggleWidth, 0), height: toggleHeight)
    }
}

/// SwiftUI `Toggle(isOn:){ VStack }.toggleStyle(.checkbox)`: onay kutusu + çok satırlı etiket; AX'te tek onay kutusu,
/// etiket satırların birleşimi.
@MainActor
private final class MaintenanceToggleView: FlippedView {
    var onToggle: ((Bool) -> Void)?
    private let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let name = TextLabel("", font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
    private let kind = TextLabel("", font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
    private let path = TextLabel("", font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
    private let third = TextLabel("", font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
    private var hasThird = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        box.target = self
        box.action = #selector(toggled)
        box.setAccessibilityElement(false)
        [name, kind, path, third].forEach { $0.setAccessibilityElement(false); addSubview($0) }
        addSubview(box)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    @objc private func toggled() { onToggle?(box.state == .on) }

    override func accessibilityValue() -> Any? { box.state == .on ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { box.performClick(nil); return true }
    override func isAccessibilityEnabled() -> Bool { box.isEnabled }

    func configure(name: String, kind: String, kindColor: NSColor, path: String, third: (String, NSColor)?, on: Bool, enabled: Bool) {
        self.name.set(name)
        self.kind.set(kind)
        self.kind.textColor = kindColor
        self.path.set(path)
        self.path.toolTip = path
        hasThird = third != nil
        self.third.isHidden = !hasThird
        if let third { self.third.set(third.0); self.third.textColor = third.1 }
        box.state = on ? .on : .off
        box.isEnabled = enabled
        // Devre dışı SwiftUI `Toggle`: yalnız birincil renkli metin soluklaşır; ikincil ve renkli metinler aynı kalır (ölçüldü).
        self.name.textColor = enabled ? .labelColor : .tertiaryLabelColor
        setAccessibilityLabel([name, kind, path, third?.0].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    var contentHeight: CGFloat { MaintenanceFileCell.contentHeight(lines: hasThird ? 3 : 2) }
    var fittingWidth: CGFloat {
        let first = pixelCeil(name.exactWidth) + 6 + pixelCeil(kind.exactWidth)
        let lines = [first, pixelCeil(path.exactWidth), hasThird ? pixelCeil(third.exactWidth) : 0]
        return MaintenanceFileCell.textInset - MaintenanceFileCell.toggleInset + (lines.max() ?? 0)
    }

    override func layout() {
        super.layout()
        let tx = MaintenanceFileCell.textInset - MaintenanceFileCell.toggleInset
        let available = bounds.width - tx
        // Kutu hizalama dikdörtgeniyle kabın başına oturur (çerçevenin sol payı dışarıda kalır).
        let boxSize = box.fittingSize
        box.frame = CGRect(x: -box.alignmentRectInsets.left, y: (name.lineHeight - boxSize.height) / 2, width: boxSize.width, height: boxSize.height)
        let nw = min(pixelCeil(name.exactWidth), available)
        name.frame = CGRect(x: tx, y: 0, width: nw, height: name.lineHeight)
        // Ad satırı HStack(spacing: 6): ad + tür (taban çizgisi değil, ortalı).
        let kw = pixelCeil(kind.exactWidth)
        kind.frame = CGRect(x: tx + nw + 6, y: (name.lineHeight - kind.lineHeight) / 2, width: min(kw, max(available - nw - 6, 0)), height: kind.lineHeight)
        path.frame = CGRect(x: tx, y: name.lineHeight + 3, width: min(pixelCeil(path.exactWidth), available), height: path.lineHeight)
        third.frame = CGRect(x: tx, y: path.frame.maxY + 3, width: min(pixelCeil(third.exactWidth), available), height: third.lineHeight)
    }
}

/// Alt satır: "N seçili · boyut" + [Tümünü seç] + Seçimi kaldır + Çöp Sepeti'ne Taşı.
@MainActor
final class MaintenanceTrashControls: FlippedView {
    private let controller: MaintenanceController
    private let summary = TextLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let selectAll = MaintenanceButton(title: "Tümünü seç", symbol: nil)
    private let clear = MaintenanceButton(title: "Seçimi kaldır", symbol: nil)
    private let trash = MaintenanceButton(title: "Çöp Sepeti'ne Taşı", symbol: "trash")
    private let showsSelectAll: Bool

    init(controller: MaintenanceController, showsSelectAll: Bool) {
        self.controller = controller
        self.showsSelectAll = showsSelectAll
        super.init(frame: .zero)
        selectAll.toolTip = "Korunan ve açık uygulamalara ait bilinen önbellekleri seçmez"
        selectAll.isHidden = !showsSelectAll
        [summary, selectAll, clear, trash].forEach(addSubview)
        for b in [selectAll, clear, trash] { b.target = self }
        selectAll.action = #selector(selectAllCaches)
        clear.action = #selector(clearSelection)
        trash.action = #selector(moveToTrash)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    @objc private func selectAllCaches() { controller.selectAllCaches() }
    @objc private func clearSelection() { controller.selectedFiles = [] }
    @objc private func moveToTrash() { controller.confirmTrash() }

    var preferredHeight: CGFloat { max(summary.lineHeight, clear.alignmentSize.height) }

    func update() {
        summary.set("\(controller.selectedFiles.count) seçili · \(MaintenanceController.size(controller.selectedBytes))")
        selectAll.isEnabled = !(controller.busy || controller.selectableCacheCount == 0)
        clear.isEnabled = !(controller.busy || controller.selectedFiles.isEmpty)
        trash.isEnabled = !(controller.busy || controller.selectedFiles.isEmpty)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        summary.frame = CGRect(x: 0, y: (h - summary.lineHeight) / 2, width: pixelCeil(summary.exactWidth), height: summary.lineHeight)
        var right = bounds.width
        for button in [trash, clear, selectAll] where !button.isHidden {
            let s = button.alignmentSize
            button.setAlignmentFrame(CGRect(x: right - s.width, y: (h - s.height) / 2, width: s.width, height: s.height))
            right -= s.width + 8
        }
    }
}

/// Kaldırıcı: uygulama seçici + Kalıntıları tara, seçili uygulamanın yolu (+ açıkken uyarı), dosya listesi, alt satır.
@MainActor
final class MaintenanceUninstallView: MaintenanceSectionView {
    private let pickerLabel = TextLabel("Uygulama", font: .systemFont(ofSize: 13), color: .labelColor)
    private let picker = MaintenancePopUpButton(frame: .zero, pullsDown: false)
    private let scan = MaintenanceButton(title: "Kalıntıları tara", symbol: "magnifyingglass")
    private let path = TextLabel("", font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
    private let running = IconLabelView("Önce uygulamadan çık", symbol: "exclamationmark.circle", font: .systemFont(ofSize: 10),
                                        color: .systemOrange)
    private let list: MaintenanceFileListView
    private let controls: MaintenanceTrashControls
    private var pickerIDs: [String] = []

    override init(controller: MaintenanceController) {
        list = MaintenanceFileListView(controller: controller, symbol: "trash")
        controls = MaintenanceTrashControls(controller: controller, showsSelectAll: false)
        super.init(controller: controller)
        pickerLabel.setAccessibilityElement(true)
        picker.target = self
        picker.action = #selector(choose)
        scan.target = self
        scan.action = #selector(scanFiles)
        [pickerLabel, picker, scan, path, running, list, controls].forEach(addSubview)
    }

    @objc private func choose() {
        let index = picker.indexOfSelectedItem
        guard pickerIDs.indices.contains(index), let app = controller.applications.first(where: { $0.id == pickerIDs[index] }) else { return }
        controller.choose(app)
    }

    @objc private func scanFiles() { controller.scan() }

    override func update() {
        let apps = controller.applications
        let ids = apps.map(\.id)
        if ids != pickerIDs || picker.numberOfItems == 0 {
            pickerIDs = ids
            picker.removeAllItems()
            if apps.isEmpty { picker.addItem(withTitle: "Uygulama bulunamadı") }
            for app in apps { picker.addItem(withTitle: "\(app.name) — \(app.version)") }
        }
        if let id = controller.applicationID, let index = pickerIDs.firstIndex(of: id), picker.indexOfSelectedItem != index {
            picker.selectItem(at: index)
        }
        picker.isEnabled = !controller.busy
        scan.isEnabled = !(controller.busy || controller.selectedApplication == nil)
        let app = controller.selectedApplication
        path.set(app?.url.path ?? "")
        path.toolTip = app?.url.path
        path.isHidden = app == nil
        running.isHidden = app.map { !controller.runningBundleIDs.contains($0.bundleID) } ?? true
        list.update()
        controls.update()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // VStack(spacing: 12): seçici satırı, yol satırı, liste, alt satır.
        let width = bounds.width
        let rowHeight = max(picker.alignmentSize.height, scan.alignmentSize.height, pickerLabel.lineHeight)
        let labelWidth = pixelCeil(pickerLabel.exactWidth)
        pickerLabel.frame = CGRect(x: 0, y: (rowHeight - pickerLabel.lineHeight) / 2, width: labelWidth, height: pickerLabel.lineHeight)
        let scanSize = scan.alignmentSize
        scan.setAlignmentFrame(CGRect(x: width - scanSize.width, y: (rowHeight - scanSize.height) / 2, width: scanSize.width, height: scanSize.height))
        let pickerX = labelWidth + 8
        let pickerHeight = picker.alignmentSize.height
        picker.setAlignmentFrame(CGRect(x: pickerX, y: (rowHeight - pickerHeight) / 2, width: width - scanSize.width - 8 - pickerX, height: pickerHeight))
        var y = rowHeight + 12
        if !path.isHidden {
            let lineHeight = max(path.lineHeight, running.isHidden ? 0 : running.fittingSize.height)
            path.frame = CGRect(x: 0, y: y + (lineHeight - path.lineHeight) / 2, width: min(pixelCeil(path.exactWidth), width), height: path.lineHeight)
            if !running.isHidden {
                let s = running.fittingSize
                running.frame = CGRect(x: width - s.width, y: y + (lineHeight - s.height) / 2, width: s.width, height: s.height)
            }
            y += lineHeight + 12
        }
        let controlsHeight = controls.preferredHeight
        controls.frame = CGRect(x: 0, y: bounds.height - controlsHeight, width: width, height: controlsHeight)
        list.frame = CGRect(x: 0, y: y, width: width, height: bounds.height - controlsHeight - 12 - y)
    }
}

/// Önbellek temizleyici: "~/Library/Caches" etiketi + Önbellekleri tara, dosya listesi, alt satır (Tümünü seç ile).
@MainActor
final class MaintenanceCleanerView: MaintenanceSectionView {
    private let location = IconLabelView("~/Library/Caches", symbol: "folder", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let scan = MaintenanceButton(title: "Önbellekleri tara", symbol: "magnifyingglass")
    private let list: MaintenanceFileListView
    private let controls: MaintenanceTrashControls

    override init(controller: MaintenanceController) {
        list = MaintenanceFileListView(controller: controller, symbol: "sparkles")
        controls = MaintenanceTrashControls(controller: controller, showsSelectAll: true)
        super.init(controller: controller)
        scan.target = self
        scan.action = #selector(scanFiles)
        [location, scan, list, controls].forEach(addSubview)
    }

    @objc private func scanFiles() { controller.scan() }

    override func update() {
        scan.isEnabled = !controller.busy
        list.update()
        controls.update()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let ls = location.fittingSize
        let scanSize = scan.alignmentSize
        let rowHeight = max(ls.height, scanSize.height)
        location.frame = CGRect(x: 0, y: (rowHeight - ls.height) / 2, width: ls.width, height: ls.height)
        scan.setAlignmentFrame(CGRect(x: width - scanSize.width, y: (rowHeight - scanSize.height) / 2, width: scanSize.width, height: scanSize.height))
        let y = rowHeight + 12
        let controlsHeight = controls.preferredHeight
        controls.frame = CGRect(x: 0, y: bounds.height - controlsHeight, width: width, height: controlsHeight)
        list.frame = CGRect(x: 0, y: y, width: width, height: bounds.height - controlsHeight - 12 - y)
    }
}

/// Açılır menü: hizalama dikdörtgeniyle yerleşir, AX çerçevesi hizalama dikdörtgeni.
final class MaintenancePopUpButton: NSPopUpButton, AlignedControl {
    /// Öğeler ve seçim değişmedikçe önbellekten.
    var alignmentSize: CGSize {
        let key = "\(numberOfItems)|\(titleOfSelectedItem ?? "")"
        if let cachedSize, cachedSize.key == key { return cachedSize.size }
        let size = fittingSize
        let i = alignmentRectInsets
        let result = CGSize(width: size.width - i.left - i.right, height: size.height - i.top - i.bottom)
        cachedSize = (key, result)
        return result
    }

    private var cachedSize: (key: String, size: CGSize)?

    override func accessibilityFrame() -> NSRect { alignmentScreenFrame() ?? super.accessibilityFrame() }
}

// Shared with SettingsForm: this helper is not owned by the removed updater.
extension TextLabel {
    /// Redraw a resized/truncated label without changing the shared per-frame path.
    func setFrameRedrawing(_ rect: CGRect) {
        let resized = rect.size != frame.size
        frame = rect
        if resized { needsDisplay = true }
    }
}
