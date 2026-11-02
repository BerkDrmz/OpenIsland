import AppKit

/// Ayarlar sayfası (macOS Sistem Ayarları düzeninde): pencere zemini üzerinde sayfa başlığı ve açıklaması, ardından
/// gruplu kartlar. Bölüm: başlık (13 pt kalın) + 8 pt + kart (10 pt sürekli köşe, dolgu, 0,5 pt kenarlık) + 8 pt +
/// açıklama (11 pt, ikincil, sola hizalı). Satırlar kartın 14 pt içinde; solda renkli simge kutucuğu, aralarında ayırıcı.
@MainActor
final class SettingsFormView: FlippedView {
    static let margin: CGFloat = 28
    let scroll = SettingsScrollView()
    private let document = FlippedView()
    private let background = SettingsFormBackground()
    private let titleLabel: TextLabel?
    private let subtitleLabel: TextLabel?
    private(set) var sections: [SettingsSection] = []
    private var generation = 0
    private let onRefresh: (() -> Void)?

    init(title: String? = nil, subtitle: String? = nil, sections: [SettingsSection], onRefresh: (() -> Void)? = nil) {
        self.sections = sections
        self.onRefresh = onRefresh
        titleLabel = title.map {
            let label = TextLabel($0, font: .systemFont(ofSize: 22, weight: .bold), color: .labelColor)
            label.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
            return label
        }
        subtitleLabel = subtitle.map {
            let label = TextLabel($0, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            label.maximumLines = 0
            label.lineBreakStrategy = .standard
            return label
        }
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        [titleLabel, subtitleLabel].compactMap { $0 }.forEach(document.addSubview)
        for section in sections {
            if let header = section.header { document.addSubview(header) }
            document.addSubview(section.box)
            if let footer = section.footer { document.addSubview(footer) }
        }
        addSubview(background)
        addSubview(scroll)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        if let title { setAccessibilityLabel(title) }
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
        let width = bounds.width
        let inner = width - 2 * Self.margin
        var y: CGFloat = 24
        if let titleLabel {
            titleLabel.frame = CGRect(x: Self.margin, y: y, width: min(pixelCeil(titleLabel.exactWidth), inner), height: titleLabel.lineHeight)
            y += titleLabel.lineHeight + 4
        }
        if let subtitleLabel {
            let height = subtitleLabel.height(forWidth: inner)
            subtitleLabel.setFrameRedrawing(CGRect(x: Self.margin, y: y, width: inner, height: height))
            y += height
        }
        if titleLabel != nil || subtitleLabel != nil { y += 20 }
        for section in sections where !section.isHidden {
            y = section.layout(at: y, x: Self.margin, width: inner) + 24
        }
        let height = max(y - 24 + 28, scroll.contentSize.height)
        document.frame = CGRect(x: 0, y: 0, width: width, height: height)
    }
}

/// Kaydırma alanı: kırpma görünümü tam genişlikte, kaydırma çubuğu içeriğin üstünde.
final class SettingsScrollView: NSScrollView {
    override func tile() {
        super.tile()
        contentView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
    }
}

/// Sayfa zemini: pencere zemini malzemesi (pencere içi karışım, hep etkin).
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

/// Bölüm: isteğe bağlı başlık ve açıklama (açıklama metni dinamik olabilir), satırları taşıyan kart.
@MainActor
final class SettingsSection {
    let header: TextLabel?
    let box: SettingsBoxView
    let footer: TextLabel?
    private let footerText: (() -> String)?
    var isHidden = false

    init(header: String? = nil, rows: [SettingsRow], footer: String? = nil, dynamicFooter: (() -> String)? = nil) {
        if let header {
            let label = TextLabel(header, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
            label.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
            self.header = label
        } else {
            self.header = nil
        }
        box = SettingsBoxView(rows: rows)
        footerText = dynamicFooter
        if footer != nil || dynamicFooter != nil {
            let label = TextLabel(footer ?? "", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
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
    func layout(at top: CGFloat, x: CGFloat, width: CGFloat) -> CGFloat {
        var y = top
        if let header {
            header.frame = CGRect(x: x + 4, y: y, width: min(pixelCeil(header.exactWidth), width - 8), height: 16)
            y += 16 + 8
        }
        let boxHeight = box.preferredHeight(width: width)
        box.frame = CGRect(x: x, y: y, width: width, height: boxHeight)
        y += boxHeight
        if let footer {
            let height = footer.height(forWidth: width - 8)
            footer.setFrameRedrawing(CGRect(x: x + 4, y: y + 8, width: width - 8, height: height))
            y += 8 + height
        }
        return y
    }
}

/// Kart: dolgu ve kenarlık (10 pt sürekli köşe, 0,5 pt), satırlar arasında ayırıcı (satırın yazı başlangıcından).
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
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        border.cornerRadius = 10
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
        return visible.reduce(0) { $0 + $1.preferredHeight(width: width - 2 * SettingsRow.padding) }
    }

    nonisolated override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.isDarkForm
        layer?.backgroundColor = dark ? CGColor(gray: 1, alpha: 0.055) : CGColor(gray: 1, alpha: 0.92)
        border.borderColor = dark ? CGColor(gray: 1, alpha: 0.09) : CGColor(gray: 0, alpha: 0.08)
        let separator = dark ? CGColor(gray: 1, alpha: 0.07) : CGColor(gray: 0, alpha: 0.07)
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
        let scale = window?.backingScaleFactor ?? 2
        for (index, row) in visible.enumerated() {
            let height = row.preferredHeight(width: bounds.width - 2 * SettingsRow.padding)
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
            if index < visible.count - 1 {
                let next = visible[index + 1]
                separators[index].isHidden = false
                let x = min(row.separatorInset, next.separatorInset)
                separators[index].frame = CGRect(x: x, y: y - 1 / scale, width: bounds.width - x, height: 1 / scale)
            }
        }
        for index in max(visible.count - 1, 0)..<separators.count { separators[index].isHidden = true }
        CATransaction.commit()
    }
}

/// Sistem Ayarları'ndaki gibi renkli simge kutucuğu: 24 pt yuvarlak köşeli kare, renk geçişli dolgu, beyaz sembol.
@MainActor
final class SettingsIconTile: NSView {
    static let size: CGFloat = 24
    private let gradient = CAGradientLayer()
    private let image = NSImageView()

    init(symbol name: String, tint: NSColor) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        let rgb = tint.usingColorSpace(.sRGB) ?? tint
        let lighter = rgb.blended(withFraction: 0.25, of: .white) ?? rgb
        gradient.colors = [lighter.cgColor, rgb.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(gradient)
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        image.image = symbol?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        image.contentTintColor = .white
        image.imageScaling = .scaleNone
        image.setAccessibilityElement(false)
        addSubview(image)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        image.frame = bounds
    }
}

/// Satır tabanı: içerik kartın 14 pt içinde (`contentWidth` = kart − 28); isteğe bağlı simge kutucuğu ve başlık altı
/// açıklaması (11 pt, ikincil, satır sarar).
@MainActor
class SettingsRow: FlippedView {
    static let padding: CGFloat = 14
    static let minimumHeight: CGFloat = 44
    private(set) var tile: SettingsIconTile?
    private(set) var detail: TextLabel?

    func preferredHeight(width: CGFloat) -> CGFloat { Self.minimumHeight }
    func refresh() {}
    var contentWidth: CGFloat { bounds.width - 2 * Self.padding }
    /// Başlığın başladığı x (simge varsa onun sağı).
    var leading: CGFloat { tile == nil ? Self.padding : Self.padding + SettingsIconTile.size + 10 }
    /// Ayırıcı yazının başından başlar (Sistem Ayarları gibi).
    var separatorInset: CGFloat { leading }

    func setIcon(_ symbol: String?, tint: NSColor) {
        guard let symbol else { return }
        let tile = SettingsIconTile(symbol: symbol, tint: tint)
        self.tile = tile
        addSubview(tile)
    }

    func setDetail(_ text: String?) {
        guard let text else { return }
        let label = TextLabel(text, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        label.maximumLines = 0
        label.lineBreakStrategy = .standard
        label.setAccessibilityElement(false)
        detail = label
        addSubview(label)
    }

    /// Başlık + açıklama bloğunun yüksekliği (açıklama yoksa 16).
    func textBlockHeight(textWidth: CGFloat) -> CGFloat {
        guard let detail else { return 16 }
        return 16 + 2 + detail.height(forWidth: textWidth)
    }

    /// Başlık ve açıklamayı dikeyde ortalı yerleştirir; simgeyi başlığın ortasına hizalar. Başlık çerçevesini döndürür.
    @discardableResult
    func placeText(_ title: TextLabel, textWidth: CGFloat) -> CGRect {
        let block = textBlockHeight(textWidth: textWidth)
        let top = pixelRound((bounds.height - block) / 2)
        let titleFrame = CGRect(x: leading, y: top, width: min(pixelCeil(title.exactWidth), textWidth), height: 16)
        title.frame = titleFrame
        if let detail {
            detail.setFrameRedrawing(CGRect(x: leading, y: top + 18, width: textWidth, height: detail.height(forWidth: textWidth)))
        }
        if let tile {
            let y = detail == nil ? (bounds.height - SettingsIconTile.size) / 2 : top + 8 - SettingsIconTile.size / 2
            tile.frame = CGRect(x: Self.padding, y: pixelRound(max(y, 10)), width: SettingsIconTile.size, height: SettingsIconTile.size)
        }
        return titleFrame
    }

    /// Denetimin sağında bıraktığı genişliğe göre satır yüksekliği.
    func heightFor(controlWidth: CGFloat, width: CGFloat) -> CGFloat {
        let textWidth = max(width - (leading - Self.padding) - controlWidth - 12, 40)
        return max(Self.minimumHeight, textBlockHeight(textWidth: textWidth) + 22)
    }
}

/// `Toggle(başlık, isOn:)`: solda (simge) başlık ve açıklama, sağda küçük anahtar.
@MainActor
final class SettingsToggleRow: SettingsRow {
    private let title: TextLabel
    private let toggle = SettingsSwitch()
    private let get: () -> Bool
    private let set: (Bool) -> Void
    private let enabled: (() -> Bool)?
    private static let switchSize = CGSize(width: 28, height: 16)

    init(_ title: String, symbol: String? = nil, tint: NSColor = .systemGray, detail: String? = nil,
         get: @escaping () -> Bool, set: @escaping (Bool) -> Void, enabled: (() -> Bool)? = nil) {
        self.title = TextLabel(title, font: .systemFont(ofSize: 13), color: .labelColor)
        self.get = get
        self.set = set
        self.enabled = enabled
        super.init(frame: .zero)
        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = #selector(changed)
        toggle.setAccessibilityLabel(title)
        if let detail { toggle.setAccessibilityHelp(detail) }
        addSubview(self.title)
        addSubview(toggle)
        setIcon(symbol, tint: tint)
        setDetail(detail)
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

    override func preferredHeight(width: CGFloat) -> CGFloat { heightFor(controlWidth: Self.switchSize.width, width: width) }

    override func layout() {
        super.layout()
        let right = bounds.width - Self.padding
        let textWidth = max(right - Self.switchSize.width - 12 - leading, 40)
        let titleFrame = placeText(title, textWidth: textWidth)
        toggle.frame = CGRect(x: right - Self.switchSize.width, y: pixelRound(titleFrame.midY - Self.switchSize.height / 2),
                              width: Self.switchSize.width, height: Self.switchSize.height)
    }
}

/// `Picker(.segmented)`: solda (simge) başlık, sağda parçalı denetim (içeriğin en çok yarısı).
@MainActor
final class SettingsSegmentedRow: SettingsRow {
    private let title: TextLabel
    private let control: NSSegmentedControl
    private let get: () -> Int
    private let set: (Int) -> Void

    init(_ title: String, symbol: String? = nil, tint: NSColor = .systemGray, items: [String],
         get: @escaping () -> Int, set: @escaping (Int) -> Void) {
        self.title = TextLabel(title, font: .systemFont(ofSize: 13), color: .labelColor)
        control = SettingsSegmentedControl(labels: items, trackingMode: .selectOne, target: nil, action: nil)
        self.get = get
        self.set = set
        super.init(frame: .zero)
        control.segmentDistribution = .fillEqually
        control.target = self
        control.action = #selector(changed)
        control.setAccessibilityLabel(title)
        addSubview(self.title)
        addSubview(control)
        setIcon(symbol, tint: tint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    @objc private func changed() { set(control.selectedSegment) }

    private func controlWidth(_ width: CGFloat) -> CGFloat {
        pixelRound(min(max(width * 0.5, CGFloat(control.segmentCount) * 64), width - 140))
    }

    override func preferredHeight(width: CGFloat) -> CGFloat { Self.minimumHeight }

    override func refresh() {
        let index = get()
        if control.selectedSegment != index { control.selectedSegment = index }
    }

    override func layout() {
        super.layout()
        let width = controlWidth(contentWidth)
        let right = bounds.width - Self.padding
        placeText(title, textWidth: max(right - width - 12 - leading, 40))
        control.frame = CGRect(x: right - width - 2, y: pixelRound((bounds.height - 24) / 2), width: width + 4, height: 24)
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

/// Parçalı seçici: AX çerçevesi denetimin hizalama kutusu (çerçevenin 2 pt yanlardan, 1 pt üst/alttan içi).
final class SettingsSegmentedControl: NSSegmentedControl {
    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(bounds.insetBy(dx: 2, dy: 1), to: nil))
    }
}

/// `Picker` (açılır menü): solda (simge) başlık, sağda seçili öğenin genişliğinde menü.
@MainActor
final class SettingsPopUpRow: SettingsRow {
    private let title: TextLabel
    private let popup = MaintenancePopUpButton(frame: .zero, pullsDown: false)
    private let get: () -> Int
    private let set: (Int) -> Void

    init(_ title: String, symbol: String? = nil, tint: NSColor = .systemGray, items: [String],
         get: @escaping () -> Int, set: @escaping (Int) -> Void) {
        self.title = TextLabel(title, font: .systemFont(ofSize: 13), color: .labelColor)
        self.get = get
        self.set = set
        super.init(frame: .zero)
        popup.addItems(withTitles: items)
        popup.target = self
        popup.action = #selector(changed)
        popup.setAccessibilityLabel(title)
        addSubview(self.title)
        addSubview(popup)
        setIcon(symbol, tint: tint)
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

    /// Menü seçili öğenin genişliğindedir (en uzun öğeninkinde değil).
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
        let right = bounds.width - Self.padding
        placeText(title, textWidth: max(right - s.width - 12 - leading, 40))
        popup.setAlignmentFrame(CGRect(x: right - s.width, y: pixelRound((bounds.height - s.height) / 2), width: s.width, height: s.height))
    }
}

/// Satır içi açıklama (ikincil, 11 pt): satır yazısının hizasında; içerik yoksa gizlenir.
@MainActor
final class SettingsCaptionRow: SettingsRow {
    private let text: TextLabel
    private let source: () -> String?

    init(_ source: @escaping () -> String?) {
        text = TextLabel("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
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
        text.setFrameRedrawing(CGRect(x: Self.padding, y: 10 + (max(16, height) - height) / 2, width: contentWidth, height: height))
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
        button.setAlignmentFrame(CGRect(x: Self.padding, y: pixelRound((bounds.height - s.height) / 2), width: s.width, height: s.height))
    }
}

/// İzin ve Space satırı: (simge) başlık + açıklama, sağda durum etiketi (simge + metin) ve [düğme | "İzin bekleniyor…"];
/// AX'te tek öğe.
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
    private let detailLabel = TextLabel("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    private var status: IconLabelView?
    private let waitingLabel = TextLabel("İzin bekleniyor…", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let button = MaintenanceButton(title: "", symbol: nil)
    private let source: () -> Content
    private let perform: (() -> Void)?
    private var content: Content?

    init(symbol: String? = nil, tint: NSColor = .systemGray, source: @escaping () -> Content, perform: (() -> Void)? = nil) {
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
        setIcon(symbol, tint: tint)
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
            let label = IconLabelView(new.status, symbol: new.symbol, font: .systemFont(ofSize: 11, weight: .medium),
                                      color: new.positive ? .systemGreen : .secondaryLabelColor)
            label.setAccessibilityElement(false)
            label.spacing = 5
            label.snapsIconToWindow = true
            addSubview(label)
            status = label
        }
        button.isHidden = new.waiting || new.action == nil
        if let action = new.action { button.setTitle(action) }
        waitingLabel.isHidden = !new.waiting
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

    /// Sağdaki öğelerin (durum, bekleme, düğme) boyutları ve toplam genişliği.
    private var trailing: [(NSView, CGSize)] {
        var items: [(NSView, CGSize)] = []
        if let status { items.append((status, status.fittingSize)) }
        if !waitingLabel.isHidden { items.append((waitingLabel, CGSize(width: pixelCeil(waitingLabel.exactWidth), height: 14))) }
        if !button.isHidden { items.append((button, button.alignmentSize)) }
        return items
    }

    private func textWidth(_ width: CGFloat) -> CGFloat {
        let trailingWidth = trailing.reduce(0) { $0 + $1.1.width + 10 }
        return max(width - (leading - Self.padding) - trailingWidth - 8, 60)
    }

    override func preferredHeight(width: CGFloat) -> CGFloat {
        let text = textWidth(width)
        return max(Self.minimumHeight, 16 + 2 + detailLabel.height(forWidth: text) + 22)
    }

    override func layout() {
        super.layout()
        status?.layoutSubtreeIfNeeded()
        let text = textWidth(contentWidth)
        let detailHeight = detailLabel.height(forWidth: text)
        let top = pixelRound((bounds.height - (18 + detailHeight)) / 2)
        titleLabel.frame = CGRect(x: leading, y: top, width: min(pixelCeil(titleLabel.exactWidth), text), height: 16)
        detailLabel.setFrameRedrawing(CGRect(x: leading, y: top + 18, width: text, height: detailHeight))
        if let tile { tile.frame = CGRect(x: Self.padding, y: pixelRound(top + 8 - SettingsIconTile.size / 2), width: SettingsIconTile.size, height: SettingsIconTile.size) }
        var x = bounds.width - Self.padding
        let midY = top + 8
        for (view, size) in trailing.reversed() {
            x -= size.width
            let rect = CGRect(x: x, y: pixelRound(midY - size.height / 2), width: size.width, height: size.height)
            if let control = view as? MaintenanceButton { control.setAlignmentFrame(rect) }
            else if let label = view as? TextLabel { label.setFrameRedrawing(rect) }
            else { view.frame = rect }
            x -= 10
        }
    }

    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        let union = CGRect(x: Self.padding, y: 8, width: contentWidth, height: bounds.height - 16)
        return window.convertToScreen(convert(union, to: nil))
    }
}

/// Satırın içinde serbest görünüm (önizleme). `fullBleed`: kartı kenardan kenara doldurur (kart köşeleriyle kırpılır).
@MainActor
final class SettingsViewRow: SettingsRow {
    let content: NSView
    private let height: () -> CGFloat
    private let fullBleed: Bool

    init(_ content: NSView, fullBleed: Bool = false, height: @escaping () -> CGFloat) {
        self.content = content
        self.height = height
        self.fullBleed = fullBleed
        super.init(frame: .zero)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func preferredHeight(width: CGFloat) -> CGFloat { (fullBleed ? 0 : 20) + height() }

    override func refresh() { (content as? IslandPreviewView)?.refresh() }

    override func layout() {
        super.layout()
        content.frame = fullBleed ? bounds : CGRect(x: Self.padding, y: 10, width: contentWidth, height: height())
    }
}
