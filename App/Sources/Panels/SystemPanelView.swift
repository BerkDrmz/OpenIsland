import AppKit
import IslandCore

/// Sistem sekmesi (SwiftUI `SystemPanel`): sıcaklıklar · kullanım · ekran ve klavye ışığı · depolama. Sekme görünürken
/// ölçer (`panelDidAppear`), gizlenince durur. Değerler yalnız değişen etiketi yeniden çizer.
@MainActor
final class SystemPanelView: FlippedView, IslandPanel {
    /// SwiftUI `SystemPanel`: sıcaklık, donanım ve ekran sütunları sırayla (`PanelAXOrder.first/second/third`), sonra depolama.
    func axNavigationRank(of view: NSView) -> Int? {
        if view.isDescendant(of: temperature) { return 3 }
        if view.isDescendant(of: usage) { return 2 }
        if view.isDescendant(of: controls) { return 1 }
        return 0
    }
    private let system: SystemMonitor
    private let temperature: TemperatureColumnView
    private let usage: UsageColumnView
    private let controls: ControlsColumnView
    private let storage: StorageSectionView
    private let separators = [SeparatorView(), SeparatorView(), SeparatorView()]
    private lazy var observer = Observer(track: { [system] in
        _ = system.temperatures; _ = system.uptime; _ = system.cpu; _ = system.gpu; _ = system.memory
        _ = system.pressure; _ = system.brightness; _ = system.keyboardBacklight; _ = system.storage
    }, apply: { [weak self] in self?.update() })

    init(system: SystemMonitor) {
        self.system = system
        temperature = TemperatureColumnView()
        usage = UsageColumnView()
        controls = ControlsColumnView(system: system)
        storage = StorageSectionView(system: system)
        super.init(frame: .zero)
        [temperature, usage, controls, storage].forEach(addSubview)
        separators.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    /// Uyku hâlindeki ön kurulum: son ölçülen değerlerle etiketler doldurulur (örnekleme başlamaz).
    func prewarm() { update() }

    func didShow() {
        system.panelDidAppear()
        observer.start()
    }

    func didHide() {
        observer.stop()
        system.panelDidDisappear()
    }

    private func update() {
        temperature.update(system)
        usage.update(system)
        controls.update(system)
        storage.update(system)
    }

    override func layout() {
        super.layout()
        let widths = IslandLayoutEngine.System.columnWidths
        let h = IslandLayoutEngine.System.columnHeight
        let gap = IslandLayoutEngine.columnGap
        var x: CGFloat = 0
        temperature.frame = CGRect(x: x, y: 0, width: widths[0], height: h)
        x += widths[0] + gap
        separators[0].frame = pixelRect(CGRect(x: x, y: 0, width: 0.5, height: h))
        x += 0.5 + gap
        usage.frame = CGRect(x: x, y: 0, width: widths[1], height: h)
        x += widths[1] + gap
        separators[1].frame = pixelRect(CGRect(x: x, y: 0, width: 0.5, height: h))
        x += 0.5 + gap
        controls.frame = CGRect(x: x, y: 0, width: widths[2], height: h)
        let sectionGap = IslandLayoutEngine.System.sectionGap
        separators[2].frame = pixelRect(CGRect(x: 0, y: h + sectionGap, width: bounds.width, height: 0.5))
        storage.frame = CGRect(x: 0, y: h + 2 * sectionGap + 0.5, width: bounds.width, height: IslandLayoutEngine.System.storageHeight)
    }

    /// SwiftUI `.frame(height: 12)`: 13 pt'lik metin satırı 12 pt'lik kutuda dikeyde ortalanır (üstten −0,5 pt).
    static func sectionLabelFrame(_ label: TextLabel, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: (12 - label.lineHeight) / 2, width: width, height: label.lineHeight)
    }

    static func sectionLabel(_ text: String) -> TextLabel {
        TextLabel(text, font: Fonts.sectionLabel, color: Palette.tertiary)
    }
}

// MARK: - Sıcaklık

private final class TemperatureColumnView: FlippedView {
    private let header = SystemPanelView.sectionLabel("SICAKLIK")
    private let cpu = TemperatureTile(title: "CPU")
    private let gpu = TemperatureTile(title: "GPU")
    private let clock = SymbolView("clock", size: 9, color: Palette.secondary)
    private let uptime = TextLabel("", font: Fonts.caption2, color: Palette.secondary)

    override init(frame: NSRect) {
        super.init(frame: frame)
        uptime.minimumScaleFactor = 0.8
        [header, cpu, gpu, clock, uptime].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func update(_ system: SystemMonitor) {
        cpu.set(system.temperatures?.cpu)
        gpu.set(system.temperatures?.gpu)
        uptime.set("Çalışma süresi \(Self.uptimeText(system.uptime))")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        header.frame = SystemPanelView.sectionLabelFrame(header, width: bounds.width)
        let tileH = cpu.preferredHeight
        let tileW = (bounds.width - 8) / 2
        cpu.frame = CGRect(x: 0, y: 12 + 6, width: tileW, height: tileH)
        gpu.frame = CGRect(x: tileW + 8, y: 12 + 6, width: tileW, height: tileH)
        let lh = uptime.lineHeight
        let s = clock.layoutSize
        let y = bounds.height - lh
        clock.frame = clock.drawingFrame(layoutOrigin: CGPoint(x: 0, y: y + (lh - s.height) / 2))
        uptime.frame = CGRect(x: s.width + 4, y: y, width: bounds.width - s.width - 4, height: lh)
    }

    static func uptimeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400, hours = total % 86_400 / 3_600, minutes = total % 3_600 / 60
        if days > 0 { return "\(days)g \(hours)s" }
        return hours > 0 ? "\(hours)s \(minutes)dk" : "\(minutes)dk"
    }
}

private final class TemperatureTile: RoundedView {
    private let title: TextLabel
    private let value = TextLabel("—", font: Fonts.numericLarge)
    private let name: String

    init(title text: String) {
        name = text
        title = TextLabel(text, font: Fonts.caption2, color: Palette.secondary)
        super.init(radius: 8, fill: Palette.fill)
        [title, value].forEach(addSubview)
        title.setAccessibilityElement(false)
        value.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.unknown)
        setAccessibilityLabel("\(text) sensör grubu, son okumadaki en yüksek sıcaklık")
        let help = "\(text) için eşleşen sensörlerin son okumadaki en yüksek değeri. Ortalama değildir. Yaklaşık 2 saniyede yenilenir; güç tasarrufunda 4 saniye. Sensör gruplaması macOS tarafından belgelenmemiştir."
        toolTip = help
        setAccessibilityHelp(help)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    var preferredHeight: CGFloat { title.lineHeight + 1 + value.lineHeight + 6 }

    func set(_ celsius: Double?) {
        value.set(celsius.map { "\(Int($0.rounded()))°" } ?? "—")
        setAccessibilityValue(celsius.map { "\(Int($0.rounded())) derece" } ?? "okunamıyor")
    }

    override func layout() {
        super.layout()
        title.frame = CGRect(x: 8, y: 3, width: bounds.width - 16, height: title.lineHeight)
        value.frame = CGRect(x: 8, y: 3 + title.lineHeight + 1, width: bounds.width - 16, height: value.lineHeight)
    }
}

// MARK: - Kullanım

private final class UsageColumnView: FlippedView {
    private let header = SystemPanelView.sectionLabel("DONANIM")
    private let cpu = UsageRow(title: "CPU")
    private let gpu = UsageRow(title: "GPU")
    private let memory = UsageRow(title: "Bellek")
    private let detail = TextLabel("", font: Fonts.caption2, color: Palette.tertiary)

    override init(frame: NSRect) {
        super.init(frame: frame)
        detail.minimumScaleFactor = 0.8
        [header, cpu, gpu, memory, detail].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func update(_ system: SystemMonitor) {
        cpu.set(fraction: system.cpu, text: system.cpu.map(Self.percent) ?? "—")
        gpu.set(fraction: system.gpu, text: system.gpu.map(Self.percent) ?? "—")
        if let m = system.memory {
            let tint: NSColor? = switch system.pressure {
            case .normal: nil
            case .warning: .systemYellow
            case .critical: .systemRed
            }
            let pressure = switch system.pressure { case .normal: "Normal"; case .warning: "Yüksek"; case .critical: "Kritik" }
            memory.set(fraction: m.usedFraction, text: "\(Self.gigabytes.string(fromByteCount: Int64(m.usedBytes))) / \(Self.bytes(m.totalBytes))", tint: tint)
            memory.toolTip = "Mac'in toplam RAM kullanımıdır; OpenIsland'in kendi kullanımı değildir. Bellek basıncı: \(pressure)."
            memory.setAccessibilityHelp("Mac'in toplam RAM kullanımı. Bellek basıncı: \(pressure).")
            // ByteCountFormatter sıfırı "Sıfır KB" yazıyor.
            let swap = m.swapUsedBytes == 0 ? "Takas yok" : "Takas \(Self.bytes(m.swapUsedBytes))"
            let text = "Sıkıştırılmış \(Self.bytes(m.compressedBytes)) · \(swap)"
            if detail.stringValue != text || detail.isHidden {
                detail.set(text)
                detail.isHidden = false
                needsLayout = true // genişlik metne bağlı
            }
        } else {
            memory.set(fraction: nil, text: "—")
            memory.toolTip = nil
            memory.setAccessibilityHelp(nil)
            detail.isHidden = true
        }
    }

    override func layout() {
        super.layout()
        header.frame = SystemPanelView.sectionLabelFrame(header, width: bounds.width)
        var y: CGFloat = 12 + 6
        for row in [cpu, gpu, memory] {
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: 18)
            y += 18 + 6
        }
        // SwiftUI VStack(spacing: 6) { başlık 12, 3 × satır 18, ayrıntı, Spacer }: kalan yükseklik ayrıntı ile Spacer
        // arasında paylaşılır; ayrıntıya düşen pay satır yüksekliğinden azsa metin en küçük oranda (0,8) çizilir.
        let remaining = bounds.height - (12 + 3 * 18) - 5 * 6
        let full = TextMetrics.lineHeight(for: Fonts.caption2)
        let shrinks = remaining / 2 < full
        detail.font = shrinks ? NSFont.systemFont(ofSize: 10 * 0.8, weight: .medium) : Fonts.caption2
        let w = min(detail.naturalWidth, bounds.width)
        detail.frame = CGRect(x: 0, y: y, width: w, height: detail.lineHeight)
    }

    private static func percent(_ value: Double) -> String { "%\(Int((value * 100).rounded()))" }

    /// Aynı biçimlendirici yeniden kullanılır (SwiftUI sürümü her değerde yenisini kuruyordu; çıktı aynı).
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useGB, .useMB]
        f.includesUnit = true
        return f
    }()

    static func bytes(_ value: UInt64) -> String { formatter.string(fromByteCount: Int64(value)) }
    /// Bellek satırında birim bir kez yazılır ("12.38 / 16 GB"): 66 pt'lik değer alanına "12.38 GB / 16 GB" sığmıyor,
    /// sondan kesiliyordu.
    private static let gigabytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useGB]
        f.includesUnit = false
        return f
    }()
}

private final class UsageRow: FlippedView {
    private let title: TextLabel
    private let bar = LevelBarView()
    private let value = TextLabel("", font: Fonts.numericSmall, alignment: .right)
    private let name: String

    init(title text: String) {
        name = text
        title = TextLabel(text, font: Fonts.caption, color: Palette.secondary)
        super.init(frame: .zero)
        value.minimumScaleFactor = 0.7
        bar.trackColor = Palette.track
        [title, bar, value].forEach(addSubview)
        [title, value].forEach { $0.setAccessibilityElement(false) }
        setAccessibilityElement(true)
        setAccessibilityRole(.unknown)
        setAccessibilityLabel("\(text) kullanımı")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func set(fraction: Double?, text: String, tint: NSColor? = nil) {
        bar.tint = tint ?? .white
        bar.setLevel(fraction ?? 0, animated: window != nil)
        value.set(text)
        setAccessibilityValue(text)
    }

    /// SwiftUI satırın AX çerçevesini içeriğin birleşimi olarak bildirir (18 pt'lik kutu değil, 14 pt'lik metin satırı).
    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        let h = max(title.lineHeight, value.lineHeight)
        return window.convertToScreen(convert(CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h), to: nil))
    }

    override func layout() {
        super.layout()
        let lh = title.lineHeight
        title.frame = CGRect(x: 0, y: (bounds.height - lh) / 2, width: 38, height: lh)
        value.frame = CGRect(x: bounds.width - 66, y: (bounds.height - value.lineHeight) / 2, width: 66, height: value.lineHeight)
        bar.frame = pixelRect(CGRect(x: 38 + 6, y: (bounds.height - 4) / 2, width: bounds.width - 38 - 66 - 12, height: 4))
    }
}

// MARK: - Ekran

private final class ControlsColumnView: FlippedView {
    private let header = SystemPanelView.sectionLabel("EKRAN")
    private let brightness: SliderRow
    private let keyboard: SliderRow

    init(system: SystemMonitor) {
        brightness = SliderRow(title: "Parlaklık", symbol: "sun.max.fill", system: system) { system.setBrightness($0) }
        keyboard = SliderRow(title: "Klavye ışığı", symbol: "light.max", system: system) { system.setKeyboardBacklight($0) }
        super.init(frame: .zero)
        [header, brightness, keyboard].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func update(_ system: SystemMonitor) {
        brightness.set(value: system.brightness, enabled: system.canAdjustBrightness)
        keyboard.set(value: system.keyboardBacklight, enabled: system.canAdjustKeyboard)
    }

    override func layout() {
        super.layout()
        header.frame = SystemPanelView.sectionLabelFrame(header, width: bounds.width)
        brightness.frame = CGRect(x: 0, y: 18, width: bounds.width, height: 22)
        keyboard.frame = CGRect(x: 0, y: 18 + 22 + 6, width: bounds.width, height: 22)
    }
}

private final class SliderRow: FlippedView {
    private let icon: SymbolView
    private let slider = AlignedSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let unavailable: TextLabel
    private let title: String
    private let set: (Float) -> Void
    private weak var system: SystemMonitor?

    init(title: String, symbol: String, system: SystemMonitor, set: @escaping (Float) -> Void) {
        self.title = title
        self.set = set
        self.system = system
        icon = SymbolView(symbol, size: 11, weight: .semibold, color: Palette.secondary)
        unavailable = TextLabel("\(title): kullanılamıyor", font: Fonts.caption2, color: Palette.tertiary)
        super.init(frame: .zero)
        slider.controlSize = .small
        slider.trackFillColor = .white
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed(_:))
        slider.setAccessibilityLabel(title)
        [icon, slider, unavailable].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func set(value: Float?, enabled: Bool) {
        let available = value != nil && enabled
        slider.isHidden = !available
        unavailable.isHidden = available
        if let value, available, !isTracking {
            slider.doubleValue = Double(value)
            slider.setAccessibilityValueDescription("%\(Int((value * 100).rounded()))")
        }
    }

    private var isTracking = false

    @objc private func changed(_ sender: NSSlider) {
        // Sürükleme dışındaki her değişiklik (bırakma, klavye, VoiceOver) tek adımdır: ölçüm hemen yeniden devralır.
        // Önceden yalnız fare bırakma izlemeyi bitiriyordu; klavyeyle değişiklikten sonra kaydırıcı güncellenmiyordu.
        let type = NSApp.currentEvent?.type
        let dragging = type == .leftMouseDown || type == .leftMouseDragged
        if !isTracking { isTracking = true; system?.setAdjusting(true) }
        set(Float(sender.doubleValue))
        slider.setAccessibilityValueDescription("%\(Int((sender.doubleValue * 100).rounded()))")
        if !dragging { isTracking = false; system?.setAdjusting(false) }
    }

    override func layout() {
        super.layout()
        icon.frame = icon.drawingFrame(centeredIn: CGRect(x: 0, y: 0, width: 14, height: bounds.height))
        let x: CGFloat = 14 + 8
        // SwiftUI küçük kaydırıcı: hizalama dikdörtgeni 16 pt yüksek, görünüm her yandan 2 pt taşar.
        slider.setAlignmentFrame(CGRect(x: x, y: (bounds.height - 16) / 2, width: bounds.width - x, height: 16))
        unavailable.frame = CGRect(x: x, y: (bounds.height - unavailable.lineHeight) / 2, width: bounds.width - x, height: unavailable.lineHeight)
    }
}

// MARK: - Depolama

private final class StorageSectionView: FlippedView {
    private let system: SystemMonitor
    private let header = SystemPanelView.sectionLabel("DEPOLAMA")
    private let picker = AlignedPopUpButton(frame: .zero, pullsDown: false)
    private var diskLabel = IconLabelView("", symbol: "internaldrive")
    private let refresh: PlainButton
    private let settings: PlainButton
    private let bar = LevelBarView()
    private let usage = TextLabel("", font: Fonts.numericSmall)
    private let free = TextLabel("", font: Fonts.numericSmall, color: Palette.secondary)
    private let loading = TextLabel("Depolama bilgisi okunuyor veya disk kullanılamıyor.", font: Fonts.caption2, color: Palette.secondary)
    private let usageGroup = ContentFramedView()
    private var selectedID = "/"
    private var volumes: [StorageVolume] = []

    init(system: SystemMonitor) {
        self.system = system
        refresh = PlainButton { system.refreshStorage() }
        settings = PlainButton {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Storage-Settings.extension") { NSWorkspace.shared.open(url) }
        }
        super.init(frame: .zero)
        // SwiftUI: `.buttonStyle(.plain)` içindeki menü seçici kenarlıksız ve okuysuz çizilir (çalışma anında okundu).
        picker.controlSize = .mini
        picker.font = NSFont.systemFont(ofSize: 9)
        picker.isBordered = false
        (picker.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        picker.target = self
        picker.action = #selector(pick(_:))
        picker.toolTip = "Dahili veya harici disk seç"
        picker.setAccessibilityLabel("Disk")
        picker.setAccessibilityHelp("Dahili veya harici disk seç")
        for (button, symbol, label) in [(refresh, "arrow.clockwise", "Depolama bilgisini yenile"),
                                        (settings, "arrow.up.forward.square", "macOS Depolama ayarlarını aç")] {
            let icon = SymbolView(symbol, size: 11, color: Palette.primary)
            button.addSubview(icon)
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.setAccessibilityHelp(label)
        }
        bar.trackColor = Palette.track
        [bar, usage, free].forEach(usageGroup.addSubview)
        [usage, free].forEach { $0.setAccessibilityElement(false) }
        usageGroup.setAccessibilityElement(true)
        usageGroup.setAccessibilityRole(.unknown)
        usageGroup.contentHeight = TextMetrics.lineHeight(for: Fonts.numericSmall)
        [header, picker, diskLabel, refresh, settings, usageGroup, loading].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    private var selected: StorageVolume? { volumes.first { $0.id == selectedID } ?? volumes.first }

    func update(_ system: SystemMonitor) {
        if system.storage != volumes {
            volumes = system.storage
            if !volumes.contains(where: { $0.id == selectedID }) { selectedID = volumes.first?.id ?? "/" }
            picker.removeAllItems()
            for v in volumes { picker.addItem(withTitle: v.name); picker.lastItem?.representedObject = v.id }
        }
        let volume = selected
        let multiple = volumes.count > 1
        picker.isHidden = volume == nil || !multiple
        diskLabel.isHidden = volume == nil || multiple
        usageGroup.isHidden = volume == nil
        loading.isHidden = volume != nil
        if let volume {
            if let index = volumes.firstIndex(where: { $0.id == volume.id }) { picker.selectItem(at: index) }
            let symbol = volume.isInternal ? "internaldrive" : "externaldrive"
            if diskLabel.text.stringValue != volume.name || diskLabel.symbolName != symbol {
                let label = IconLabelView(volume.name, symbol: symbol)
                label.isHidden = diskLabel.isHidden
                replaceSubview(diskLabel, with: label)
                diskLabel = label
            }
            bar.setLevel(volume.usedFraction, animated: false)
            usage.set("\(Self.bytes(volume.used)) / \(Self.bytes(volume.total))")
            free.set("\(Self.bytes(volume.available)) boş")
            usageGroup.setAccessibilityLabel("\(volume.name) depolama alanı")
            usageGroup.setAccessibilityValue("\(Self.bytes(volume.used)) kullanılıyor, \(Self.bytes(volume.available)) boş, \(Self.bytes(volume.total)) toplam")
        }
        needsLayout = true
    }

    @objc private func pick(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        selectedID = id
        update(system)
    }

    override func layout() {
        super.layout()
        let rowH: CGFloat = 18
        let hw = pixelCeil(header.exactWidth)
        header.frame = CGRect(x: 0, y: (rowH - header.lineHeight) / 2, width: hw, height: header.lineHeight)
        var x = hw + 8
        if !picker.isHidden {
            // Esnek genişlik: `.frame(maxWidth: 145)` önerisini alır.
            let h = picker.intrinsicContentSize.height
            picker.setAlignmentFrame(CGRect(x: x, y: (rowH - h) / 2, width: 145, height: h))
        } else {
            let s = diskLabel.fittingSize
            diskLabel.frame = CGRect(x: x, y: (rowH - s.height) / 2, width: s.width, height: s.height)
        }
        // Sağda iki düğme (SwiftUI düz düğmeleri: simge boyutu kadar, aralarında 8 pt).
        var right = bounds.width
        for button in [settings, refresh] {
            guard let icon = button.subviews.first as? SymbolView else { continue }
            let s = icon.layoutSize
            right -= s.width
            icon.place(asLabelOf: button, layoutOrigin: CGPoint(x: right, y: (rowH - s.height) / 2))
            right -= 8
        }
        _ = x
        x = 0
        let y2 = rowH + 6
        usageGroup.frame = CGRect(x: 0, y: y2, width: bounds.width, height: rowH)
        let fw = pixelCeil(free.exactWidth), uw = pixelCeil(usage.exactWidth)
        free.frame = CGRect(x: bounds.width - fw, y: (rowH - free.lineHeight) / 2, width: fw, height: free.lineHeight)
        usage.frame = CGRect(x: bounds.width - fw - 10 - uw, y: (rowH - usage.lineHeight) / 2, width: uw, height: usage.lineHeight)
        bar.frame = pixelRect(CGRect(x: 0, y: (rowH - 4) / 2, width: max(bounds.width - fw - uw - 20, 0), height: 4))
        loading.frame = CGRect(x: 0, y: y2 + (rowH - loading.lineHeight) / 2, width: bounds.width, height: loading.lineHeight)
    }

    private static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

/// AX çerçevesi SwiftUI gibi içeriğin birleşimi (dikeyde ortalı `contentHeight`), kutunun tamamı değil.
final class ContentFramedView: FlippedView {
    var contentHeight: CGFloat = 0

    override func accessibilityFrame() -> NSRect {
        guard let window, contentHeight > 0 else { return super.accessibilityFrame() }
        let r = CGRect(x: 0, y: (bounds.height - contentHeight) / 2, width: bounds.width, height: contentHeight)
        return window.convertToScreen(convert(r, to: nil))
    }
}
