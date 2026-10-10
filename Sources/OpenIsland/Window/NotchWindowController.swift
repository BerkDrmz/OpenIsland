import AppKit
import IslandCore
import SwiftUI

/// Bir ekran için görsel panel + girdi sensörü + view model üçlüsünü yönetir.
///
/// **Neden iki pencere?** Önceki sürümde tek pencere hover'da büyüyüp yay durunca küçülüyordu.
/// WindowServer yeni çerçeveyi anında uygularken SwiftUI içeriği bir kare sonra yeniden yerleştiği için
/// o karede ada yeni sol kenara göre çiziliyor ve sağa zıplayıp geri geliyordu. Şimdi:
///
/// - **Görsel panel** sabit bir tuvaldir; ekran değişimi dışında **hiç** `setFrame` almaz. Tüm morph
///   Core Animation'dadır ve ada, çift genişlikli tuvalin tam ortasında (= çentik merkezi) çizilir.
/// - **Sensör** görünmez ve yalnızca dinlenmedeki ada kadardır; boyutu değişse bile ekranda titreme
///   yaratacak bir çizim yoktur.
///
/// Girdi yönlendirmesi:
/// | Durum | Sensör | Görsel panel |
/// |---|---|---|
/// | Dinlenme (idle/compact, HUD/bildirim dahil) | fareyi alır | fareyi geçirir |
/// | Yükseltilmiş, imleç içeride veya sürükleme sürüyor | geçirir | alır (hover çıkışı tracking area ile) |
/// | Yükseltilmiş, imleç dışarıda (tolerans / pin / kilit / demo) | açık adanın hover alanını kaplar, yeniden girişi yakalar | geçirir; yalnızca dış tıklama için global `mouseDown` |
///
/// Son satırda sistem geneli fare hareketi izlenmez: sabitlenmiş adada imleç başka yerde gezinirken uygulama
/// uyanmaz (önceki global `mouseMoved` izleyicisi 60 Hz harekette sürekli %1,2–1,5 CPU harcıyordu).
@MainActor
final class NotchWindowController {
    private(set) var screen: NotchScreen
    let model: IslandViewModel
    let panel = NotchPanel()
    let sensor = NotchSensorPanel()
    /// Ada genişlediğinde (ör. pano geçmişini tazelemek için).
    var onExpanded: (() -> Void)?

    private let shelf: ShelfStore
    private let preferences: Preferences
    private let container: IslandContainerView
    private let contextMenu: IslandContextMenu
    private var targetLayout: IslandLayout
    private var isPointerInside = false
    /// Yalnızca "yükseltilmiş + imleç dışarıda" iken: dış tıklama izleyicileri (global + yerel `leftMouseDown`).
    private var outsideClickMonitors: [Any] = []
    /// "Her zaman gizle" + tam ekran: ada hover/tıklama ile açılmaz (sensör kapalı).
    private var interactionBlocked = false

    init(screen: NotchScreen, environment: AppEnvironment) {
        self.screen = screen
        shelf = environment.shelf
        preferences = environment.preferences
        let model = IslandViewModel(metrics: Self.metrics(for: screen, preferences: environment.preferences),
                                    configuration: environment.preferences.islandConfiguration)
        model.hapticsEnabled = environment.preferences.hapticsEnabled
        model.motionStyle = environment.preferences.motionStyle
        self.model = model
        targetLayout = model.layout
        let contextMenu = IslandContextMenu(model: model, environment: environment)
        self.contextMenu = contextMenu
        let hosting = IslandHostingView(rootView: IslandRootView(model: model, environment: environment))
        hosting.fallbackMenu = { contextMenu.make() }
        container = IslandContainerView(content: hosting)

        panel.contentView = container
        panel.onEscape = { [weak model] in model?.send(.escapePressed) }
        container.onPointerEntered = { [weak self] in self?.pointerDidEnter() }
        container.onPointerExited = { [weak self] in self?.pointerDidExit() }
        wireSensor()
        contextMenu.onClose = { [weak self] in self?.reconcilePointerExit() }
        model.onPhaseChange = { [weak self] old, new in self?.phaseDidChange(from: old, to: new) }
        model.onLayoutChange = { [weak self] layout in self?.layoutDidChange(to: layout) }

        placeWindows()
        panel.orderFrontRegardless()
        sensor.orderFrontRegardless()
        SpacePresentationController.shared.attach([panel, sensor])
        updateInputRouting()

        if let diagnostics = IslandDiagnostics.shared {
            model.onRenderedFrame = { [weak self] rect in
                guard let self else { return }
                // Hosting view çevrilmiş (sol-üst) koordinat kullanır; ekran koordinatına çevir.
                let frame = self.panel.frame
                diagnostics.recordRendered(CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY,
                                                  width: rect.width, height: rect.height))
            }
        }
    }

    func update(screen: NotchScreen) {
        self.screen = screen
        var metrics = Self.metrics(for: screen, preferences: preferences)
        metrics.content = model.metrics.content
        model.metrics = metrics
        targetLayout = model.layout
        placeWindows()
        // Ekran eklendi/çıkarıldı, çözünürlük değişti veya uyanıldı: birincil sağlayıcıyla yeniden kurulup doğrulanır.
        SpacePresentationController.shared.attach([panel, sensor])
        updateInputRouting()
    }

    /// Preferences do not change Space membership. Only changed geometry updates the canvas/tracking area.
    func applyPreferences() {
        var metrics = Self.metrics(for: screen, preferences: preferences)
        metrics.content = model.metrics.content
        guard metrics != model.metrics else { return }
        model.metrics = metrics
        targetLayout = model.layout
        placeWindows()
        updateInputRouting()
    }

    /// Ekran ölçüleri ve içerik düzeni: ayarlar mevcut Space bağlantısı korunarak uygulanır.
    private static func metrics(for screen: NotchScreen, preferences: Preferences) -> NotchMetrics {
        var metrics = screen.metrics
        metrics.nookWidgetCount = preferences.nookLayout.widgetCount
        metrics.expandedSurfaceSize = preferences.expandedSurfaceSize
        return metrics
    }

    /// Genişletilmiş görünümlerin içerik miktarı (pano, raf, etkinlik…): görünür gövde içerik kadar büyür.
    func setContent(_ content: ExpandedContent) {
        guard model.metrics.content != content else { return }
        model.updateContent(content)
        layoutDidChange(to: model.layout)
    }

    func close() {
        model.cancelPendingEffects()
        stopOutsideClickMonitor()
        SpacePresentationController.shared.detach([panel, sensor])
        panel.orderOut(nil)
        sensor.orderOut(nil)
        panel.close()
        sensor.close()
    }

    /// Tam ekran bilgisi: Akıllı modda makine canlı etkinlikleri gizler ama hover çalışır;
    /// "Her zaman gizle"de ayrıca girdi sensörü kapatılır.
    func setFullscreen(_ isFullscreen: Bool, behavior: FullscreenBehavior) {
        let hides = isFullscreen && behavior != .alwaysShow
        model.send(.fullscreenChanged(isFullscreen: hides))
        interactionBlocked = isFullscreen && behavior == .alwaysHide
        if interactionBlocked, model.machine.isExpanded { model.send(.escapePressed) }
        refreshTrackingArea()
        updateInputRouting()
    }

    /// Klavye kısayolu: imleç olmadan aç/kapat. Açılınca panel key olur, Esc ile kapanır.
    func toggleFromKeyboard() {
        if model.machine.isExpanded {
            model.send(.escapePressed)
        } else {
            model.send(.tapped)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Geometri

    /// Adanın merkezi: donanım çentiğinin (veya ekranın) piksel hizalı yatay merkezi.
    private var centerX: CGFloat { screen.anchor.x }

    /// Adanın dikdörtgeni, global ekran koordinatlarında. Genişlik çift nokta olduğu için
    /// `centerX ± width/2` iki kenar da tam piksele düşer: genişleme iki yana birebir simetriktir.
    private func islandRect(for layout: IslandLayout) -> CGRect {
        CGRect(
            x: centerX - layout.size.width / 2,
            y: screen.frame.maxY - layout.topInset - layout.size.height,
            width: layout.size.width,
            height: layout.size.height
        )
    }

    /// Hover/tıklama bölgesi.
    /// - Notch: üst kenar ekranın tepesine uzatılır (Fitts yasası). Çentik bandında menü öğesi olamaz.
    /// - Pill: yalnızca kapsülün kendisi (+4 pt). Menü çubuğu bandına uzatılmaz; aksi halde menü
    ///   çubuğunun ortasındaki öğelerin (uzun uygulama menüleri) tıklamaları yutulurdu.
    private func hitRect(for layout: IslandLayout) -> CGRect {
        var rect = islandRect(for: layout)
        if screen.hasNotch {
            rect.size.height = screen.frame.maxY - rect.minY
        } else {
            rect = rect.insetBy(dx: -4, dy: -4)
        }
        return rect
    }

    /// Sensörün boyutu: HUD/bildirim gibi geçici katmanlar değil, dinlenme fazının kendisi.
    /// Böylece geçici genişlemeler menü çubuğu öğelerinin tıklamalarını engellemez.
    /// WindowServer pencere çerçevesini tam noktaya yuvarladığı için (762,5 → 762,0) dikdörtgen dışa
    /// doğru tam noktaya genişletilir: iki kenar da .5 olduğundan genişleme simetrik kalır (762…948).
    private var restHitRect: CGRect {
        hitRect(for: IslandLayoutEngine.layout(for: model.machine.basePresentation, metrics: model.metrics)).integral
    }

    /// Yalnızca gerçekten değiştiyse çerçeve atanır: ayar değişiklikleri (ör. kaydırıcı) her adımda
    /// tüm tuvali yeniden çizdirmez.
    private func placeWindows() {
        let canvas = IslandLayoutEngine.canvasSize(for: model.metrics)
        let panelFrame = CGRect(x: centerX - canvas.width / 2, y: screen.frame.maxY - canvas.height,
                                width: canvas.width, height: canvas.height)
        if panel.frame != panelFrame { panel.setFrame(panelFrame, display: true) }
        let sensorFrame = restHitRect
        if sensor.frame != sensorFrame { sensor.setFrame(sensorFrame, display: false) }
        refreshTrackingArea()
    }

    // MARK: - Yerleşim değişimleri (pencere boyutu değişmez)

    private func layoutDidChange(to layout: IslandLayout) {
        targetLayout = layout
        if !model.machine.isEngaged {
            let rect = restHitRect
            if sensor.frame != rect { sensor.setFrame(rect, display: false) }
        }
        refreshTrackingArea()
        updateInputRouting()
    }

    private func refreshTrackingArea() {
        let rect = hitRect(for: targetLayout)
        container.setTrackingRect(container.convert(panel.convertFromScreen(rect), from: nil),
                                  pointerInside: isPointerInside && rect.containsInclusive(NSEvent.mouseLocation))
        reconcilePointerExit()
    }

    /// Yüzey veya girdi yönlendirmesi değişirken AppKit çıkış üretmeyebilir; yalnızca bu olaylarda
    /// (olay güdümlü) bir kez doğrulanır. Girişler asla buradan üretilmez: HUD veya bildirim duran bir
    /// imlecin altında genişlediğinde ada kendiliğinden açılmamalı.
    func reconcilePointerExit() {
        guard isPointerInside, !hitRect(for: targetLayout).containsInclusive(NSEvent.mouseLocation) else { return }
        pointerDidExit()
    }

    // MARK: - Girdi yönlendirmesi

    private func updateInputRouting() {
        let machine = model.machine
        let dragActive = machine.context.isFileDragActive
        let engaged = machine.isEngaged || dragActive
        let panelAccepts = engaged && (isPointerInside || dragActive)
        // Yükseltilmiş + imleç dışarıda: yeniden girişi sensörün kendi tracking area'sı yakalar (olay yalnızca
        // sınır geçişinde); sensör bu sürede açık adanın hover alanını kaplar.
        let watchesReentry = engaged && !panelAccepts && !interactionBlocked
        if watchesReentry {
            let rect = hitRect(for: targetLayout).integral
            if sensor.frame != rect { sensor.setFrame(rect, display: false) }
        }

        let sensorIgnores = (engaged && !watchesReentry) || interactionBlocked
        if sensor.ignoresMouseEvents != sensorIgnores { sensor.ignoresMouseEvents = sensorIgnores }
        if panel.ignoresMouseEvents == panelAccepts { panel.ignoresMouseEvents = !panelAccepts }
        if watchesReentry { startOutsideClickMonitor() } else { stopOutsideClickMonitor() }
    }

    private func pointerDidEnter() {
        guard !isPointerInside else { return }
        isPointerInside = true
        updateInputRouting()
        model.send(.pointerEntered)
    }

    private func pointerDidExit() {
        guard isPointerInside else { return }
        isPointerInside = false
        updateInputRouting()
        model.send(.pointerExited)
    }

    private func phaseDidChange(from old: IslandPhase, to new: IslandPhase) {
        let wasExpanded = if case .expanded = old { true } else { false }
        if wasExpanded, !model.machine.isExpanded { panel.relinquishKeyFocus() }
        if !wasExpanded, model.machine.isExpanded { onExpanded?() }
        if !model.machine.isEngaged, sensor.frame != restHitRect { sensor.setFrame(restHitRect, display: false) }
        refreshTrackingArea()
        updateInputRouting()
    }

    // MARK: - Sensör

    private func wireSensor() {
        let view = sensor.sensorView
        view.onPointerEntered = { [weak self] in
            guard let self else { return }
            let isReentry = self.model.machine.isEngaged
            let rect = isReentry ? self.hitRect(for: self.targetLayout) : self.sensor.frame
            guard rect.containsInclusive(NSEvent.mouseLocation) else { return }
            self.pointerDidEnter()
            // Yükseltilmiş adaya sensör üzerinden geri dönüldü: panelin hover alanı "imleç içeride" varsayımıyla
            // yenilenir, sonraki çıkış oradan gelir.
            if isReentry { self.refreshTrackingArea() }
        }
        view.onPointerExited = { [weak self] in
            // The sensor may have queued this exit just before input moved to the visual panel.
            // Keep it if the pointer really left; crossing only the old sensor edge is not an exit.
            guard let self, !self.hitRect(for: self.targetLayout).containsInclusive(NSEvent.mouseLocation) else { return }
            self.pointerDidExit()
        }
        view.onClick = { [weak self] in self?.model.send(.tapped) }
        view.onContextMenu = { [weak self, weak view] event in
            guard let self, let view else { return }
            NSMenu.popUpContextMenu(self.contextMenu.make(), with: event, for: view)
        }
        view.onDragEntered = { [weak self] in self?.model.send(.fileDragEntered) }
        view.onDragExited = { [weak self] in
            // Ada drop hedefine dönüşünce sürükleme görsel panele devredilir; o durumda sensörden
            // gelen çıkış bir "vazgeçme" değildir.
            guard let self, !self.hitRect(for: self.targetLayout).containsInclusive(NSEvent.mouseLocation) else { return }
            self.model.send(.fileDragExited)
        }
        view.onDrop = { [weak self] pasteboard in
            guard let self else { return false }
            let accepted = self.shelf.ingest(pasteboard: pasteboard)
            self.model.send(.fileDragEnded(dropped: accepted))
            return accepted
        }
    }

    // MARK: - Dış tıklama izleyicisi (yalnızca "yükseltilmiş + imleç dışarıda")

    /// Yalnızca tıklamada uyanır; fare hareketi dinlenmez (yeniden giriş sensörün işidir).
    private func startOutsideClickMonitor() {
        guard outsideClickMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handleClick(at: location) }
        }) {
            outsideClickMonitors.append(global)
        }
        // Uygulamanın kendi pencerelerine (ör. Ayarlar) yapılan tıklamalar global izleyiciye gelmez.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handleClick(at: location) }
            return event
        }) {
            outsideClickMonitors.append(local)
        }
    }

    private func stopOutsideClickMonitor() {
        guard !outsideClickMonitors.isEmpty else { return }
        outsideClickMonitors.forEach(NSEvent.removeMonitor)
        outsideClickMonitors.removeAll()
    }

    private func handleClick(at location: CGPoint) {
        if hitRect(for: targetLayout).containsInclusive(location) {
            pointerDidEnter() // tracking area girişinden önce gelen tıklama: adaya dönülmüş sayılır
        } else {
            model.send(.tappedOutside)
        }
    }
}
