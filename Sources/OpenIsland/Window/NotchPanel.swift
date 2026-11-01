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

    /// Yalnızca ada genişken key olabilir (kontrolcü faz değişiminde ayarlar). Kapanırken key bırakıldıktan sonra
    /// AppKit uygulamanın sıradaki key adayını seçer; panel aday kalırsa kapanmış ada odağı, kullanıcının tıkladığı
    /// uygulamadan geri alıyordu (klavyeyle açılıp dışarı tıklanınca ölçüldü).
    var acceptsKeyFocus = false
    override var canBecomeKey: Bool { acceptsKeyFocus }
    override var canBecomeMain: Bool { false }

    /// Sekme değişiminden beri key-view döngüsü bayat mı (yeni panelin platform görünümleri döngüye girmemiş olabilir).
    private var keyViewLoopIsStale = false

    /// Döngüyü hemen yeniden kurmak yerine bayat işaretler. Döngüyü yalnız klavyeyle gezinme kullanır: Tab/Shift-Tab
    /// pencereye ulaşmadan ve panel key olmadan hemen önce bir kez `recalculateKeyViewLoop()` çağrılır (AppKit'in
    /// belgelenmiş yolu; SwiftUI odak köprüsünü `_recursiveSetDefaultKeyViewLoop` ile günceller). Odak taşınmaz.
    func invalidateKeyViewLoop() {
        keyViewLoopIsStale = true
    }

    private func refreshKeyViewLoopIfStale() {
        if keyViewLoopIsStale {
            keyViewLoopIsStale = false
            recalculateKeyViewLoop()
        }
        orderPanelKeyViewsAfterRoot()
    }

    /// Kök SwiftUI host'u key-view halkasına önce platform görünümlerini (panel sahnesi dahil), sonra kendi odak vekillerini
    /// (başlık düğmeleri) koyar; tabanda panel öğeleri başlıktan sonra gelir. Sahne bölümü halkanın sonuna, son kök
    /// vekilinden sonraya taşınır: Tab sırası başlık → panel → (başa dön), Shift-Tab tersi. Yalnız `nextKeyView` bağları
    /// değişir; SwiftUI halkayı yeniden kurarsa bir sonraki Tab'da yeniden uygulanır.
    private func orderPanelKeyViewsAfterRoot() {
        guard let start = contentView else { return }
        var cycle: [NSView] = []
        var view: NSView? = start
        while let current = view, cycle.count < 400 {
            if !cycle.isEmpty && current === start { break }
            if cycle.contains(where: { $0 === current }) { return } // halka başa dönmüyor: dokunma
            cycle.append(current)
            view = current.nextKeyView
        }
        guard view === start else { return }
        func inStage(_ view: NSView) -> Bool {
            var node: NSView? = view
            while let current = node {
                if current is PanelStageView { return true }
                if current.subviews.contains(where: { $0 is PanelStageView }) { return true } // sahnenin SwiftUI kabı
                node = current.superview
            }
            return false
        }
        guard let first = cycle.firstIndex(where: inStage), first > 0 else { return }
        var last = first
        while last + 1 < cycle.count, inStage(cycle[last + 1]) { last += 1 }
        guard last + 1 < cycle.count, !cycle[(last + 1)...].contains(where: inStage) else { return } // zaten sonda
        cycle[first - 1].nextKeyView = cycle[last + 1]
        cycle[cycle.count - 1].nextKeyView = cycle[first]
        cycle[last].nextKeyView = start
    }

    /// SwiftUI odağı bir panel host'unun içindeyken (ilk yanıtlayıcı host'un odak vekili ya da host'un kendisi) odaklı
    /// öğe o host'tan alınır: host erişilebilirlikte görünmez olduğu için AppKit odaklı öğeyi en yakın görünür ataya, kök
    /// "OpenIsland" kapsayıcısına bağlıyordu (öğenin kendi `AXFocused`'ı doğruyken). İlk yanıtlayıcı gerçek bir AppKit
    /// denetimi ya da metin görünümüyse (açılır düğme, metin düzenleyici) AppKit'in çözümü doğrudur.
    override var accessibilityFocusedUIElement: Any? {
        // Erişilebilirlik sorguları ana thread'de gelir.
        nonisolated(unsafe) var focused: Any?
        MainActor.assumeIsolated {
            guard let responder = firstResponder as? NSView, !(responder is NSControl), !(responder is NSText) else { return }
            var node: NSView? = responder
            while let current = node {
                if let host = current as? PanelHostingView { focused = host.accessibilityFocusedUIElement; return }
                node = current.superview
            }
        }
        return focused ?? super.accessibilityFocusedUIElement
    }

    override func sendEvent(_ event: NSEvent) {
        #if OPENISLAND_DENEY
        // Opt-in diagnostics only; no tracking or formatting in normal use.
        if FrameDriver.isLogging, event.type == .leftMouseDown || event.type == .keyDown {
            let hit = contentView?.hitTest(event.locationInWindow)
            FrameDriver.note("input type=\(event.type) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") key=\(isKeyWindow) canKey=\(canBecomeKey) first=\(firstResponder.map { String(describing: type(of: $0)) } ?? "nil") needsPanel=\(hit?.needsPanelToBecomeKey ?? false)")
        }
        #endif
        #if OPENISLAND_DENEY
        if NativeEditingCommands.route(event, in: self) { return }
        #endif
        // 48 = Tab (kVK_Tab); Shift/Control ile birlikte de aynı tuş kodu.
        if event.type == .keyDown, event.keyCode == 48 { refreshKeyViewLoopIfStale() }
        super.sendEvent(event)
    }

    override func becomeKey() {
        refreshKeyViewLoopIfStale()
        super.becomeKey()
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// Ada kapanırken klavye odağını, önceki uygulamaya geri verir.
    func relinquishKeyFocus() {
        guard isKeyWindow, !QuickLookController.shared.isPreviewing else { return }
        // Kaldırılan içerikteki (ör. metin alanı) bayat first responder'ı bırakma.
        makeFirstResponder(nil)
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

    /// Algılayıcı yalnız fare yönlendirmesi içindir; erişilebilirlikte görünmez. Üstteki görünmez pencere VoiceOver'ın
    /// "işaretçi altındaki öğe" sorgusunu yakalayıp içi boş bir pencere okutuyordu. İsabet sorgusu görsel adaya iletilir.
    /// Pencere öğe olarak kalırsa VoiceOver adaya geçerken bu boş "sistem sorgu kutusu"na düşüp içinde kalıyor.
    /// (Tam Klavye Erişimi'ndeki Tab takılması bu gizlemeden değil, pencere düzeyindeki layoutChanged bildiriminden geliyordu.)
    weak var accessibilityTarget: NSWindow?
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { nil }
    // Erişilebilirlik sorguları ana iş parçacığında gelir; başka iş parçacığından gelen sorgu yanıtsız kalır.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { accessibilityTarget }?.accessibilityHitTest(point)
    }
}

final class SensorView: NSView {
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { window as? NotchSensorPanel }?.accessibilityHitTest(point)
    }
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
