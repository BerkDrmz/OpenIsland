import AppKit
import CoreAudio
import IslandCore

/// Ses mikseri (SwiftUI `AudioMixerPanel`). Ölçüler, aynı görünümün SwiftUI'de çalışma anında ölçülmesiyle alınmıştır
/// (Deney/README.md → Ölçümler): kaydırıcı ve açılır menüler SwiftUI gibi hizalama dikdörtgeniyle yerleşir, satırlar
/// kalıcıdır ve yalnız değişen değer güncellenir (seviye değişimi satırları yeniden kurmaz).
@MainActor
final class MixerPanelView: FlippedView, IslandPanel {
    private let mixer: AudioMixerController
    private let header = TextLabel("SES MİKSERİ", font: Fonts.sectionLabel, color: Palette.secondary)
    private let routes = TextLabel("", font: Fonts.caption2, color: Palette.secondary, alignment: .right)
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let output: DeviceControlView
    private let system: DeviceControlView
    private let input: DeviceControlView
    private let divider = RoundedView(radius: 0, fill: NSColor(white: 1, alpha: 89.0 / 255)) // Divider + ayırıcı kaplaması
    private let unsupported = TextLabel("Uygulama başına ses kontrolü macOS 14.2 veya üstünü gerektirir.",
                                        font: Fonts.caption, color: .secondaryLabelColor)
    private var rows: [pid_t: ApplicationRowView] = [:]
    private var order: [pid_t] = []
    private let errorLabel = TextLabel("", font: Fonts.caption2, color: .systemOrange)
    private let errorClose = PlainButton()
    private let errorIcon = SymbolView("xmark", size: 13, color: Palette.primary)
    private let settingsButton = PlainButton()
    private let settingsLabel = IconLabelView("Ayarlar", symbol: "gearshape")
    private let quitButton = PlainButton()
    private let quitLabel = IconLabelView("Çık", symbol: "power")
    private lazy var observer = Observer(track: { [mixer] in
        _ = mixer.devices; _ = mixer.applications; _ = mixer.output; _ = mixer.systemOutput; _ = mixer.input
        _ = mixer.outputLevel; _ = mixer.inputLevel; _ = mixer.error; _ = mixer.volumes; _ = mixer.routes; _ = mixer.activeRouteCount
    }, apply: { [weak self] in self?.update() })

    init(mixer: AudioMixerController, settings: @escaping () -> Void) {
        self.mixer = mixer
        output = DeviceControlView(title: "Çıkış", symbol: "speaker.wave.2", mixer: mixer,
                                   selector: kAudioHardwarePropertyDefaultOutputDevice, input: false, hasLevel: true)
        system = DeviceControlView(title: "Sistem sesleri", symbol: "bell", mixer: mixer,
                                   selector: kAudioHardwarePropertyDefaultSystemOutputDevice, input: false, hasLevel: false)
        input = DeviceControlView(title: "Mikrofon", symbol: "mic", mixer: mixer,
                                  selector: kAudioHardwarePropertyDefaultInputDevice, input: true, hasLevel: true)
        super.init(frame: .zero)
        // SwiftUI `ScrollView`: dikey kaydırma çubuğu sistem tercihindeki biçimde, kendiliğinden gizlenir.
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        [output, system, input, divider, unsupported].forEach(document.addSubview)
        unsupported.isHidden = mixer.supportsApplicationMixer
        unsupported.maximumLines = 0
        errorLabel.maximumLines = 0
        errorClose.addSubview(errorIcon)
        errorClose.setAccessibilityLabel("Hata mesajını kapat")
        errorClose.action = { [mixer] in mixer.clearError() }
        settingsButton.addSubview(settingsLabel)
        settingsButton.setAccessibilityLabel("Ayarlar")
        settingsButton.action = settings
        quitButton.addSubview(quitLabel)
        quitButton.setAccessibilityLabel("Çık")
        quitButton.action = { NSApp.terminate(nil) }
        [settingsLabel, quitLabel].forEach { $0.setAccessibilityElement(false) }
        settingsButton.accessibilityFrameSource = settingsLabel
        quitButton.accessibilityFrameSource = quitLabel
        routes.isHidden = true
        [header, routes, scroll, errorLabel, errorClose, settingsButton, quitButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func prewarm() { mixer.prefetch() }
    func didShow() { mixer.showPanel(); observer.start() }
    func didHide() { observer.stop(); mixer.hidePanel() }

    private func update() {
        let count = mixer.activeRouteCount
        routes.isHidden = count == 0
        routes.set(count > 0 ? "\(count) özel ses yolu" : "")
        output.update(id: mixer.output, level: mixer.outputLevel)
        system.update(id: mixer.systemOutput, level: nil)
        input.update(id: mixer.input, level: mixer.inputLevel)
        let ids = mixer.applications.map(\.id)
        for (id, row) in rows where !ids.contains(id) { row.removeFromSuperview(); rows[id] = nil }
        for app in mixer.applications {
            if let row = rows[app.id] { row.update(app) } else {
                let row = ApplicationRowView(app: app, mixer: mixer)
                rows[app.id] = row
                document.addSubview(row)
            }
        }
        order = ids
        errorLabel.isHidden = mixer.error == nil
        errorClose.isHidden = mixer.error == nil
        errorLabel.set(mixer.error ?? "")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        header.frame = CGRect(x: 0, y: 0, width: pixelCeil(header.exactWidth), height: header.lineHeight)
        let rw = pixelCeil(routes.exactWidth)
        routes.frame = CGRect(x: w - rw, y: 0, width: rw, height: routes.lineHeight)
        // Alt satır: iki düz düğme (Label), SwiftUI HStack'te dikeyde ortalı.
        let sSize = settingsLabel.fittingSize, qSize = quitLabel.fittingSize
        let footerH = max(sSize.height, qSize.height)
        let footerY = bounds.height - footerH
        settingsButton.frame = CGRect(x: 0, y: footerY + (footerH - sSize.height) / 2, width: sSize.width, height: sSize.height)
        settingsLabel.frame = settingsButton.bounds
        quitButton.frame = CGRect(x: w - qSize.width, y: footerY + (footerH - qSize.height) / 2, width: qSize.width, height: qSize.height)
        quitLabel.frame = quitButton.bounds
        var bottom = footerY
        if !errorLabel.isHidden {
            let xs = errorIcon.layoutSize
            let ew = w - 8 - xs.width
            let eh = errorLabel.height(forWidth: ew)
            bottom -= 10 + max(eh, xs.height)
            errorLabel.frame = CGRect(x: 0, y: bottom, width: ew, height: eh)
            errorIcon.place(asLabelOf: errorClose, layoutOrigin: CGPoint(x: w - xs.width, y: bottom))
        }
        let top = header.lineHeight + 10
        scroll.frame = pixelRect(CGRect(x: 0, y: top, width: w, height: max(bottom - 10 - top, 0)))
        let viewportWidth = scroll.contentSize.width
        layoutDocument(width: viewportWidth)
        // Showing/hiding a legacy scrollbar can resize the viewport when the
        // document height changes. Resolve that one size transition immediately,
        // without polling, global preference changes, or an extra render loop.
        if scroll.contentSize.width != viewportWidth {
            layoutDocument(width: scroll.contentSize.width)
        }
    }

    private func layoutDocument(width: CGFloat) {
        // İçerik: VStack(spacing: 12) + sağda 3 pt dolgu.
        let cw = max(width - 3, 0)
        var y: CGFloat = 0
        for view in [output, system, input] as [DeviceControlView] {
            view.frame = CGRect(x: 0, y: y, width: cw, height: view.preferredHeight)
            y += view.preferredHeight + 12
        }
        divider.frame = CGRect(x: 0, y: y, width: cw, height: 1)
        y += 1 + 12
        if !unsupported.isHidden {
            let h = unsupported.height(forWidth: cw)
            unsupported.frame = CGRect(x: 0, y: y, width: cw, height: h)
            y += h + 12
        }
        for id in order {
            guard let row = rows[id] else { continue }
            row.frame = CGRect(x: 0, y: y, width: cw, height: row.preferredHeight)
            y += row.preferredHeight + 12
        }
        document.frame = CGRect(x: 0, y: 0, width: width, height: max(y - 12, 0))
    }
}

/// SwiftUI `Label(başlık, systemImage:)` varsayılan biçimi: simge + 8 pt + metin. Simge taban çizgisine hizalanır:
/// yerleşim kutusunun altı, metnin taban çizgisinin `alignmentRect.minY` kadar altındadır. AX'te tek statik metin;
/// çerçevesi simge mürekkebi ile metnin birleşimi (SwiftUI ile aynı).
@MainActor
final class IconLabelView: FlippedView {
    let icon: SymbolView
    let text: TextLabel
    let symbolName: String
    /// Simge pencerenin piksel ızgarasına oturur (kesirli konumdaki etikette SwiftUI gibi; varsayılan kapalı).
    var snapsIconToWindow = false { didSet { if snapsIconToWindow != oldValue { needsLayout = true } } }
    /// Simge ile metin arası (SwiftUI `Label` varsayılanı 8; ölçülmüş yerlerde farklı).
    var spacing: CGFloat = 8 { didSet { if spacing != oldValue { needsLayout = true } } }
    /// Metnin simgeye göre dikey ek kaydırması (yalnız ölçülmüş yerlerde; varsayılan 0).
    var textNudge: CGFloat = 0 { didSet { if textNudge != oldValue { needsLayout = true } } }

    init(_ title: String, symbol: String, font: NSFont = Fonts.caption, color: NSColor = Palette.primary) {
        symbolName = symbol
        icon = SymbolView(symbol, size: font.pointSize, color: color)
        text = TextLabel(title, font: font, color: color)
        super.init(frame: .zero)
        text.setAccessibilityElement(false)
        [icon, text].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// (simge üstü, metin üstü, yükseklik) — etiketin kendi koordinatlarında.
    private var vertical: (iconTop: CGFloat, textTop: CGFloat, height: CGFloat) {
        let ih = icon.layoutSize.height
        let iconTop = TextMetrics.baseline(for: text.font) + (icon.image?.alignmentRect.minY ?? 0) - ih
        let lh = text.lineHeight
        let top = min(0, iconTop), bottom = max(lh, iconTop + ih)
        return (iconTop - top, -top, bottom - top)
    }

    override var fittingSize: NSSize {
        NSSize(width: icon.layoutSize.width + spacing + pixelCeil(text.exactWidth), height: vertical.height)
    }

    override func layout() {
        super.layout()
        let v = vertical
        let iw = icon.layoutSize.width
        icon.frame = icon.drawingFrame(layoutOrigin: CGPoint(x: 0, y: v.iconTop))
        if snapsIconToWindow {
            icon.frame = backingAlignedRect(icon.frame, options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest])
        }
        text.frame = CGRect(x: iw + spacing, y: v.textTop + textNudge, width: pixelCeil(text.exactWidth), height: text.lineHeight)
    }

    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        let textRect = window.convertToScreen(text.convert(text.bounds, to: nil))
        guard let ink = icon.inkScreenFrame() else { return textRect }
        // SwiftUI: yatayda mürekkep + metin, dikeyde metin satırı.
        return NSRect(x: ink.minX, y: textRect.minY, width: textRect.maxX - ink.minX, height: textRect.height)
    }
}

/// SwiftUI'nin barındırdığı AppKit denetimi gibi: hizalama dikdörtgeniyle yerleşir, AX çerçevesi o dikdörtgendir.
@MainActor
protocol AlignedControl: NSView {}

extension AlignedControl {
    /// `rect`: üst görünümün (çevrik) koordinatlarında hizalama dikdörtgeni.
    func setAlignmentFrame(_ rect: CGRect) {
        let i = alignmentRectInsets
        frame = CGRect(x: rect.minX - i.left, y: rect.minY - i.top, width: rect.width + i.left + i.right, height: rect.height + i.top + i.bottom)
    }

    func alignmentScreenFrame() -> NSRect? {
        guard let window else { return nil }
        let i = alignmentRectInsets
        let r = CGRect(x: i.left, y: isFlipped ? i.top : i.bottom, width: bounds.width - i.left - i.right, height: bounds.height - i.top - i.bottom)
        return window.convertToScreen(convert(r, to: nil))
    }
}

final class AlignedPopUpButton: NSPopUpButton, AlignedControl {
    override func accessibilityFrame() -> NSRect { alignmentScreenFrame() ?? super.accessibilityFrame() }
}

final class AlignedSlider: NSSlider, AlignedControl {
    override func accessibilityFrame() -> NSRect { alignmentScreenFrame() ?? super.accessibilityFrame() }
}

/// Aygıt denetimi: Label (94 pt) + küçük açılır menü; seviyesi olanlarda altında kaydırıcı + yüzde (38 pt).
@MainActor
private final class DeviceControlView: FlippedView {
    private let label: IconLabelView
    private let picker = AlignedPopUpButton(frame: .zero, pullsDown: false)
    private let slider: AlignedSlider?
    private let value: TextLabel?
    private let mixer: AudioMixerController
    private let input: Bool
    private let selector: AudioObjectPropertySelector
    private var deviceSignature: [AudioObjectID] = []

    init(title: String, symbol: String, mixer: AudioMixerController, selector: AudioObjectPropertySelector, input: Bool, hasLevel: Bool) {
        self.mixer = mixer
        self.input = input
        self.selector = selector
        label = IconLabelView(title, symbol: symbol)
        if hasLevel {
            let s = AlignedSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
            s.controlSize = .small
            s.isContinuous = true
            s.setAccessibilityLabel(title + " seviyesi")
            slider = s
            value = TextLabel("", font: Fonts.numericSmall, alignment: .right)
            value?.setAccessibilityElement(true)
        } else {
            slider = nil
            value = nil
        }
        super.init(frame: .zero)
        picker.controlSize = .small
        picker.font = NSFont.systemFont(ofSize: 11)
        picker.setAccessibilityLabel(title)
        picker.target = self
        picker.action = #selector(pick(_:))
        slider?.target = self
        slider?.action = #selector(level(_:))
        [label, picker, slider, value].compactMap { $0 }.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    var preferredHeight: CGFloat { slider == nil ? 16 : 16 + 4 + 16 }

    func update(id: AudioObjectID, level: Float?) {
        let devices = mixer.devices.filter { input ? $0.input : $0.output }
        let signature = devices.map(\.id)
        if signature != deviceSignature || picker.itemArray.map(\.title) != devices.map(\.name) {
            deviceSignature = signature
            picker.removeAllItems()
            for device in devices {
                picker.addItem(withTitle: device.name)
                picker.lastItem?.tag = Int(device.id)
            }
        }
        if picker.selectedTag() != Int(id) { picker.selectItem(withTag: Int(id)) }
        if let slider, let value, let level {
            if !isTracking { slider.doubleValue = Double(level) }
            value.set("\(Int((level * 100).rounded()))%")
        }
    }

    private var isTracking = false

    @objc private func pick(_ sender: NSPopUpButton) {
        mixer.selectDevice(AudioObjectID(sender.selectedTag()), selector: selector)
    }

    @objc private func level(_ sender: NSSlider) {
        let type = NSApp.currentEvent?.type
        isTracking = type != .leftMouseUp && (type == .leftMouseDown || type == .leftMouseDragged)
        mixer.setDeviceLevel(Float(sender.doubleValue), input: input)
        value?.set("\(Int((sender.doubleValue * 100).rounded()))%")
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let ls = label.fittingSize
        label.frame = CGRect(x: 0, y: (16 - ls.height) / 2, width: min(ls.width, 94), height: ls.height)
        picker.setAlignmentFrame(CGRect(x: 94 + 8, y: 0, width: w - 94 - 8, height: 16))
        if let slider, let value {
            value.frame = CGRect(x: w - 38, y: 20 + (16 - value.lineHeight) / 2, width: 38, height: value.lineHeight)
            slider.setAlignmentFrame(CGRect(x: 0, y: 20, width: w - 38 - 8, height: 16))
        }
    }
}

/// Uygulama satırı: 26 pt simge; ad + mini çıkış menüsü (en çok 142 pt) + "…" menüsü; kaydırıcı + yüzde + sessiz düğmesi.
@MainActor
private final class ApplicationRowView: FlippedView {
    private var app: MixerApplication
    private let mixer: AudioMixerController
    private let icon = FramedImageView()
    private let name: TextLabel
    private let route = AlignedPopUpButton(frame: .zero, pullsDown: false)
    private let more = AlignedPopUpButton(frame: .zero, pullsDown: true)
    private let slider = AlignedSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let value = TextLabel("", font: Fonts.numericSmall, alignment: .right)
    private let mute = PlainButton()
    private let muteIcon = SymbolView("speaker.wave.2", size: 13, color: Palette.primary)
    private let noAudio = TextLabel("Ses oturumu yok", font: Fonts.caption2, color: Palette.tertiary)
    private var hasAudio = true
    private var routeSignature: [String] = []
    private var isTracking = false

    init(app: MixerApplication, mixer: AudioMixerController) {
        self.app = app
        self.mixer = mixer
        name = TextLabel(app.name, font: Fonts.caption)
        super.init(frame: .zero)
        // SwiftUI `Image(nsImage:)`: AX'te etiketsiz görsel.
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(true)
        icon.setAccessibilityRole(.image)
        icon.setAccessibilityLabel("")
        route.controlSize = .mini
        route.font = NSFont.systemFont(ofSize: 9)
        route.target = self
        route.action = #selector(routeChanged(_:))
        more.isBordered = false
        more.controlSize = .regular
        more.font = NSFont.systemFont(ofSize: 13)
        (more.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtCenter
        let menu = NSMenu()
        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        head.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        menu.addItem(head)
        menu.addItem(StatusMenuItem(title: "Varsayılan sesi geri yükle", keyEquivalent: "") { [weak self, mixer] in
            guard let self else { return }
            mixer.restoreApplication(self.app.id)
        })
        more.menu = menu
        let moreLabel = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?.accessibilityDescription ?? ""
        more.setAccessibilityLabel(moreLabel.capitalized(with: Locale(identifier: "tr_TR")))
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(volumeChanged(_:))
        mute.addSubview(muteIcon)
        mute.action = { [weak self] in
            guard let self else { return }
            let volume = self.mixer.volumes[self.app.id] ?? 1
            self.mixer.setApplicationVolume(volume == 0 ? 1 : 0, pid: self.app.id)
        }
        [icon, name, route, more, slider, value, mute, noAudio].forEach(addSubview)
        update(app)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    var preferredHeight: CGFloat { 2 + 14 + 4 + 16 + (hasAudio ? 0 : 4 + noAudio.lineHeight) + 2 }

    func update(_ app: MixerApplication) {
        self.app = app
        let direct = DirectApplicationVolume.kind(for: app.bundleID)
        let audio = direct != nil || (mixer.supportsApplicationMixer && !app.processes.isEmpty)
        if audio != hasAudio { hasAudio = audio; superview?.superview?.needsLayout = true }
        icon.image = app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        name.set(app.name)
        let devices = mixer.devices.filter(\.output)
        let signature = [""] + devices.map(\.uid)
        if signature != routeSignature {
            routeSignature = signature
            route.removeAllItems()
            route.addItem(withTitle: "Varsayılan"); route.lastItem?.representedObject = ""
            for device in devices { route.addItem(withTitle: device.name); route.lastItem?.representedObject = device.uid }
        }
        let current = mixer.routes[app.id] ?? ""
        if let index = route.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }), route.indexOfSelectedItem != index {
            route.selectItem(at: index)
        }
        route.isEnabled = mixer.supportsApplicationMixer && audio
        let routeHelp = direct != nil ? "Farklı çıkış aygıtı macOS Sistem Sesi Kaydı izni gerektirir" : "Uygulama ses çıkışı; sistem sesi erişimi gerektirir"
        route.toolTip = routeHelp
        route.setAccessibilityHelp(routeHelp)
        route.setAccessibilityLabel("\(app.name) ses çıkışı")
        more.toolTip = "\(app.name) ses seçenekleri"
        more.setAccessibilityHelp(more.toolTip)
        let volume = mixer.volumes[app.id] ?? 1
        if !isTracking { slider.doubleValue = Double(volume) }
        slider.isEnabled = audio
        slider.setAccessibilityLabel(app.name + " ses seviyesi")
        let sliderHelp = direct?.isBrowser == true ? "Açık sekmedeki video ve müzik oynatıcıları" :
            direct != nil ? "Uygulamanın kendi ses seviyesi" : "Uygulamanın tüm sesi; sistem sesi erişimi gerektirir"
        slider.toolTip = sliderHelp
        slider.setAccessibilityHelp(sliderHelp)
        value.set("\(Int((volume * 100).rounded()))%")
        muteIcon.set(volume == 0 ? "speaker.slash" : "speaker.wave.2", animated: false)
        mute.isEnabled = audio
        muteIcon.alphaValue = audio ? 1 : 0.5
        mute.setAccessibilityLabel(app.name + (volume == 0 ? " sesini aç" : " sesini kapat"))
        mute.setAccessibilityEnabled(audio)
        noAudio.isHidden = audio
        needsLayout = true
    }

    @objc private func routeChanged(_ sender: NSPopUpButton) {
        mixer.setApplicationOutput(sender.selectedItem?.representedObject as? String ?? "", pid: app.id)
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        let type = NSApp.currentEvent?.type
        isTracking = type != .leftMouseUp && (type == .leftMouseDown || type == .leftMouseDragged)
        mixer.setApplicationVolume(Float(sender.doubleValue), pid: app.id)
        value.set("\(Int((sender.doubleValue * 100).rounded()))%")
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        icon.frame = CGRect(x: 0, y: 2, width: 26, height: 26)
        let x: CGFloat = 26 + 10
        // Üst satır (HStack, aralık 8): ad, Spacer(4), çıkış menüsü (≤ 142), "…" menüsü; satır 14 pt.
        let moreSize = more.intrinsicContentSize
        let moreRect = CGRect(x: w - moreSize.width, y: 2 + (14 - moreSize.height) / 2, width: moreSize.width, height: moreSize.height)
        more.setAlignmentFrame(moreRect)
        let nameW = pixelCeil(name.exactWidth)
        let routeH = route.intrinsicContentSize.height
        let routeW = min(142, max(moreRect.minX - 8 - 4 - 8 - (x + nameW), 0))
        let routeRect = CGRect(x: moreRect.minX - 8 - routeW, y: 2 + (14 - routeH) / 2, width: routeW, height: routeH)
        route.setAlignmentFrame(routeRect)
        name.frame = CGRect(x: x, y: 2 + (14 - name.lineHeight) / 2, width: min(nameW, max(routeRect.minX - 12 - x, 0)), height: name.lineHeight)
        // Alt satır (HStack, aralık 8): kaydırıcı, yüzde (38), sessiz düğmesi; satır 16 pt.
        let y2: CGFloat = 2 + 14 + 4
        let ms = muteIcon.layoutSize
        muteIcon.place(asLabelOf: mute, layoutOrigin: CGPoint(x: w - ms.width, y: y2 + (16 - ms.height) / 2))
        value.frame = CGRect(x: mute.frame.minX - 8 - 38, y: y2 + (16 - value.lineHeight) / 2, width: 38, height: value.lineHeight)
        slider.setAlignmentFrame(CGRect(x: x, y: y2, width: max(value.frame.minX - 8 - x, 0), height: 16))
        noAudio.frame = CGRect(x: x, y: y2 + 16 + 4, width: w - x, height: noAudio.lineHeight)
    }
}

/// AX çerçevesi görünüm çerçevesi olan görsel (NSImageView 1 pt kenar ekler; SwiftUI `Image` eklemez).
final class FramedImageView: NSImageView {
    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}
