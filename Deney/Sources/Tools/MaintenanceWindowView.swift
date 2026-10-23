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
        sidebar.update(selected: section, enabled: !(controller.busy && !controller.isScanningUpdates))
        title.set(section.rawValue)
        refresh.isHidden = section == .cleaner
        refresh.setTitle(section == .updater ? "Yeniden tara" : "Listeyi yenile")
        refresh.isEnabled = !controller.busy
        summary.set(Self.description(section))
        if shownSection != section {
            shownSection = section
            sectionView?.removeFromSuperview()
            let view: MaintenanceSectionView = switch section {
            case .uninstaller: MaintenanceUninstallView(controller: controller)
            case .cleaner: MaintenanceCleanerView(controller: controller)
            case .updater: MaintenanceUpdaterView(controller: controller)
            }
            content.addSubview(view)
            sectionView = view
        }
        sectionView?.update()
        statusRow.update(busy: controller.busy, status: controller.status.isEmpty ? "Hazır." : controller.status)
        needsLayout = true
    }

    @objc private func reload() { controller.loadApplications() }

    private static func description(_ section: MaintenanceController.Section) -> String {
        switch section {
        case .uninstaller:
            "Uygulamayı seç, kalıntılarını tara ve kaldırılacak öğeleri denetle. Kişisel veriler ve ada göre eşleşen klasörler ayrıca seçilir. Paylaşılan grup klasörlerine ve sistem yardımcılarına dokunulmaz."
        case .cleaner:
            "Kullanıcı önbelleklerini isteğe bağlı tara. Açık uygulamalara ait bilinen önbellekler korunur. Önce ilgili uygulamaları kapat; önbellekler daha sonra yeniden oluşabilir."
        case .updater:
            "Bu bölümü açınca mağaza, uygulama kaynağı ve ek sürüm kataloğu denetlenir. Güncelleme bulunanları seçip onayla; indirme veya mağaza sayfaları açılır. Sürümü doğrulanamayanlar güncel sayılmaz."
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
        title.frame = CGRect(x: pad, y: pad, width: pixelCeil(title.exactWidth), height: titleHeight)
        if !refresh.isHidden {
            let s = refresh.alignmentSize
            refresh.setAlignmentFrame(CGRect(x: pad + width - s.width, y: pad + (titleHeight - s.height) / 2, width: s.width, height: s.height))
        }
        var y = pad + titleHeight + 14
        let summaryHeight = summary.height(forWidth: width)
        summary.frame = CGRect(x: pad, y: y, width: width, height: summaryHeight)
        y += summaryHeight + 14
        let statusHeight: CGFloat = 54
        let statusY = main.bounds.height - pad - statusHeight
        statusRow.frame = CGRect(x: pad, y: statusY, width: width, height: statusHeight)
        let dividerY = statusY - 14 - 1
        bottomDivider.frame = CGRect(x: pad, y: dividerY, width: width, height: 1)
        content.frame = CGRect(x: pad, y: y, width: width, height: dividerY - 14 - y)
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
        header.frame = CGRect(x: pad, y: pad, width: headerSize.width, height: headerSize.height)
        // VStack(spacing: 8): başlık + 12 pt alt boşluk, düğmeler (Label + 10 pt dolgu).
        var y = pad + headerSize.height + 12 + 8
        for section in MaintenanceController.Section.allCases {
            guard let button = buttons[section] else { continue }
            let h = button.preferredHeight
            button.frame = CGRect(x: pad, y: y, width: width, height: h)
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

    var preferredHeight: CGFloat { label.fittingSize.height + 20 }

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
        label.frame = CGRect(x: 10, y: 10, width: s.width, height: s.height)
    }
}

/// Yuvarlak köşeli vurgu zemini (`Color.accentColor.opacity(0.15)`).
private final class MaintenanceFillView: NSView {
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
    var alignmentSize: CGSize {
        let text = (title as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 13)]).width
        let i = alignmentRectInsets
        return CGSize(width: pixelCeil(text + 16 + (symbolWidth > 0 ? symbolWidth + 8 : 0)),
                      height: fittingSize.height - i.top - i.bottom)
    }

    override func accessibilityFrame() -> NSRect { alignmentScreenFrame() ?? super.accessibilityFrame() }
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
        let size = text.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)) ?? .zero
        text.frame = CGRect(x: 0, y: 0, width: width, height: ceil(size.height))
        scroll.documentView?.frame = CGRect(x: 0, y: 0, width: width, height: max(ceil(size.height), scroll.contentSize.height))
    }
}

/// Seçilebilir durum metni: AX çerçevesi metnin kullandığı alan (SwiftUI `Text`), alanın tamamı değil.
private final class MaintenanceStatusField: NSTextField {
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
}

/// Dosya listesi alanı (metin arka plan rengi, 8 pt köşe): boşken bölüm simgesi + yönerge ortada.
@MainActor
final class MaintenanceFileListView: FlippedView {
    private let symbol: SymbolView
    private let hint = TextLabel("Dosyaları görmek için taramayı başlat.", font: .systemFont(ofSize: 13), color: .secondaryLabelColor)

    init(symbol name: String) {
        symbol = SymbolView(name, size: 30, color: .secondaryLabelColor)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        symbol.exposeAsImage()
        [symbol, hint].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    nonisolated override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.textBackgroundColor.cgColor }
    }

    override func layout() {
        super.layout()
        // VStack(spacing: 10), ortalı.
        let s = symbol.layoutSize
        let hw = pixelCeil(hint.exactWidth)
        let total = s.height + 10 + hint.lineHeight
        let top = (bounds.height - total) / 2
        symbol.frame = symbol.drawingFrame(layoutOrigin: CGPoint(x: (bounds.width - s.width) / 2, y: top))
        hint.frame = CGRect(x: (bounds.width - hw) / 2, y: top + s.height + 10, width: hw, height: hint.lineHeight)
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
    private let list = MaintenanceFileListView(symbol: "trash")
    private let controls: MaintenanceTrashControls
    private var pickerIDs: [String] = []

    override init(controller: MaintenanceController) {
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
    private let list = MaintenanceFileListView(symbol: "sparkles")
    private let controls: MaintenanceTrashControls

    override init(controller: MaintenanceController) {
        controls = MaintenanceTrashControls(controller: controller, showsSelectAll: true)
        super.init(controller: controller)
        scan.target = self
        scan.action = #selector(scanFiles)
        [location, scan, list, controls].forEach(addSubview)
    }

    @objc private func scanFiles() { controller.scan() }

    override func update() {
        scan.isEnabled = !controller.busy
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

/// Güncelleyici (sonraki adımda tamamlanacak).
@MainActor
final class MaintenanceUpdaterView: MaintenanceSectionView {}

/// Açılır menü: hizalama dikdörtgeniyle yerleşir, AX çerçevesi hizalama dikdörtgeni.
final class MaintenancePopUpButton: NSPopUpButton, AlignedControl {
    var alignmentSize: CGSize {
        let size = fittingSize
        let i = alignmentRectInsets
        return CGSize(width: size.width - i.left - i.right, height: size.height - i.top - i.bottom)
    }

    override func accessibilityFrame() -> NSRect { alignmentScreenFrame() ?? super.accessibilityFrame() }
}
