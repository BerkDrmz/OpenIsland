import AppKit
import IslandCore

/// Quick Notes (sol) + App/Shortcuts başlatıcı (sağ) (SwiftUI `NotesPanel`).
@MainActor
final class NotesPanelView: FlippedView, IslandPanel, NSTextViewDelegate {
    /// SwiftUI `NotesPanel`: not sütunu önce (`PanelAXOrder.first`), başlatıcı sonra.
    func axNavigationRank(of view: NSView) -> Int? {
        [noteLabel, editorBackground, scroll].contains { view.isDescendant(of: $0) } ? 3 : 0
    }
    private let notes: NotesStore
    private let launcher: LauncherStore
    private let noteLabel = TextLabel("Hızlı Not", font: Fonts.sectionLabel, color: Palette.secondary)
    private let editorBackground = RoundedView(radius: Spacing.cardRadius - 4, fill: Palette.fill)
    private let scroll: NSScrollView = NotesScrollView()
    private let textView: NSTextView
    private let launcherLabel = TextLabel("Başlatıcı", font: Fonts.sectionLabel, color: Palette.secondary)
    private let addButton = FramedPopUpButton(frame: .zero, pullsDown: true)
    private let grid = NSScrollView()
    private let gridDocument = LazyStackView()
    private var tiles: [UUID: LauncherTileView] = [:]
    private var refreshTask: Task<Void, Never>?
    private lazy var observer = Observer(track: { [notes, launcher] in
        _ = notes.text; _ = launcher.items; _ = launcher.availableShortcuts
    }, apply: { [weak self] in self?.update() })

    init(notes: NotesStore, launcher: LauncherStore) {
        self.notes = notes
        self.launcher = launcher
        let textView = NotesTextView(frame: .zero)
        self.textView = textView
        super.init(frame: .zero)
        // SwiftUI `TextEditor`'ün metin görünümü ayarlarıyla birebir (çalışma anında okunmuştur): ekleme imleci vurgu
        // renginde, akıllı tırnak/tire, metin değiştirme, otomatik düzeltme ve tamamlama açık; sürekli imla denetimi kapalı.
        textView.font = Fonts.body
        textView.textColor = Palette.primary
        textView.insertionPointColor = .controlAccentColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticTextCompletionEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
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
        scroll.verticalScrollElasticity = .allowed
        scroll.documentView = textView
        editorBackground.addSubview(scroll)

        addButton.isBordered = false
        addButton.pullsDown = true
        (addButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        addButton.setAccessibilityLabel("Başlatıcıya ekle")
        grid.drawsBackground = false
        grid.hasVerticalScroller = false
        grid.documentView = gridDocument
        [noteLabel, editorBackground, launcherLabel, addButton, grid].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    /// Uyku hâlindeki ön kurulum: not metni, menü ve kutucuklar mevcut veriden doldurulur; metin yerleşimi ve ilk çizim
    /// ilk açılıştan önce boşta yapılır (ölçüldü: ilk açılışta ~70 ms). Gözlem başlamaz.
    func prewarm() { update() }

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

    /// Menü yalnız kısayol listesi değişince yeniden kurulur: yeni menü atamak açılır düğmenin simgesini her
    /// gösterimde yeniden rasterleştiriyordu.
    private var menuShortcuts: [String]?

    private func rebuildMenu() {
        guard menuShortcuts != launcher.availableShortcuts else { return }
        menuShortcuts = launcher.availableShortcuts
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
        if addButton.contentTintColor != Palette.primary { addButton.contentTintColor = Palette.primary }
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
final class LauncherTileView: PlainButton, TransientStateResettable {
    func resetTransientState() { hover.animate(to: 0, spec: nil) }

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

    /// 1,08 hover ölçeği `IslandMotion.control` yayıyla, simge merkezi çevresinde.
    private lazy var hover = LayerSpring(0) { [weak self] h in
        guard let layer = self?.image.layer else { return [] }
        return [(layer, "transform", LayerSpring.scale(1 + 0.08 * h, about: CGPoint(x: layer.bounds.midX, y: layer.bounds.midY), in: layer))]
    }

    private func setHover(_ on: Bool) { hover.animate(to: on ? 1 : 0, spec: AppMotion.control) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(StatusMenuItem(title: "Kaldır", keyEquivalent: "") { [remove] in remove() })
        return menu
    }
}

/// The island is deliberately nonactivating. A standard NSTextView discards
/// the first click while making that panel key, leaving the window itself as
/// first responder. Accept that same click in this editor only, as the island's
/// other controls do; do not activate the application or steal focus on hover.
/// Erişilebilirlikte saydam kaydırma görünümü: metin alanı ve kaydırma çubuğu AX ağacında kalır, üst kaba taşınır.
/// Tam Klavye Erişimi, bir tıklama paneli anahtar pencere yaptığında pencere-anahtar oldu işleyicisinde ~1 sn klavye
/// odağı izlemesini kapatıyor ve imleci pencereye girişte odak zincirindeki ilk durağa koyuyordu. Bu durak kaydırma
/// alanı olunca fareyle düzenleyiciye tıklandıktan sonraki ilk Ctrl-Tab metin alanına inmekte harcanıyordu.
private final class NotesScrollView: NSScrollView {
    override func isAccessibilityElement() -> Bool { false }
}

private final class NotesTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
