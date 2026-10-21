import AppKit
import IslandCore

/// Quick Notes (sol) + App/Shortcuts başlatıcı (sağ) (SwiftUI `NotesPanel`).
@MainActor
final class NotesPanelView: FlippedView, IslandPanel, NSTextViewDelegate {
    private let notes: NotesStore
    private let launcher: LauncherStore
    private let noteLabel = TextLabel("Hızlı Not", font: Fonts.sectionLabel, color: Palette.secondary)
    private let editorBackground = RoundedView(radius: Spacing.cardRadius - 4, fill: Palette.fill)
    private let scroll = NSScrollView()
    private let textView: NSTextView
    private let launcherLabel = TextLabel("Başlatıcı", font: Fonts.sectionLabel, color: Palette.secondary)
    private let addButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let grid = NSScrollView()
    private let gridDocument = FlippedView()
    private var tiles: [UUID: LauncherTileView] = [:]
    private var refreshTask: Task<Void, Never>?
    private lazy var observer = Observer(track: { [notes, launcher] in
        _ = notes.text; _ = launcher.items; _ = launcher.availableShortcuts
    }, apply: { [weak self] in self?.update() })

    init(notes: NotesStore, launcher: LauncherStore) {
        self.notes = notes
        self.launcher = launcher
        let textView = NSTextView(frame: .zero)
        self.textView = textView
        super.init(frame: .zero)
        textView.font = Fonts.body
        textView.textColor = Palette.primary
        textView.insertionPointColor = Palette.primary
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .overlay
        scroll.documentView = textView
        editorBackground.addSubview(scroll)

        addButton.isBordered = false
        addButton.pullsDown = true
        (addButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        addButton.setAccessibilityLabel("Başlatıcıya ekle")
        grid.drawsBackground = false
        grid.hasVerticalScroller = false
        grid.documentView = gridDocument
        gridDocument.makeLazyStackContainer()
        [noteLabel, editorBackground, launcherLabel, addButton, grid].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() {
        observer.start()
        refreshTask = Task { [launcher] in await launcher.refreshShortcutsIfNeeded() } // SwiftUI `.task`
    }

    func didHide() {
        observer.stop()
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func update() {
        if textView.string != notes.text && !(window?.firstResponder === textView && textView.hasMarkedText()) {
            textView.string = notes.text
        }
        rebuildMenu()
        rebuildTiles()
        needsLayout = true
    }

    func textDidChange(_ notification: Notification) {
        if notes.text != textView.string { notes.text = textView.string }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let symbol = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        symbol.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        menu.addItem(symbol) // açılır düğmenin başlık öğesi (yalnız simge)
        menu.addItem(StatusMenuItem(title: "Uygulama ekle…", keyEquivalent: "") { [launcher] in launcher.addApplication() })
        menu.addItem(StatusMenuItem(title: "Bağlantı ekle…", keyEquivalent: "") { [launcher] in launcher.addLink() })
        let shortcuts = NSMenuItem(title: "Kısayol sabitle", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if launcher.availableShortcuts.isEmpty {
            let none = NSMenuItem(title: "Kısayol bulunamadı", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for name in launcher.availableShortcuts {
            sub.addItem(StatusMenuItem(title: name, keyEquivalent: "") { [launcher] in launcher.pinShortcut(name) })
        }
        shortcuts.submenu = sub
        menu.addItem(shortcuts)
        addButton.menu = menu
        addButton.contentTintColor = Palette.primary
    }

    private func rebuildTiles() {
        let ids = launcher.items.map(\.id)
        for (id, tile) in tiles where !ids.contains(id) { tile.removeFromSuperview(); tiles[id] = nil }
        for item in launcher.items where tiles[item.id] == nil {
            let tile = LauncherTileView(title: launcher.title(for: item), icon: launcher.icon(for: item),
                                        launch: { [launcher] in launcher.launch(item) },
                                        remove: { [launcher] in launcher.remove(item) })
            tiles[item.id] = tile
            gridDocument.addSubview(tile)
        }
        let n = IslandLayoutEngine.Notes.self
        grid.verticalScrollElasticity = launcher.items.count <= n.launcherColumns * n.launcherMaxRows ? .none : .allowed
    }

    override func layout() {
        super.layout()
        let n = IslandLayoutEngine.Notes.self
        let launcherWidth = n.launcherWidth
        let noteWidth = bounds.width - launcherWidth - n.columnSpacing
        let lh = noteLabel.lineHeight
        noteLabel.frame = CGRect(x: 0, y: 0, width: noteWidth, height: lh)
        editorBackground.frame = CGRect(x: 0, y: lh + 4, width: noteWidth, height: max(bounds.height - lh - 4, n.editorHeight))
        scroll.frame = editorBackground.bounds.insetBy(dx: 6, dy: 6)
        textView.frame.size.width = scroll.contentSize.width
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let x = noteWidth + n.columnSpacing
        // Başlık satırı: metin + menü düğmesi (20 × 14), satır 14 pt; altında 6 pt.
        let rowH: CGFloat = 14
        launcherLabel.frame = CGRect(x: x, y: (rowH - launcherLabel.lineHeight) / 2, width: launcherLabel.naturalWidth, height: launcherLabel.lineHeight)
        addButton.frame = CGRect(x: x + launcherWidth - 20, y: 0, width: 20, height: rowH)
        let gy = rowH + 6
        grid.frame = CGRect(x: x, y: gy, width: launcherWidth, height: bounds.height - gy)
        var index = 0
        for item in launcher.items {
            guard let tile = tiles[item.id] else { continue }
            let col = index % n.launcherColumns, row = index / n.launcherColumns
            // Sütun 32 pt (sabit), satır yüksekliği içerik kadar (28 pt simge); aralık 8.
            tile.frame = CGRect(x: CGFloat(col) * (n.launcherCell + n.launcherSpacing) + (n.launcherCell - 28) / 2,
                                y: CGFloat(row) * (28 + n.launcherSpacing), width: 28, height: 28)
            index += 1
        }
        let rows = (launcher.items.count + n.launcherColumns - 1) / n.launcherColumns
        let contentHeight = CGFloat(rows) * 28 + CGFloat(max(rows - 1, 0)) * n.launcherSpacing
        gridDocument.frame = CGRect(x: 0, y: 0, width: launcherWidth, height: max(contentHeight, grid.contentSize.height))
    }
}

/// Başlatıcı kutucuğu: 28 pt simge, hover'da 1,08 ölçek, sağ tıkta "Kaldır".
@MainActor
final class LauncherTileView: PlainButton {
    private let image = DecorativeImageView()
    private let remove: () -> Void
    private var hoverArea: NSTrackingArea?

    init(title: String, icon: NSImage, launch: @escaping () -> Void, remove: @escaping () -> Void) {
        self.remove = remove
        super.init(action: launch)
        image.image = icon
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.setAccessibilityElement(false)
        addSubview(image)
        toolTip = title
        setAccessibilityLabel(title)
        setAccessibilityHelp(title)
    }

    override func layout() {
        super.layout()
        image.frame = bounds
        if let l = image.layer {
            l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            l.position = CGPoint(x: image.frame.midX, y: image.frame.midY)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            ctx.allowsImplicitAnimation = true
            image.layer?.setAffineTransform(on ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(StatusMenuItem(title: "Kaldır", keyEquivalent: "") { [remove] in remove() })
        return menu
    }
}
