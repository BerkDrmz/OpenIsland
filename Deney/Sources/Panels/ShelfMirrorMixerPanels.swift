import AppKit
import AVFoundation
import CoreAudio
import IslandCore

// MARK: - Raf

/// Genişletilmiş raf (SwiftUI `ShelfPanel`): çoklu seçim, Quick Look, çok öğeli sürükleme, işlemler.
@MainActor
final class ShelfPanelView: FlippedView, IslandPanel {
    private let shelf: ShelfStore
    private let empty = PlaceholderStack(symbol: "tray", title: "Dosyaları çentiğe sürükleyin",
        detail: "Raftaki dosyaları seçip Quick Look ile önizleyebilir, topluca herhangi bir uygulamaya, Finder'a veya AirDrop'a bırakabilirsiniz.",
        maxDetailWidth: IslandLayoutEngine.Shelf.emptyTextWidth)
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var cells: [ShelfItem.ID: ShelfItemCell] = [:]
    private let status = TextLabel("", font: Fonts.caption2, color: Palette.tertiary, truncation: .byTruncatingMiddle)
    private let selectAll: PlainButton
    private let selectAllLabel = TextLabel("", font: Fonts.caption2, color: Palette.secondary)
    private var actions: [PlainButton] = []
    private let operations = NSPopUpButton(frame: .zero, pullsDown: true)
    private var isShown = false
    private var announcedAppear = false
    private lazy var observer = Observer(track: { [shelf] in
        _ = shelf.items; _ = shelf.selection; _ = shelf.thumbnails; _ = shelf.operationStatus; _ = shelf.isOperationRunning
    }, apply: { [weak self] in self?.update() })

    init(shelf: ShelfStore) {
        self.shelf = shelf
        selectAll = PlainButton()
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        selectAll.addSubview(selectAllLabel)
        selectAllLabel.setAccessibilityElement(false)
        selectAll.action = { [weak self] in
            guard let self else { return }
            self.shelf.selection.count == self.shelf.items.count ? self.shelf.clearSelection() : self.shelf.selectAll()
        }
        for (symbol, title) in [("eye", "Önizle"), ("antenna.radiowaves.left.and.right", "AirDrop"), ("doc.on.doc", "Kopyala"), ("trash", "Kaldır")] {
            let button = PlainButton { [weak self] in self?.perform(title) }
            let icon = SymbolView(symbol, size: 10, weight: .medium, color: Palette.secondary)
            button.addSubview(icon)
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.setAccessibilityHelp(title)
            actions.append(button)
        }
        operations.isBordered = false
        (operations.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        operations.toolTip = "İşlemler: zip'le, arşivi aç, resmi sıkıştır, yolu kopyala"
        operations.setAccessibilityLabel("İşlemler")
        [empty, scroll, status, selectAll].forEach(addSubview)
        actions.forEach(addSubview)
        addSubview(operations)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() { isShown = true; observer.start() }
    func didHide() { isShown = false; announcedAppear = false; observer.stop() }

    private func perform(_ title: String) {
        let targets = shelf.actionTargets
        switch title {
        case "Önizle": shelf.quickLook(targets)
        case "AirDrop": shelf.airDrop(targets.map(\.url))
        case "Kopyala": shelf.copyToPasteboard(targets)
        default: shelf.remove(targets)
        }
    }

    private func update() {
        let isEmpty = shelf.items.isEmpty
        empty.isHidden = !isEmpty
        [scroll, status, selectAll, operations].forEach { $0.isHidden = isEmpty }
        actions.forEach { $0.isHidden = isEmpty }
        // SwiftUI'de `onAppear(shelf.panelDidAppear)` yalnız dolu raf görünümündedir.
        if !isEmpty, isShown, !announcedAppear { announcedAppear = true; shelf.panelDidAppear() }
        if isEmpty { announcedAppear = false }
        guard !isEmpty else { return }
        let ids = Set(shelf.items.map(\.id))
        for (id, cell) in cells where !ids.contains(id) { cell.removeFromSuperview(); cells[id] = nil }
        for item in shelf.items {
            let cell = cells[item.id] ?? {
                let c = ShelfItemCell(shelf: shelf)
                cells[item.id] = c
                document.addSubview(c)
                return c
            }()
            cell.configure(item: item, thumbnail: shelf.thumbnails[item.url], isSelected: shelf.selection.contains(item.id))
        }
        let scope = shelf.selection.isEmpty ? "\(shelf.items.count) öğe" : "\(shelf.selection.count) / \(shelf.items.count) seçili"
        status.set(shelf.operationStatus ?? scope)
        status.textColor = shelf.operationStatus == nil ? Palette.tertiary : Palette.secondary
        selectAllLabel.set(shelf.selection.count == shelf.items.count ? "Seçimi kaldır" : "Tümünü seç")
        selectAll.setAccessibilityLabel(selectAllLabel.stringValue)
        let targets = shelf.actionTargets
        let ops = shelf.availableOperations(for: targets)
        let menu = NSMenu()
        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        head.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "İşlemler")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        menu.addItem(head)
        for op in ops { menu.addItem(StatusMenuItem(title: op.title, keyEquivalent: "") { [shelf] in shelf.perform(op, on: targets) }) }
        operations.menu = menu
        operations.isEnabled = !(ops.isEmpty || shelf.isOperationRunning)
        operations.contentTintColor = Palette.secondary
        needsLayout = true
    }

    override func layout() {
        super.layout()
        empty.frame = bounds
        let barH: CGFloat = 18
        let scrollH = bounds.height - barH - Spacing.s
        scroll.frame = CGRect(x: 0, y: 0, width: bounds.width, height: scrollH)
        var x: CGFloat = 0
        for item in shelf.items {
            guard let cell = cells[item.id] else { continue }
            let size = cell.preferredSize
            cell.frame = CGRect(x: x, y: (scrollH - size.height) / 2, width: size.width, height: size.height)
            x += size.width + Spacing.xs
        }
        document.frame = CGRect(x: 0, y: 0, width: max(x - Spacing.xs, scroll.contentSize.width), height: scrollH)
        let by = bounds.height - barH
        // Sağdan: işlemler menüsü + 4 düğme (22 × 18), aralık 12.
        var right = bounds.width
        operations.frame = CGRect(x: right - 22, y: by, width: 22, height: barH)
        right -= 22 + Spacing.m
        for button in actions.reversed() {
            button.frame = CGRect(x: right - 22, y: by, width: 22, height: barH)
            if let icon = button.subviews.first {
                let s = icon.intrinsicContentSize
                icon.frame = pixelRect(CGRect(x: (22 - s.width) / 2, y: (barH - s.height) / 2, width: s.width, height: s.height))
            }
            right -= 22 + Spacing.m
        }
        let sw = min(status.naturalWidth, max(right - selectAllLabel.naturalWidth - 2 * Spacing.m, 0))
        status.frame = CGRect(x: 0, y: by + (barH - status.lineHeight) / 2, width: sw, height: status.lineHeight)
        let ax = sw + Spacing.m
        selectAll.frame = CGRect(x: ax, y: by + (barH - selectAllLabel.lineHeight) / 2, width: selectAllLabel.naturalWidth, height: selectAllLabel.lineHeight)
        selectAllLabel.frame = selectAll.bounds
    }
}

/// Raf öğesi: 52 pt küçük resim/simge + ad; seçili: vurgu dolgu + kontur; hover: dolgu. Tıklama/çift tıklama/
/// ⌘⇧ seçim, sağ tık menüsü ve çok öğeli sürükleme oturumu.
@MainActor
private final class ShelfItemCell: RoundedView, NSDraggingSource {
    private let shelf: ShelfStore
    private var item: ShelfItem?
    private let image = DecorativeImageView()
    private let symbol = SymbolView("doc.fill", size: 28, color: Palette.secondary)
    private let name = TextLabel("", font: Fonts.caption2, color: Palette.secondary, alignment: .center, truncation: .byTruncatingMiddle)
    private var isSelected = false
    private var isHovering = false { didSet { updateColors() } }
    private var hoverArea: NSTrackingArea?
    private var mouseDownEvent: NSEvent?

    init(shelf: ShelfStore) {
        self.shelf = shelf
        super.init(radius: Spacing.cardRadius - 4, fill: .clear)
        image.imageScaling = .scaleProportionallyUpOrDown
        [image, symbol, name].forEach(addSubview)
        name.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Seçmek için tıklayın, açmak için çift tıklayın, başka bir uygulamaya sürükleyin")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    var preferredSize: CGSize { CGSize(width: 68 + 12, height: 52 + Spacing.xs + name.lineHeight + 12) }

    func configure(item: ShelfItem, thumbnail: NSImage?, isSelected: Bool) {
        self.item = item
        self.isSelected = isSelected
        if item.isMissing {
            image.isHidden = true
            symbol.isHidden = false
            symbol.set("questionmark.folder", animated: false)
            symbol.setConfiguration(size: 26, weight: .regular)
            symbol.contentTintColor = Palette.tertiary
        } else if let thumbnail {
            image.image = thumbnail
            image.isHidden = false
            symbol.isHidden = true
        } else {
            image.isHidden = true
            symbol.isHidden = false
            symbol.set("doc.fill", animated: false)
            symbol.setConfiguration(size: 28, weight: .regular)
            symbol.contentTintColor = Palette.secondary
        }
        name.set(item.isMissing ? "Bulunamadı" : item.name)
        toolTip = item.url.path
        setAccessibilityLabel(item.isMissing ? "\(item.name), bulunamadı" : item.name)
        setAccessibilitySelected(isSelected)
        updateColors()
        needsLayout = true
    }

    private func updateColors() {
        fill = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.28) : (isHovering ? Palette.fill : .clear)
        stroke = isSelected ? (NSColor.controlAccentColor.withAlphaComponent(0.7), 1) : nil
        name.textColor = isSelected ? Palette.primary : Palette.secondary
    }

    override func layout() {
        super.layout()
        let box = CGRect(x: (bounds.width - 52) / 2, y: 6, width: 52, height: 52)
        image.frame = box
        let s = symbol.intrinsicContentSize
        symbol.frame = pixelRect(CGRect(x: box.midX - s.width / 2, y: box.midY - s.height / 2, width: s.width, height: s.height))
        name.frame = CGRect(x: 6, y: 6 + 52 + Spacing.xs, width: 68, height: name.lineHeight)
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let item else { return }
        let urls = shelf.dragPayload(startingAt: item)
        guard !urls.isEmpty else { return }
        let distance = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
        guard distance > 3 else { return }
        mouseDownEvent = nil
        let origin = convert(down.locationInWindow, from: nil)
        let items = urls.enumerated().map { index, url -> NSDraggingItem in
            let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let offset = CGFloat(min(index, 4)) * 6
            dragItem.setDraggingFrame(CGRect(x: origin.x - 24 + offset, y: origin.y - 24 - offset, width: 48, height: 48), contents: icon)
            return dragItem
        }
        let session = beginDraggingSession(with: items, event: down, source: self)
        session.draggingFormation = .pile
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil, let item else { return }
        mouseDownEvent = nil
        if event.clickCount >= 2 { shelf.open(item) } else {
            shelf.select(item, modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let item else { return false }
        shelf.select(item, modifiers: [])
        return true
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return nil }
        let targets = isSelected ? shelf.actionTargets : [item]
        let menu = NSMenu()
        let shelf = self.shelf
        menu.addItem(StatusMenuItem(title: "Aç", keyEquivalent: "") { targets.forEach(shelf.open) })
        menu.addItem(StatusMenuItem(title: "Hızlı Bakış", keyEquivalent: "") { shelf.quickLook(targets) })
        menu.addItem(StatusMenuItem(title: "Finder'da Göster", keyEquivalent: "") { shelf.revealInFinder(targets) })
        menu.addItem(StatusMenuItem(title: "AirDrop ile Gönder", keyEquivalent: "") { shelf.airDrop(targets.map(\.url)) })
        menu.addItem(StatusMenuItem(title: "Kopyala", keyEquivalent: "") { shelf.copyToPasteboard(targets) })
        let operations = shelf.availableOperations(for: targets)
        if !operations.isEmpty, !shelf.isOperationRunning {
            menu.addItem(.separator())
            for operation in operations {
                menu.addItem(StatusMenuItem(title: operation.title, keyEquivalent: "") { shelf.perform(operation, on: targets) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(StatusMenuItem(title: "Raftan Kaldır", keyEquivalent: "") { shelf.remove(targets) })
        return menu
    }
}

// MARK: - Ayna

/// Quick Mirror (SwiftUI `MirrorPanel`): dairesel kamera önizlemesi + başlık, kamera menüsü ve açıklama.
@MainActor
final class MirrorPanelView: FlippedView, IslandPanel {
    private let mirror: CameraMirror
    private let circle = RoundedView(radius: IslandLayoutEngine.Mirror.previewSize / 2, fill: Palette.fill)
    private let preview = CameraPreview.PreviewView()
    private let stateIcon = SymbolView("web.camera", size: 26, color: Palette.tertiary)
    private let spinner = NSProgressIndicator()
    private let title = TextLabel("Ayna", font: Fonts.title)
    private let cameraMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let caption = TextLabel("", font: Fonts.body, color: Palette.secondary)
    private let actionButton = PlainButton()
    private let actionLabel = TextLabel("", font: Fonts.bodyEmphasized)
    private lazy var observer = Observer(track: { [mirror] in
        _ = mirror.state; _ = mirror.cameras; _ = mirror.selectedCameraID
    }, apply: { [weak self] in self?.update() })

    init(mirror: CameraMirror) {
        self.mirror = mirror
        super.init(frame: .zero)
        circle.stroke = (Palette.separator, 0.5)
        circle.layer?.masksToBounds = true
        circle.setAccessibilityElement(true)
        circle.setAccessibilityRole(.group)
        circle.setAccessibilityLabel("Kamera önizlemesi")
        preview.wantsLayer = true
        spinner.style = .spinning
        spinner.controlSize = .small
        [preview, stateIcon, spinner].forEach(circle.addSubview)
        caption.maximumLines = 0
        cameraMenu.isBordered = false
        (cameraMenu.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        cameraMenu.toolTip = "Kamera seç"
        cameraMenu.setAccessibilityLabel("Kamera seç")
        actionLabel.setAccessibilityElement(false)
        actionButton.addSubview(actionLabel)
        [circle, title, cameraMenu, caption, actionButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() {
        mirror.panelDidAppear()
        mirror.refreshCameras() // kamera menüsünün onAppear'ı
        observer.start()
    }

    func didHide() {
        observer.stop()
        mirror.panelDidDisappear()
    }

    private func update() {
        let state = mirror.state
        preview.isHidden = state != .running
        if state == .running, preview.previewLayer.session !== mirror.session { preview.previewLayer.session = mirror.session }
        stateIcon.isHidden = !(state == .denied || state == .unavailable)
        stateIcon.set(state == .denied ? "video.slash.fill" : "web.camera", animated: false)
        spinner.isHidden = !(state == .idle || state == .starting)
        if spinner.isHidden { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
        let text: String = switch state {
        case .running: "Toplantıdan önce saç ve kadraj kontrolü. Görüntü kaydedilmez; sekmeden çıkınca kamera kapanır."
        case .denied: "Kamera izni verilmedi. Sistem Ayarları › Gizlilik ve Güvenlik › Kamera."
        case .unavailable: "Kamera başlatılamadı. Kapak kapalı olabilir ya da kamera az önce başka bir uygulamadaydı."
        case .idle, .starting: "Kamera başlatılıyor…"
        }
        caption.set(text)
        actionButton.isHidden = !(state == .denied || state == .unavailable)
        if state == .denied {
            actionLabel.set("Kamera iznini aç")
            actionButton.action = { NSWorkspace.shared.open(PermissionsCenter.Pane.camera.url) }
        } else if state == .unavailable {
            actionLabel.set("Yeniden dene")
            actionButton.action = { [mirror] in mirror.start() }
        }
        actionButton.setAccessibilityLabel(actionLabel.stringValue)
        let menu = NSMenu()
        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        head.image = NSImage(systemSymbolName: "web.camera", accessibilityDescription: "Kamera seç")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        menu.addItem(head)
        for camera in mirror.cameras {
            let item = StatusMenuItem(title: camera.name, keyEquivalent: "") { [mirror] in mirror.select(camera) }
            item.state = camera.id == mirror.selectedCameraID ? .on : .off
            menu.addItem(item)
        }
        cameraMenu.menu = menu
        cameraMenu.contentTintColor = Palette.primary
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let m = IslandLayoutEngine.Mirror.self
        let captionWidth = m.captionWidth
        let total = m.previewSize + m.spacing + captionWidth
        let x0 = (bounds.width - total) / 2
        circle.frame = CGRect(x: x0, y: (bounds.height - m.previewSize) / 2, width: m.previewSize, height: m.previewSize)
        preview.frame = circle.bounds
        preview.previewLayer.frame = preview.bounds
        let s = stateIcon.intrinsicContentSize
        stateIcon.frame = pixelRect(CGRect(x: (m.previewSize - s.width) / 2, y: (m.previewSize - s.height) / 2, width: s.width, height: s.height))
        let sp = spinner.fittingSize
        spinner.frame = CGRect(x: (m.previewSize - sp.width) / 2, y: (m.previewSize - sp.height) / 2, width: sp.width, height: sp.height)
        let tx = x0 + m.previewSize + m.spacing
        let th = title.lineHeight
        let ch = caption.height(forWidth: captionWidth)
        let ah = actionButton.isHidden ? 0 : actionLabel.lineHeight + 8
        let colH = th + 8 + ch + ah
        var y = (bounds.height - colH) / 2
        title.frame = CGRect(x: tx, y: y, width: title.naturalWidth, height: th)
        cameraMenu.frame = CGRect(x: tx + captionWidth - 20, y: y + (th - 16) / 2, width: 20, height: 16)
        y += th + 8
        caption.frame = CGRect(x: tx, y: y, width: captionWidth, height: ch)
        y += ch + 8
        actionButton.frame = CGRect(x: tx, y: y, width: actionLabel.naturalWidth, height: actionLabel.lineHeight)
        actionLabel.frame = actionButton.bounds
    }
}

// MARK: - Ses mikseri

/// Ses mikseri (SwiftUI `AudioMixerPanel`): aygıt seçimi ve seviyeleri, uygulama başına ses ve çıkış.
@MainActor
final class MixerPanelView: FlippedView, IslandPanel {
    private let mixer: AudioMixerController
    private let settings: () -> Void
    private let header = TextLabel("SES MİKSERİ", font: Fonts.sectionLabel, color: Palette.secondary)
    private let routes = TextLabel("", font: Fonts.caption2, color: Palette.secondary, alignment: .right)
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var rows: [NSView] = []
    private let errorLabel = TextLabel("", font: Fonts.caption2, color: .systemOrange)
    private let errorClose = PlainButton()
    private let settingsButton = PlainButton()
    private let quitButton = PlainButton()
    private lazy var observer = Observer(track: { [mixer] in
        _ = mixer.devices; _ = mixer.applications; _ = mixer.output; _ = mixer.systemOutput; _ = mixer.input
        _ = mixer.outputLevel; _ = mixer.inputLevel; _ = mixer.error; _ = mixer.volumes; _ = mixer.routes; _ = mixer.activeRouteCount
    }, apply: { [weak self] in self?.update() })

    init(mixer: AudioMixerController, settings: @escaping () -> Void) {
        self.mixer = mixer
        self.settings = settings
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = document
        errorLabel.maximumLines = 0
        errorClose.addSubview(SymbolView("xmark", size: 10, color: Palette.primary))
        errorClose.setAccessibilityLabel("Hata mesajını kapat")
        errorClose.action = { [mixer] in mixer.clearError() }
        for (button, symbol, title) in [(settingsButton, "gearshape", "Ayarlar"), (quitButton, "power", "Çık")] {
            let icon = SymbolView(symbol, size: 11, color: Palette.primary)
            let label = TextLabel(title, font: Fonts.caption)
            label.setAccessibilityElement(false)
            button.addSubview(icon); button.addSubview(label)
            button.setAccessibilityLabel(title)
        }
        settingsButton.action = settings
        quitButton.action = { NSApp.terminate(nil) }
        [header, routes, scroll, errorLabel, errorClose, settingsButton, quitButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() { mixer.showPanel(); observer.start() }
    func didHide() { observer.stop(); mixer.hidePanel() }

    private func update() {
        routes.set(mixer.activeRouteCount > 0 ? "\(mixer.activeRouteCount) özel ses yolu" : "")
        rows.forEach { $0.removeFromSuperview() }
        rows = [
            DeviceControlView(title: "Çıkış", symbol: "speaker.wave.2", mixer: mixer, id: mixer.output,
                              selector: kAudioHardwarePropertyDefaultOutputDevice, input: false, level: mixer.outputLevel),
            DeviceControlView(title: "Sistem sesleri", symbol: "bell", mixer: mixer, id: mixer.systemOutput,
                              selector: kAudioHardwarePropertyDefaultSystemOutputDevice, input: false, level: nil),
            DeviceControlView(title: "Mikrofon", symbol: "mic", mixer: mixer, id: mixer.input,
                              selector: kAudioHardwarePropertyDefaultInputDevice, input: true, level: mixer.inputLevel),
            SeparatorView(),
        ]
        if !mixer.supportsApplicationMixer {
            rows.append(TextLabel("Uygulama başına ses kontrolü macOS 14.2 veya üstünü gerektirir.", font: Fonts.caption, color: .secondaryLabelColor))
        }
        for app in mixer.applications { rows.append(ApplicationRowView(app: app, mixer: mixer)) }
        rows.forEach(document.addSubview)
        errorLabel.isHidden = mixer.error == nil
        errorClose.isHidden = mixer.error == nil
        errorLabel.set(mixer.error ?? "")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let hh = header.lineHeight
        header.frame = CGRect(x: 0, y: 0, width: header.naturalWidth, height: hh)
        routes.frame = CGRect(x: bounds.width - routes.naturalWidth, y: 0, width: routes.naturalWidth, height: routes.lineHeight)
        let footerH = TextMetrics.lineHeight(for: Fonts.caption)
        var bottom = bounds.height - footerH
        layoutFooterButton(settingsButton, x: 0, y: bottom, alignRight: false)
        layoutFooterButton(quitButton, x: bounds.width, y: bottom, alignRight: true)
        if !errorLabel.isHidden {
            let eh = errorLabel.height(forWidth: bounds.width - 20)
            bottom -= 10 + eh
            errorLabel.frame = CGRect(x: 0, y: bottom, width: bounds.width - 20, height: eh)
            errorClose.frame = CGRect(x: bounds.width - 12, y: bottom, width: 12, height: 12)
            errorClose.subviews.first?.frame = errorClose.bounds
        }
        let sy = hh + 10
        scroll.frame = CGRect(x: 0, y: sy, width: bounds.width, height: max(bottom - 10 - sy, 0))
        let w = bounds.width - 3
        var y: CGFloat = 0
        for row in rows {
            let h: CGFloat
            switch row {
            case let r as DeviceControlView: h = r.preferredHeight
            case let r as ApplicationRowView: h = r.preferredHeight
            case is SeparatorView: h = 1
            case let t as TextLabel: h = t.lineHeight
            default: h = 20
            }
            row.frame = CGRect(x: 0, y: y, width: w, height: h)
            y += h + 12
        }
        document.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(y - 12, scroll.contentSize.height))
    }

    private func layoutFooterButton(_ button: PlainButton, x: CGFloat, y: CGFloat, alignRight: Bool) {
        guard let icon = button.subviews.first as? SymbolView, let label = button.subviews.last as? TextLabel else { return }
        let s = icon.intrinsicContentSize
        let w = s.width + 5 + label.naturalWidth
        let h = max(s.height, label.lineHeight)
        button.frame = CGRect(x: alignRight ? x - w : x, y: y, width: w, height: h)
        icon.frame = pixelRect(CGRect(x: 0, y: (h - s.height) / 2, width: s.width, height: s.height))
        label.frame = CGRect(x: s.width + 5, y: (h - label.lineHeight) / 2, width: label.naturalWidth, height: label.lineHeight)
    }
}

@MainActor
private final class DeviceControlView: FlippedView {
    private let icon: SymbolView
    private let title: TextLabel
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let slider: NSSlider?
    private let value: TextLabel?
    private let mixer: AudioMixerController
    private let input: Bool
    private let selector: AudioObjectPropertySelector

    init(title text: String, symbol: String, mixer: AudioMixerController, id: AudioObjectID,
         selector: AudioObjectPropertySelector, input: Bool, level: Float?) {
        self.mixer = mixer
        self.input = input
        self.selector = selector
        icon = SymbolView(symbol, size: 11, color: Palette.primary)
        title = TextLabel(text, font: Fonts.caption)
        if let level {
            let s = NSSlider(value: Double(level), minValue: 0, maxValue: 1, target: nil, action: nil)
            s.controlSize = .small
            s.setAccessibilityLabel(text + " seviyesi")
            slider = s
            value = TextLabel("\(Int((level * 100).rounded()))%", font: Fonts.numericSmall, alignment: .right)
        } else {
            slider = nil
            value = nil
        }
        super.init(frame: .zero)
        picker.controlSize = .small
        picker.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        picker.setAccessibilityLabel(text)
        for device in mixer.devices where input ? device.input : device.output {
            picker.addItem(withTitle: device.name)
            picker.lastItem?.tag = Int(device.id)
        }
        picker.selectItem(withTag: Int(id))
        picker.target = self
        picker.action = #selector(pick(_:))
        slider?.target = self
        slider?.action = #selector(level(_:))
        [icon, title, picker, slider, value].compactMap { $0 }.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    var preferredHeight: CGFloat { slider == nil ? 22 : 22 + 4 + 18 }

    @objc private func pick(_ sender: NSPopUpButton) {
        mixer.selectDevice(AudioObjectID(sender.selectedTag()), selector: selector)
    }

    @objc private func level(_ sender: NSSlider) {
        mixer.setDeviceLevel(Float(sender.doubleValue), input: input)
        value?.set("\(Int((sender.doubleValue * 100).rounded()))%")
    }

    override func layout() {
        super.layout()
        let s = icon.intrinsicContentSize
        icon.frame = pixelRect(CGRect(x: 0, y: (22 - s.height) / 2, width: s.width, height: s.height))
        title.frame = CGRect(x: s.width + 5, y: (22 - title.lineHeight) / 2, width: 94 - s.width - 5, height: title.lineHeight)
        let ph = picker.intrinsicContentSize.height
        picker.frame = CGRect(x: 94 + 8, y: (22 - ph) / 2, width: bounds.width - 94 - 8, height: ph)
        if let slider, let value {
            let y: CGFloat = 26
            value.frame = CGRect(x: bounds.width - 38, y: y + (18 - value.lineHeight) / 2, width: 38, height: value.lineHeight)
            let sh = slider.intrinsicContentSize.height
            slider.frame = CGRect(x: 0, y: y + (18 - sh) / 2, width: bounds.width - 38 - 8, height: sh)
        }
    }
}

@MainActor
private final class ApplicationRowView: FlippedView {
    private let app: MixerApplication
    private let mixer: AudioMixerController
    private let icon = DecorativeImageView()
    private let name: TextLabel
    private let route = NSPopUpButton(frame: .zero, pullsDown: false)
    private let more = NSPopUpButton(frame: .zero, pullsDown: true)
    private let slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let value = TextLabel("", font: Fonts.numericSmall, alignment: .right)
    private let mute = PlainButton()
    private let muteIcon = SymbolView("speaker.wave.2", size: 11, color: Palette.primary)
    private let noAudio = TextLabel("Ses oturumu yok", font: Fonts.caption2, color: Palette.tertiary)
    private let hasAudio: Bool

    init(app: MixerApplication, mixer: AudioMixerController) {
        self.app = app
        self.mixer = mixer
        name = TextLabel(app.name, font: Fonts.caption)
        let direct = DirectApplicationVolume.kind(for: app.bundleID)
        hasAudio = direct != nil || (mixer.supportsApplicationMixer && !app.processes.isEmpty)
        super.init(frame: .zero)
        icon.image = app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        route.controlSize = .mini
        route.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        route.addItem(withTitle: "Varsayılan"); route.lastItem?.representedObject = ""
        for device in mixer.devices where device.output {
            route.addItem(withTitle: device.name); route.lastItem?.representedObject = device.uid
        }
        let current = mixer.routes[app.id] ?? ""
        if let index = route.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) { route.selectItem(at: index) }
        route.isEnabled = mixer.supportsApplicationMixer && hasAudio
        route.toolTip = direct != nil ? "Farklı çıkış aygıtı macOS Sistem Sesi Kaydı izni gerektirir" : "Uygulama ses çıkışı; sistem sesi erişimi gerektirir"
        route.setAccessibilityLabel("\(app.name) ses çıkışı")
        route.target = self
        route.action = #selector(routeChanged(_:))
        more.isBordered = false
        (more.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        let menu = NSMenu()
        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        head.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        menu.addItem(head)
        menu.addItem(StatusMenuItem(title: "Varsayılan sesi geri yükle", keyEquivalent: "") { [mixer] in mixer.restoreApplication(app.id) })
        more.menu = menu
        more.toolTip = "\(app.name) ses seçenekleri"
        let volume = mixer.volumes[app.id] ?? 1
        slider.controlSize = .small
        slider.doubleValue = Double(volume)
        slider.isEnabled = hasAudio
        slider.target = self
        slider.action = #selector(volumeChanged(_:))
        slider.setAccessibilityLabel(app.name + " ses seviyesi")
        slider.toolTip = direct?.isBrowser == true ? "Açık sekmedeki video ve müzik oynatıcıları" :
            direct != nil ? "Uygulamanın kendi ses seviyesi" : "Uygulamanın tüm sesi; sistem sesi erişimi gerektirir"
        value.set("\(Int((volume * 100).rounded()))%")
        muteIcon.set(volume == 0 ? "speaker.slash" : "speaker.wave.2", animated: false)
        mute.addSubview(muteIcon)
        mute.isEnabled = hasAudio
        mute.setAccessibilityLabel(app.name + (volume == 0 ? " sesini aç" : " sesini kapat"))
        mute.action = { [mixer] in mixer.setApplicationVolume(volume == 0 ? 1 : 0, pid: app.id) }
        noAudio.isHidden = hasAudio
        [icon, name, route, more, slider, value, mute, noAudio].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    var preferredHeight: CGFloat { 2 + 20 + 4 + 18 + (hasAudio ? 0 : 4 + noAudio.lineHeight) + 2 }

    @objc private func routeChanged(_ sender: NSPopUpButton) {
        mixer.setApplicationOutput(sender.selectedItem?.representedObject as? String ?? "", pid: app.id)
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        mixer.setApplicationVolume(Float(sender.doubleValue), pid: app.id)
        value.set("\(Int((sender.doubleValue * 100).rounded()))%")
    }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 0, y: 2, width: 26, height: 26)
        let x: CGFloat = 26 + 10
        let w = bounds.width - x
        more.frame = CGRect(x: bounds.width - 18, y: 2, width: 18, height: 18)
        let rw = min(route.intrinsicContentSize.width, 142)
        route.frame = CGRect(x: more.frame.minX - 8 - rw, y: 2 + (20 - route.intrinsicContentSize.height) / 2, width: rw, height: route.intrinsicContentSize.height)
        name.frame = CGRect(x: x, y: 2 + (20 - name.lineHeight) / 2, width: max(route.frame.minX - 4 - x, 0), height: name.lineHeight)
        let y2: CGFloat = 2 + 20 + 4
        let ms = muteIcon.intrinsicContentSize
        mute.frame = pixelRect(CGRect(x: bounds.width - ms.width, y: y2 + (18 - ms.height) / 2, width: ms.width, height: ms.height))
        muteIcon.frame = mute.bounds
        value.frame = CGRect(x: mute.frame.minX - 8 - 38, y: y2 + (18 - value.lineHeight) / 2, width: 38, height: value.lineHeight)
        let sh = slider.intrinsicContentSize.height
        slider.frame = CGRect(x: x, y: y2 + (18 - sh) / 2, width: max(value.frame.minX - 8 - x, 0), height: sh)
        noAudio.frame = CGRect(x: x, y: y2 + 18 + 4, width: w, height: noAudio.lineHeight)
    }
}
