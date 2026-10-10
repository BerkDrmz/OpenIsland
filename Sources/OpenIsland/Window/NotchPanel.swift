import AppKit
import IslandCore
import Quartz
import SwiftUI

/// Adanın **görsel** penceresi: menü çubuğunun ve donanım çentiğinin üzerine oturan sabit boyutlu,
/// şeffaf tuval. Animasyon sırasında hiç yeniden boyutlanmaz (bkz. `NotchWindowController`).
///
/// Kritik ayarlar:
/// - `.nonactivatingPanel`: tıklamada uygulama aktifleşmez; kullanıcının odaktaki uygulaması değişmez.
/// - `level = .mainMenu + 3`: menü çubuğunun, status item'ların ve tam ekran uygulamaların üzerinde; ekran
///   koruyucunun ve kilit ekranının altında.
/// - Space/tam ekran geçişlerindeki davranışı `SpacePresentationController` yönetir (sağlayıcılar, doğrulama).
/// - Temel `collectionBehavior` `PublicStationaryProvider.collectionBehavior`'dır (`.canJoinAllSpaces +
///   .canJoinAllApplications + .stationary + .fullScreenAuxiliary + .ignoresCycle`): her Space'te ve tam ekranda
///   görünür, Cmd+` döngüsüne girmez.
final class NotchPanel: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        Self.configureOverlay(self, level: NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3))
        becomesKeyOnlyIfNeeded = true // yalnızca metin alanına tıklanınca key olur (Quick Notes)
        ignoresMouseEvents = true // dinlenmede girdiyi sensör penceresi alır
    }

    /// Görsel panel ve sensör için ortak "sistem kaplaması" ayarları.
    static func configureOverlay(_ panel: NSPanel, level: NSWindow.Level) {
        panel.isFloatingPanel = true
        panel.level = level
        // Temel (public) davranış; Space geçişinde kaymayı `SpacePresentationController` önler.
        panel.collectionBehavior = PublicStationaryProvider.collectionBehavior
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // gölge SwiftUI'da şekle göre çizilir
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.worksWhenModal = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// Ada kapanırken klavye odağını, önceki uygulamaya geri verir.
    func relinquishKeyFocus() {
        guard isKeyWindow, !QuickLookController.shared.isPreviewing else { return }
        orderOut(nil)
        orderFrontRegardless()
    }

    // MARK: - Quick Look (QLPreviewPanelController)
    // QLPreviewPanel denetleyicisini responder zincirinde arar; key olan bu panel, raftaki dosyalar için
    // denetleyiciliği üstlenir. Veri kaynağını doğrudan atamak yerine Apple'ın önerdiği yol budur.

    // Quick Look bu yöntemleri ana iş parçacığında, responder zinciri üzerinden çağırır.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { QuickLookController.shared.hasItems }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { if let panel { QuickLookController.shared.begin(panel) } }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { if let panel { QuickLookController.shared.end(panel) } }
    }
}

/// Dinlenmedeki (idle / compact) adanın **girdi** penceresi.
///
/// Görünmezdir ve yalnızca adanın dinlenme dikdörtgeni (+ ekranın üst kenarına kadar) kadardır:
/// hover `NSTrackingArea`, tıklama `mouseDown`, dosya sürükleme `NSDraggingDestination`, trackpad
/// jestleri `scrollWheel` ile gelir. Görsel pencere dinlenmede fareyi tamamen geçirir.
/// Yalnızca görünmez bir pencere yeniden boyutlandığı için boyut değişimi hiçbir zaman titreme yapmaz.
final class NotchSensorPanel: NSPanel {
    let sensorView = SensorView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        NotchPanel.configureOverlay(self, level: NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4))
        contentView = sensorView
        ignoresMouseEvents = false // şeffaf alanlarda da olay alması için açıkça false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class SensorView: NSView {
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?
    var onClick: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onDrop: ((NSPasteboard) -> Bool)?

    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Tamamen şeffaf pikseller bazı durumlarda olayları geçirebilir; siyah adanın üzerinde görünmez
        // kalan binde birlik bir dolgu isabet testini garanti eder.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor
        registerForDraggedTypes(Self.draggedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) desteklenmiyor") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onPointerEntered?() }
    override func mouseExited(with event: NSEvent) { onPointerExited?() }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onContextMenu?(event) } else { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: Self.draggedTypes) != nil else { return [] }
        onDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExited?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender.draggingPasteboard) ?? false
    }
}

/// Görsel panelin içerik görünümü: SwiftUI'yi taşır ve **yükseltilmiş** adada hover'ı olay güdümlü
/// algılar (`NSTrackingArea`, yalnızca sınır geçişinde olay).
final class IslandContainerView: NSView {
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?

    private var hoverArea: NSTrackingArea?
    private var trackingRect: CGRect = .zero
    private var pointerInside = false
    private let mouseLocation: () -> CGPoint

    init(content: NSView, mouseLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }) {
        self.mouseLocation = mouseLocation
        super.init(frame: .zero)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) desteklenmiyor") }

    /// - Parameter pointerInside: İmleç zaten içerideyse `.assumeInside`: ilk olay çıkışta üretilir;
    ///   pencere fareyi yeni kabul etmeye başladığında bile çıkış kaçırılmaz.
    func setTrackingRect(_ rect: CGRect, pointerInside: Bool) {
        guard rect != trackingRect || pointerInside != self.pointerInside || (!rect.isEmpty && hoverArea == nil) else { return }
        trackingRect = rect
        self.pointerInside = pointerInside
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard !rect.isEmpty else { return }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        if pointerInside { options.insert(.assumeInside) }
        let area = NSTrackingArea(rect: rect, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === hoverArea else { return super.mouseEntered(with: event) }
        guard containsPointer() == true else { return }
        pointerInside = true
        onPointerEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        // A queued exit may belong to an area replaced during expansion. Validate the
        // current region rather than losing that exit or closing after a quick reentry.
        guard let area = event.trackingArea, area.owner as? IslandContainerView === self else {
            return super.mouseExited(with: event)
        }
        guard pointerInside, containsPointer() == false else { return }
        pointerInside = false
        onPointerExited?()
    }

    private func containsPointer() -> Bool? {
        guard let window else { return nil }
        let point = convert(window.convertPoint(fromScreen: mouseLocation()), from: nil)
        return trackingRect.containsInclusive(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// SwiftUI içeriğini taşıyan, ilk tıklamayı kabul eden ve pencere boyutuna karışmayan hosting view.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    /// SwiftUI'nin kendi bağlam menüsü (ör. raf öğesi) yoksa gösterilen ada menüsü.
    var fallbackMenu: (() -> NSMenu)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) desteklenmiyor") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        super.menu(for: event) ?? fallbackMenu?()
    }

    /// Çentik bölgesindeki safe-area boşluğunu yok say.
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
}
