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
            if let icon = button.subviews.first as? SymbolView {
                icon.frame = icon.drawingFrame(centeredIn: CGRect(x: 0, y: 0, width: 22, height: barH))
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
        symbol.frame = symbol.drawingFrame(centeredIn: box)
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
        stateIcon.frame = stateIcon.drawingFrame(centeredIn: CGRect(x: 0, y: 0, width: m.previewSize, height: m.previewSize))
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
