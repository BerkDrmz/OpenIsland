import AppKit

/// SwiftUI `Form.formStyle(.grouped)` karşılığı (macOS; SwiftUI'nin çizdiği katmanlar çalışma anında okunmuştur):
/// gri zemin + duvar kâğıdı tonu, 20 pt kenar boşluğu, bölümler arası 30 pt; bölüm: başlık (13 pt kalın) + 10 pt +
/// kutu (6 pt sürekli köşe, dolgu ve 0,5 pt kenarlık) + 10 pt + açıklama (caption, ikincil, sağa hizalı).
/// Satırlar kutunun 10 pt içinde; aralarında 1 pt ayırıcı.
@MainActor
final class SettingsFormView: FlippedView {
    let scroll = SettingsScrollView()
    private let document = FlippedView()
    private let background = SettingsFormBackground()
    private(set) var sections: [SettingsSection] = []
    private var generation = 0
    private let onRefresh: (() -> Void)?

    init(sections: [SettingsSection], onRefresh: (() -> Void)? = nil) {
        self.sections = sections
        self.onRefresh = onRefresh
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        for section in sections {
            if let header = section.header { document.addSubview(header) }
            document.addSubview(section.box)
            if let footer = section.footer { document.addSubview(footer) }
        }
        addSubview(background)
        addSubview(scroll)
        // SwiftUI: sekme içeriği bir AX grubu (barındırma görünümü), içinde kaydırma alanı.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    /// Model gözlenir: yalnız okunan değerler değişince satırlar yeniden okunur.
    private func observe() {
        generation += 1
        let token = generation
        withObservationTracking { refresh() } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    self.observe()
                }
            }
        }
    }

    func refresh() {
        onRefresh?()
        for section in sections { section.refresh() }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        scroll.frame = bounds
        let width = bounds.width // SwiftUI: içerik tam genişlikte, kaydırma çubuğu üstünde
        var y: CGFloat = 20
        for section in sections where !section.isHidden {
            y = section.layout(at: y, width: width) + 30
        }
        let height = max(y - 30 + 20, scroll.contentSize.height)
        document.frame = CGRect(x: 0, y: 0, width: width, height: height)
    }
}

/// SwiftUI `HostingScrollView` gibi: kırpma görünümü tam genişlikte, eski tarz kaydırma çubuğu içeriğin üstünde.
final class SettingsScrollView: NSScrollView {
    override func tile() {
        super.tile()
        contentView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
    }
}

/// Form zemini: SwiftUI düz gri katman + duvar kâğıdı tonu (`CAChameleonLayer`) ile pencere zemini malzemesini kopyalar
/// (aynı konumda pencerenin kendi zeminiyle piksel piksel aynı, ölçüldü). AppKit'te aynı sonuç malzemenin kendisiyle:
/// pencere içi karışımlı, hep etkin `windowBackground` efekt görünümü.
@MainActor
private final class SettingsFormBackground: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .windowBackground
        blendingMode = .withinWindow
        state = .active
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSAppearance {
    var isDarkForm: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// Bölüm: isteğe bağlı başlık ve açıklama (açıklama metni dinamik olabilir), satırları taşıyan kutu.
@MainActor
final class SettingsSection {
    let header: TextLabel?
    let box: SettingsBoxView
    let footer: TextLabel?
    private let footerText: (() -> String)?
    var isHidden = false

    init(header: String? = nil, rows: [SettingsRow], footer: String? = nil, dynamicFooter: (() -> String)? = nil) {
        if let header {
            let label = TextLabel(header, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor) // ölçüldü
            label.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
            self.header = label
        } else {
            self.header = nil
        }
        box = SettingsBoxView(rows: rows)
        footerText = dynamicFooter
        if footer != nil || dynamicFooter != nil {
            let label = TextLabel(footer ?? "", font: .systemFont(ofSize: 10), color: .secondaryLabelColor, alignment: .right)
            label.maximumLines = 0
            label.lineBreakStrategy = .standard
            self.footer = label
        } else {
            self.footer = nil
        }
    }

    func refresh() {
        for row in box.rows { row.refresh() }
        if let footerText { footer?.set(footerText()) }
        box.needsLayout = true
    }

    /// `y`'den başlayarak yerleşir; bölümün alt kenarını döndürür.
    func layout(at top: CGFloat, width: CGFloat) -> CGFloat {
        var y = top
        let inner = width - 40
        if let header {
            header.frame = CGRect(x: 30, y: y, width: min(pixelCeil(header.exactWidth), inner - 20), height: 16)
            y += 16 + 10
        }
        let boxHeight = box.preferredHeight(width: inner)
        box.frame = CGRect(x: 20, y: y, width: inner, height: boxHeight)
        y += boxHeight
        if let footer {
            // Açıklama kutunun sol kenarından sağdan 10 pt içeriye kadar kayar, sağa hizalı (ölçüldü).
            let height = footer.height(forWidth: inner - 10)
            footer.setFrameRedrawing(CGRect(x: 20, y: y + 10, width: inner - 10, height: height))
            y += 10 + height
        }
        return y
    }
}

/// Kutu: dolgu ve kenarlık (6 pt sürekli köşe, 0,5 pt), satırlar arasında 1 pt ayırıcı (kutunun 10 pt içinden).
@MainActor
final class SettingsBoxView: FlippedView {
    let rows: [SettingsRow]
    private let border = CALayer()
    private var separators: [CALayer] = []

    init(rows: [SettingsRow]) {
        self.rows = rows
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        border.cornerRadius = 6
        border.cornerCurve = .continuous
        border.borderWidth = 0.5
        border.zPosition = 10
        layer?.addSublayer(border)
        rows.forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    private var visibleRows: [SettingsRow] { rows.filter { !$0.isHidden } }

    func preferredHeight(width: CGFloat) -> CGFloat {
        let visible = visibleRows
        return visible.reduce(0) { $0 + $1.preferredHeight(width: width - 20) } + CGFloat(max(visible.count - 1, 0))
    }

    nonisolated override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.isDarkForm
        layer?.backgroundColor = dark ? CGColor(gray: 1, alpha: 0.015) : CGColor(gray: 0, alpha: 0.015)
        border.borderColor = dark ? CGColor(gray: 1, alpha: 0.12) : CGColor(gray: 0, alpha: 0.06)
        let separator = dark ? CGColor(gray: 1, alpha: 0.0471) : CGColor(gray: 0, alpha: 0.0471)
        separators.forEach { $0.backgroundColor = separator }
    }

    override func layout() {
        super.layout()
        let visible = visibleRows
        while separators.count < max(visible.count - 1, 0) {
            let line = CALayer()
            line.zPosition = 5
            layer?.addSublayer(line)
            separators.append(line)
            needsDisplay = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        var y: CGFloat = 0
        for (index, row) in visible.enumerated() {
            let height = row.preferredHeight(width: bounds.width - 20)
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
            if index < visible.count - 1 {
                separators[index].isHidden = false
                separators[index].frame = CGRect(x: 10, y: y, width: bounds.width - 20, height: 1)
                y += 1
            }
        }
        for index in max(visible.count - 1, 0)..<separators.count { separators[index].isHidden = true }
        CATransaction.commit()
    }
}

/// Satır tabanı: içerik kutunun 10 pt içinde (`contentWidth` = kutu − 20).
@MainActor
class SettingsRow: FlippedView {
    func preferredHeight(width: CGFloat) -> CGFloat { 36 }
    func refresh() {}
    var contentWidth: CGFloat { bounds.width - 20 }
}

/// `Toggle(başlık, isOn:)`: solda başlık, sağda küçük anahtar (AX: 26 × 15, çerçeve 28 × 16).
@MainActor
final class SettingsToggleRow: SettingsRow {
    private let title: TextLabel
    private let toggle = SettingsSwitch()
    private let get: () -> Bool
    private let set: (Bool) -> Void
    private let enabled: (() -> Bool)?

    init(_ title: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void, enabled: (() -> Bool)? = nil) {
        self.title = TextLabel(title, font: .systemFont(ofSize: 13), color: .labelColor)
        self.get = get
        self.set = set
        self.enabled = enabled
        super.init(frame: .zero)
        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = #selector(changed)
        addSubview(self.title)
        addSubview(toggle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    @objc private func changed() { set(toggle.state == .on) }

    override func refresh() {
        let state: NSControl.StateValue = get() ? .on : .off
        if toggle.state != state { toggle.state = state }
        let isEnabled = enabled?() ?? true
        if toggle.isEnabled != isEnabled {
            toggle.isEnabled = isEnabled
            title.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        }
    }

    override func layout() {
        super.layout()
        let available = contentWidth - 26 - 8
        title.frame = CGRect(x: 10, y: 10, width: min(pixelCeil(title.exactWidth), available), height: 16)
        toggle.frame = CGRect(x: 10 + contentWidth - 26 - 1, y: 11, width: 28, height: 16) // AX kutusu 26 × 15, y 11 (ölçüldü)
    }
}

/// `Picker(.segmented)`: solda başlık, sağda kontrol sütununun tamamı (içeriğin %55'i; ölçüldü), satır 40 pt.
@MainActor
final class SettingsSegmentedRow: SettingsRow {
    private let title: TextLabel
    private let control: NSSegmentedControl
    private let get: () -> Int
    private let set: (Int) -> Void

    init(_ title: String, items: [String], get: @escaping () -> Int, set: @escaping (Int) -> Void) {
        self.title = TextLabel(title, font: .systemFont(ofSize: 13), color: .labelColor)
        control = SettingsSegmentedControl(labels: items, trackingMode: .selectOne, target: nil, action: nil)
        self.get = get
        self.set = set
        super.init(frame: .zero)
        control.segmentDistribution = .fillEqually
        control.target = self
        control.action = #selector(changed)
        addSubview(self.title)
        addSubview(control)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    @objc private func changed() { set(control.selectedSegment) }

    override func preferredHeight(width: CGFloat) -> CGFloat { 40 }

    override func refresh() {
        let index = get()
        if control.selectedSegment != index { control.selectedSegment = index }
    }

    override func layout() {
        super.layout()
        let controlWidth = pixelRound(contentWidth * 0.55)
        let x = 10 + contentWidth - controlWidth
        title.frame = CGRect(x: 10, y: 10, width: min(pixelCeil(title.exactWidth), x - 18), height: 16)
        control.frame = CGRect(x: x - 2, y: 7, width: controlWidth + 4, height: 24)
    }
}

/// SwiftUI `Toggle` anahtarı: AX onay kutusu, çerçevesi 26 × 15 (NSSwitch çerçevesinin 1 pt içi; ölçüldü).
final class SettingsSwitch: NSSwitch {
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(CGRect(x: 1, y: isFlipped ? 0 : 1, width: 26, height: 15), to: nil))
    }
}

/// SwiftUI parçalı seçici: AX çerçevesi denetimin hizalama kutusu (çerçevenin 2 pt yanlardan, 1 pt üst/alttan içi).
final class SettingsSegmentedControl: NSSegmentedControl {
    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(bounds.insetBy(dx: 2, dy: 1), to: nil))
    }
}

/// `Picker` (açılır menü): solda başlık, sağda doğal genişlikte menü.
@MainActor
final class SettingsPopUpRow: SettingsRow {
    private let title: TextLabel
    private let popup = MaintenancePopUpButton(frame: .zero, pullsDown: false)
    private let get: () -> Int
    private let set: (Int) -> Void

    init(_ title: String, items: [String], get: @escaping () -> Int, set: @escaping (Int) -> Void) {
        self.title = TextLabel(title, font: .systemFont(ofSize: 13), color: .labelColor)
        self.get = get
        self.set = set
        super.init(frame: .zero)
        popup.addItems(withTitles: items)
        popup.target = self
        popup.action = #selector(changed)
        addSubview(self.title)
        addSubview(popup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    @objc private func changed() { set(popup.indexOfSelectedItem) }

    override func refresh() {
        let index = get()
        if popup.indexOfSelectedItem != index {
            popup.selectItem(at: index)
            needsLayout = true
        }
    }

    /// SwiftUI menü seçicisi seçili öğenin genişliğindedir (en uzun öğeninkinde değil; ölçüldü).
    private var selectedSize: CGSize {
        let title = popup.titleOfSelectedItem ?? ""
        if let cached = sizes[title] { return cached }
        let probe = NSPopUpButton(frame: .zero, pullsDown: false)
        probe.addItem(withTitle: title)
        let size = probe.fittingSize
        let i = probe.alignmentRectInsets
        let result = CGSize(width: size.width - i.left - i.right, height: size.height - i.top - i.bottom)
        sizes[title] = result
        return result
    }

    private var sizes: [String: CGSize] = [:]

    override func layout() {
        super.layout()
        let s = selectedSize
        popup.setAlignmentFrame(CGRect(x: 10 + contentWidth - s.width, y: 9, width: s.width, height: s.height))
        title.frame = CGRect(x: 10, y: 10, width: min(pixelCeil(title.exactWidth), contentWidth - s.width - 8), height: 16)
    }
}

/// Satır içi açıklama (`Text.font(.caption).foregroundStyle(.secondary)`): sola hizalı, satır en az 16 pt, ortalı.
@MainActor
final class SettingsCaptionRow: SettingsRow {
    private let text: TextLabel
    private let source: () -> String?

    init(_ source: @escaping () -> String?) {
        text = TextLabel("", font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
        self.source = source
        super.init(frame: .zero)
        text.maximumLines = 0
        text.lineBreakStrategy = .standard
        addSubview(text)
    }

    convenience init(_ value: String) { self.init { value } }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func refresh() {
        let value = source()
        isHidden = value == nil
        text.set(value ?? "")
    }

    override func preferredHeight(width: CGFloat) -> CGFloat { 20 + max(16, text.height(forWidth: width)) }

    override func layout() {
        super.layout()
        let height = text.height(forWidth: contentWidth)
        text.setFrameRedrawing(CGRect(x: 10, y: 10 + (max(16, height) - height) / 2, width: contentWidth, height: height))
    }
}

/// Satırda tek düğme (`Button(başlık)`), solda.
@MainActor
final class SettingsButtonRow: SettingsRow {
    private let button: MaintenanceButton
    private let visible: () -> Bool

    init(_ title: String, visible: @escaping () -> Bool, action: @escaping () -> Void) {
        button = MaintenanceButton(title: title, symbol: nil)
        self.visible = visible
        self.action = action
        super.init(frame: .zero)
        button.target = self
        button.action = #selector(pressed)
        addSubview(button)
    }

    private let action: () -> Void

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    @objc private func pressed() { action() }

    override func refresh() { isHidden = !visible() }

    override func layout() {
        super.layout()
        let s = button.alignmentSize
        button.setAlignmentFrame(CGRect(x: 10, y: 10 + (16 - s.height) / 2, width: s.width, height: s.height))
    }
}

/// İzin ve Space satırı: HStack(alignment: .firstTextBaseline, spacing: 12){ VStack(spacing: 2){başlık, açıklama},
/// Spacer(min 8), durum etiketi (caption, simge + metin), [düğme | "İzin bekleniyor…"] }; AX'te tek öğe.
@MainActor
final class SettingsStatusRow: SettingsRow {
    struct Content: Equatable {
        var title: String
        var detail: String
        var status: String
        var symbol: String
        var positive: Bool
        var action: String?
        var waiting: Bool
    }

    private let titleLabel = TextLabel("", font: .systemFont(ofSize: 13), color: .labelColor)
    private let detailLabel = TextLabel("", font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
    private var status: IconLabelView?
    private let waitingLabel = TextLabel("İzin bekleniyor…", font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
    private let button = MaintenanceButton(title: "", symbol: nil)
    private let source: () -> Content
    private let perform: (() -> Void)?
    private var content: Content?

    init(source: @escaping () -> Content, perform: (() -> Void)? = nil) {
        self.source = source
        self.perform = perform
        super.init(frame: .zero)
        detailLabel.maximumLines = 0
        detailLabel.lineBreakStrategy = .standard
        for label in [titleLabel, detailLabel, waitingLabel] { label.setAccessibilityElement(false) }
        button.setAccessibilityElement(false)
        button.cell?.setAccessibilityElement(false)
        button.target = self
        button.action = #selector(pressed)
        [titleLabel, detailLabel, waitingLabel, button].forEach(addSubview)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    @objc private func pressed() { perform?() }

    override func refresh() {
        let new = source()
        guard new != content else { return }
        let old = content
        content = new
        titleLabel.set(new.title)
        detailLabel.set(new.detail)
        if old?.status != new.status || old?.symbol != new.symbol || old?.positive != new.positive {
            status?.removeFromSuperview()
            let label = IconLabelView(new.status, symbol: new.symbol, font: .systemFont(ofSize: 10),
                                      color: new.positive ? .systemGreen : .secondaryLabelColor)
            label.setAccessibilityElement(false)
            label.spacing = 12 // caption Label: simge ile metin arası 12 pt (ölçüldü)
            label.snapsIconToWindow = true // etiket kesirli y'de; SwiftUI simgeyi pencere ızgarasına oturtur
            addSubview(label)
            status = label
        }
        button.isHidden = new.waiting || new.action == nil
        if let action = new.action { button.setTitle(action) }
        waitingLabel.isHidden = !new.waiting
        // SwiftUI `.accessibilityElement(children: .combine)`: düğme varsa düğme, yoksa metin.
        setAccessibilityRole(button.isHidden ? .staticText : .button)
        setAccessibilityLabel([new.title, new.detail, new.status, button.isHidden ? (new.waiting ? "İzin bekleniyor…" : nil) : new.action]
            .compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    override func accessibilityPerformPress() -> Bool {
        guard !button.isHidden else { return false }
        perform?()
        return true
    }

    /// Yerleşim (satır koordinatlarında, içerik üstü 0): öğe çerçeveleri ve içerik yüksekliği.
    private func arrange(width: CGFloat) -> (frames: [NSView: CGRect], height: CGFloat) {
        var trailing: [(NSView, CGSize)] = []
        if let status { trailing.append((status, status.fittingSize)) }
        if !waitingLabel.isHidden { trailing.append((waitingLabel, CGSize(width: pixelCeil(waitingLabel.exactWidth), height: 13))) }
        // SwiftUI düğme kutusu NSButton hizalama kutusundan 1 pt üstte ve altta büyük (22 pt; ölçüldü).
        if !button.isHidden { trailing.append((button, CGSize(width: button.alignmentSize.width, height: button.alignmentSize.height + 2))) }
        let trailingWidth = trailing.reduce(0) { $0 + $1.1.width + 12 }
        let textWidth = max(width - trailingWidth - 8 - 12, 0)
        // Taban çizgisi hizası: başlığın taban çizgisi y = b.
        let titleFont = titleLabel.font
        let b = TextMetrics.baseline(for: titleFont)
        var frames: [NSView: CGRect] = [:]
        frames[titleLabel] = CGRect(x: 0, y: 0, width: min(pixelCeil(titleLabel.exactWidth), textWidth), height: 16)
        let detailHeight = detailLabel.height(forWidth: textWidth)
        frames[detailLabel] = CGRect(x: 0, y: 16 + 2, width: textWidth, height: detailHeight)
        var x = width
        for (view, size) in trailing.reversed() {
            x -= size.width
            let top: CGFloat
            switch view {
            case let label as IconLabelView:
                top = b - (label.text.frame.minY + TextMetrics.baseline(for: label.text.font))
            case let label as TextLabel:
                top = b - TextMetrics.baseline(for: label.font)
            default:
                top = -1 // SwiftUI: düğme kutusu başlığın 1 pt üstünden başlar (ölçüldü)
            }
            frames[view] = CGRect(x: x, y: top, width: size.width, height: size.height)
            x -= 12
        }
        let minY = frames.values.map(\.minY).min() ?? 0
        let maxY = frames.values.map(\.maxY).max() ?? 0
        for (view, frame) in frames { frames[view] = frame.offsetBy(dx: 0, dy: -minY) }
        return (frames, maxY - minY)
    }

    override func preferredHeight(width: CGFloat) -> CGFloat { 20 + arrange(width: width).height }

    override func layout() {
        super.layout()
        status?.layoutSubtreeIfNeeded()
        for (view, frame) in arrange(width: contentWidth).frames {
            let rect = frame.offsetBy(dx: 10, dy: 10)
            if let control = view as? MaintenanceButton {
                // Çizim: NSButton hizalama kutusu (20 pt) SwiftUI kutusunun (22 pt) üst kenarında (zemin ve metin aynı yerde; ölçüldü).
                control.setAlignmentFrame(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - 2))
            }
            else if let label = view as? TextLabel { label.setFrameRedrawing(rect) }
            else { view.frame = rect }
        }
    }

    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        let union = CGRect(x: 10, y: 10, width: contentWidth, height: bounds.height - 20)
        return window.convertToScreen(convert(union, to: nil))
    }
}

/// Satırın içinde serbest görünüm (önizleme): satır 10 pt içeriden, görünümün yüksekliği kadar.
@MainActor
final class SettingsViewRow: SettingsRow {
    let content: NSView
    private let height: () -> CGFloat

    init(_ content: NSView, height: @escaping () -> CGFloat) {
        self.content = content
        self.height = height
        super.init(frame: .zero)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func preferredHeight(width: CGFloat) -> CGFloat { 20 + height() }

    override func refresh() { (content as? IslandPreviewView)?.refresh() }

    override func layout() {
        super.layout()
        content.frame = CGRect(x: 10, y: 10, width: contentWidth, height: height())
    }
}
