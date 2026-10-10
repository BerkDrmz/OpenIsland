import IslandCore
import SwiftUI
import UniformTypeIdentifiers

/// Adanın kök görünümü.
///
/// Katman düzeni — iki ayrı görünüm açılıp kapanmaz, **tek bir yüzey** morph eder:
/// 1. `IslandSurface`: saf siyah gövde; boyutu ve köşe yarıçapları yay ile animasyonlanır.
/// 2. Durum içeriği: her durumun içeriği kendi **sabit** boyutunda yerleşir ve büyüyen yüzey tarafından
///    kırpılarak "açığa çıkar" (içerik animasyon sırasında yeniden akmaz / sıkışmaz).
/// 3. Kalıcı medya katmanları: albüm kapağı ve dalga biçimi durumlar arasında yok olup yeniden
///    oluşmaz; aynı yay ile kompakt kanattan panele akar.
/// 4. Cam kenar ışığı ve gölge yalnızca pill (yüzen kapsül) stilinde görünür. Notch'ta açık ada da çentiğin
///    gölgesiz, kenar ışıksız devamıdır (Revizyon 18); bu katmanlar orada sıfır yoğunlukta kalır.
struct IslandRootView: View {
    let model: IslandViewModel
    let environment: AppEnvironment
    @State private var dropZone: DropZone?
    @State private var surface: IslandSurfaceState
    @State private var pendingOpening: DispatchWorkItem?
    @Environment(\.openSettings) private var openSettings

    init(model: IslandViewModel, environment: AppEnvironment) {
        self.model = model
        self.environment = environment
        _surface = State(initialValue: IslandSurfaceState(layout: model.layout, presentation: model.presentation))
    }

    var body: some View {
        let layout = model.layout
        let presentation = model.presentation
        let target = IslandSurfaceState(layout: layout, presentation: presentation)
        let metrics = model.metrics
        let canvas = IslandLayoutEngine.canvasSize(for: metrics)
        let shape = IslandCanvasShape(surfaceSize: surface.layout.size, shape: IslandShape(
            style: metrics.style, topRadius: surface.layout.topCornerRadius, bottomRadius: surface.layout.bottomCornerRadius))

        IslandStateContent(presentation: presentation, expandedIsVisible: surface.presentation.isExpanded,
                           model: model, environment: environment, dropZone: dropZone)
            // Content keeps its own settled proposal while only the outer surface morphs.
            .fixedSize()
            .frame(width: canvas.width, height: canvas.height, alignment: .top)
            .overlay(alignment: .topLeading) {
                MediaLayers(presentation: surface.presentation, metrics: metrics, media: environment.media,
                            albumColoredPulse: environment.preferences.albumColoredPulse)
                    .offset(x: (canvas.width - surface.layout.size.width) / 2)
            }
            .clipShape(shape)
            .background {
                IslandSurface(shape: shape.recordingGeometry(IslandDiagnostics.shared?.surfaceRecorder,
                                                             topInset: surface.layout.topInset), elevation: surface.layout.elevation,
                              shadowClearance: metrics.style == .notch ? metrics.notchSize.height : 0)
            }
            .overlay { IslandEdgeHighlight(shape: shape, intensity: surface.layout.edgeHighlight) }
            .contentShape(shape)
            // Açıkken dokunma jesti devre dışı: TextEditor ve düğmeler olayları doğrudan alır.
            .gesture(TapGesture().onEnded { model.send(.tapped) }, including: presentation.isExpanded ? .subviews : .all)
            .onDrop(of: ShelfStore.acceptedTypes, delegate: IslandDropDelegate(model: model, shelf: environment.shelf, zone: $dropZone))
            .environment(\.islandMotionStyle, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .reduced : model.motionStyle)
            .environment(\.islandEnergySaving, model.energySaving)
            .modifier(IslandRelaxation(model: model))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("OpenIsland")
            .accessibilityHint(presentation.isExpanded ? "Kapatmak için Escape" : "Genişletmek için etkinleştirin")
            .accessibilityAction(named: "Genişlet") { model.send(.tapped) }
            .accessibilityAction(.escape) { model.send(.escapePressed) }
            .padding(.top, surface.layout.topInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .environment(\.colorScheme, .dark)
            .onAppear { [openSettings] in
                environment.settingsAction = { openSettings() }
                surface = target
            }
            .onChange(of: target) { _, next in morph(to: next) }
            .onDisappear { pendingOpening?.cancel(); pendingOpening = nil }
    }

    private func morph(to target: IslandSurfaceState) {
        pendingOpening?.cancel()
        pendingOpening = nil
        let update = {
            let style = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? MotionStyle.reduced : model.motionStyle
            withAnimation(IslandMotion.morph(from: surface.presentation, to: target.presentation, style: style)) {
                surface = target
            }
            pendingOpening = nil
        }
        if target.presentation.isExpanded && !surface.presentation.isExpanded {
            // Mount and lay out destination content first, then start a fresh spring clock.
            // No timed delay: hover, closing and retargeting still update synchronously.
            let work = DispatchWorkItem(block: update)
            pendingOpening = work
            DispatchQueue.main.async(execute: work)
        } else {
            update()
        }
    }
}

private struct IslandSurfaceState: Equatable {
    let layout: IslandLayout
    let presentation: IslandPresentation
}

/// Duruma göre içerik. Kimlik (identity) içerik türüne bağlıdır: `compact(x)` ile `peek(x)` aynı
/// görünümü paylaşır, böylece hover'da içerik değişmez — yalnızca yüzey kabarır.
private struct IslandStateContent: View {
    @Environment(\.islandMotionStyle) private var motionStyle
    let presentation: IslandPresentation
    let expandedIsVisible: Bool
    let model: IslandViewModel
    let environment: AppEnvironment
    let dropZone: DropZone?

    var body: some View {
        let metrics = model.metrics
        ZStack(alignment: .top) {
            switch presentation {
            case .idle, .peek(.none):
                Color.clear.frame(width: 0, height: 0)

            case .compact(let activity), .peek(let activity?):
                CompactActivityView(activity: activity, metrics: metrics, environment: environment)
                    .id(activity)
                    .transition(.islandReveal(motionStyle))

            case .hud(let payload):
                HUDCompactView(payload: payload, metrics: metrics)
                    .transition(.islandReveal(motionStyle))

            case .notice(.unlocked):
                UnlockNoticeView(metrics: metrics)
                    .transition(.islandReveal(motionStyle))

            case let .notice(.audioOutput(name, kind, connected)):
                AudioConnectionNoticeView(name: name, kind: kind, connected: connected, metrics: metrics)
                    .id(model.notice)
                    .transition(.islandReveal(motionStyle))

            case .notice(let notice):
                NoticeView(notice: notice, metrics: metrics)
                    .id(notice)
                    .transition(.islandReveal(motionStyle))

            case .dropTarget:
                DropZoneView(zone: dropZone, metrics: metrics)
                    .transition(.islandReveal(motionStyle))

            case .expanded(let tab):
                ExpandedIslandView(tab: tab, model: model, environment: environment)
                    // Reveal only when the prepared surface starts moving. The content uses
                    // the preview's opacity timing without an additional blur pass.
                    .opacity(expandedIsVisible ? 1 : 0)
                    .animation(motionStyle == .expressive ? IslandMotion.livelyContentIn : IslandMotion.contentIn,
                               value: expandedIsVisible)
                    .allowsHitTesting(expandedIsVisible)
                    .transition(.asymmetric(insertion: .identity,
                        removal: .opacity.animation(motionStyle == .expressive ? IslandMotion.livelyContentOut : IslandMotion.contentOut)))
            }
        }
    }
}

/// Albüm kapağı ve müzik nabzı: durumlar arasında kimliğini koruyan kalıcı katmanlar.
/// Yerleri `IslandLayoutEngine` yuvalarından gelir ve yüzeyle aynı transaction'da animasyonlanır.
private struct MediaLayers: View {
    @Environment(\.islandMotionStyle) private var motionStyle
    let presentation: IslandPresentation
    let metrics: NotchMetrics
    let media: MediaController
    let albumColoredPulse: Bool

    var body: some View {
        let hasMedia = media.nowPlaying != nil
        let pulseColor = albumColoredPulse ? (media.pulseNSColor ?? IslandPalette.pulseNSColor) : IslandPalette.pulseNSColor
        ZStack(alignment: .topLeading) {
            if hasMedia, let slot = IslandLayoutEngine.artworkSlot(for: presentation, metrics: metrics) {
                ArtworkView(image: media.artwork, cornerRadius: slot.cornerRadius)
                    .shadow(color: media.accentColor.opacity(presentation.isExpanded ? 0.3 : 0), radius: 12, y: 4)
                    .frame(width: slot.rect.width, height: slot.rect.height)
                    .offset(x: slot.rect.minX, y: slot.rect.minY)
                    .transition(.islandReveal(motionStyle))
                    .accessibilityElement()
                    .accessibilityLabel(nowPlayingLabel)
            }
            if hasMedia, let rect = IslandLayoutEngine.waveformSlot(for: presentation, metrics: metrics) {
                // Müzik ritmi tahminidir: ses kaydedilmez veya analiz edilmez.
                WaveformView(isPlaying: media.isPlaying, color: pulseColor)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .transition(.islandReveal(motionStyle))
                .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
    }

    private var nowPlayingLabel: String {
        guard let info = media.nowPlaying else { return "" }
        return "Şimdi çalıyor: \(info.title)" + (info.artist.isEmpty ? "" : ", \(info.artist)")
    }
}

// MARK: - Sürükle-bırak

enum DropZone: Equatable {
    case shelf, airDrop
}

/// Adanın tek drop hedefi (native `NSDraggingDestination` üzerinden). Global fare izleyicisi yok:
/// sürükleme ada penceresine girdiğinde sistem bu delegeyi çağırır.
private struct IslandDropDelegate: DropDelegate {
    let model: IslandViewModel
    let shelf: ShelfStore
    @Binding var zone: DropZone?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: ShelfStore.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        model.send(.fileDragEntered)
        zone = zone(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let current = zone(at: info.location)
        if current != zone { withAnimation(IslandMotion.control) { zone = current } }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        zone = nil
        model.send(.fileDragExited)
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = zone(at: info.location)
        let providers = info.itemProviders(for: ShelfStore.acceptedTypes)
        zone = nil
        if target == .airDrop {
            let shelf = shelf
            ShelfStore.loadFileURLs(from: providers) { urls in shelf.airDrop(urls) }
            model.send(.fileDragEnded(dropped: false))
            return true
        }
        let accepted = shelf.ingest(providers)
        model.send(.fileDragEnded(dropped: accepted))
        return accepted
    }

    /// Drop hedefi görünümünde sol yarı raf, sağ yarı AirDrop; diğer durumlarda her zaman raf.
    private func zone(at location: CGPoint) -> DropZone {
        guard model.presentation == .dropTarget else { return .shelf }
        return location.x < IslandLayoutEngine.canvasSize(for: model.metrics).width / 2 ? .shelf : .airDrop
    }
}

/// Read relaxation in the modifier so this small transform does not invalidate the root content.
private struct IslandRelaxation: ViewModifier {
    let model: IslandViewModel

    func body(content: Content) -> some View {
        content.scaleEffect(model.isRelaxing ? IslandMotion.relaxScale : 1, anchor: .top)
    }
}
