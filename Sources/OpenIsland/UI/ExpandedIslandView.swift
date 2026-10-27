import IslandCore
import SwiftUI

extension ExpandedTab {
    var symbol: String {
        switch self {
        case .nook: "square.grid.2x2.fill"
        case .media: "music.note"
        case .shelf: "tray.and.arrow.down.fill"
        case .clipboard: "doc.on.clipboard"
        case .focus: "stopwatch"
        case .notes: "note.text"
        case .mirror: "person.crop.circle"
        case .system: "cpu"
        case .mixer: "slider.horizontal.3"
        }
    }

    var title: String {
        switch self {
        case .nook: "Nook"
        case .media: "Medya"
        case .shelf: "Raf"
        case .clipboard: "Pano"
        case .focus: "Odak"
        case .notes: "Notlar"
        case .mirror: "Ayna"
        case .system: "Sistem"
        case .mixer: "Ses Mikseri"
        }
    }
}

/// Genişletilmiş ada: çentiğin iki yanına yerleşen sekmeler + sekme içeriği.
///
/// Görünüm kendi durumunun **sabit** boyutunda yerleşir (`IslandLayoutEngine`); yüzey büyürken içerik
/// yeniden akmaz, yalnızca açığa çıkar. İçerik kenar boşlukları gövdeyle eş-merkezli yuvalarla
/// aynı ölçülerden türetilir; böylece kalıcı albüm kapağı katmanı `MediaPanel`'deki yere oturur.
struct ExpandedIslandView: View {
    @Environment(\.islandMotionStyle) private var motionStyle
    @Environment(\.islandEnergySaving) private var energySaving
    let tab: ExpandedTab
    let model: IslandViewModel
    let environment: AppEnvironment
    @Namespace private var tabSelection

    var body: some View {
        let metrics = model.metrics
        let layout = IslandLayoutEngine.layout(for: .expanded(tab), metrics: metrics)
        let side = IslandLayoutEngine.contentSideInset(for: layout, style: metrics.style, size: metrics.expandedSurfaceSize)
        let visible = environment.preferences.visibleTabs
        let headerPadding = IslandLayoutEngine.headerSidePadding(style: metrics.style, size: metrics.expandedSurfaceSize)
        // Görünüm tuval genişliğinde sabit kalır ve tuvalde ortalanır; gövde (içerik + HUD) ortada morph eder.
        let frameWidth = max(IslandLayoutEngine.canvasSize(for: metrics).width, layout.size.width)
        let headerPlacement = HeaderPlacement(bodyWidth: layout.size.width, boxWidth: frameWidth, padding: headerPadding,
                                              metrics: metrics, visible: visible)

        ZStack(alignment: .top) {
            // Başlık satırı gövdenin morph eden çerçevesinin dışında, sabit kutuda: sekme geçişinde düğmelerin
            // yerleşimi değişmez (her yay karesinde satır, odak döngüsü, izleme alanları yeniden kurulmaz).
            // Dar gövdelerde özgün yığının ürettiği kayma, aynı transaction'da canlanan ofsetle birebir üretilir.
            // Kaymanın yerleşimi (odak, erişilebilirlik, isabet) tek adımda geçer; düğme etiketleri aynı animasyonla
            // kayar (`layoutWithoutAnimation`). Ölçüldü: canlanan yerleşim, odaklanabilir düğmeleri her yay karesinde
            // taşıdığı için SwiftUI her karede bütün key-view döngüsünü ve odak vekillerini yeniden kuruyordu.
            header(metrics: metrics, visible: visible)
                .padding(.horizontal, headerPadding)
                .frame(width: headerPlacement.boxWidth, height: metrics.notchSize.height)
                .offset(x: headerPlacement.shift)
                .layoutWithoutAnimation()

            // Sekme içerikleri kalıcı host'larda (`PanelStage`); sahne sabit dış çerçeveyi kaplar. Ağaçta başlıktan sonra ve
            // HUD'dan önce gelir: erişilebilirlik sırası tabandaki gibi başlık, panel, HUD; HUD panelin üstünde çizilir,
            // host'lar başlık bölgesiyle örtüşmez.
            // İçerik dikdörtgeni özgün iç yığının yerleşimiyle aynıdır: yığın genişliği gövde ile görünmez başlık
            // iskeletinin büyüğüdür (dar gövdelerde iskelet taşar ve içerik bu genişlikte ortalanır).
            let stackWidth = max(layout.size.width, headerPlacement.skeletonWidth)
            PanelStage(
                tab: tab,
                contentRect: CGRect(
                    x: (frameWidth - stackWidth) / 2 + side,
                    y: metrics.notchSize.height + IslandLayoutEngine.headerGap,
                    width: stackWidth - 2 * side,
                    height: layout.size.height - metrics.notchSize.height - IslandLayoutEngine.headerGap
                        - IslandLayoutEngine.expandedBottomInset(for: metrics)),
                motionStyle: motionStyle, energySaving: energySaving,
                inputs: metrics,
                make: { item in AnyView(content(for: item, metrics: metrics)) }
            )
            .frame(width: frameWidth, height: IslandLayoutEngine.canvasSize(for: metrics).height, alignment: .top)
            .frame(width: frameWidth, height: layout.size.height, alignment: .top)

            ZStack(alignment: .top) {
                // Görünmez, etkileşimsiz iskelet: özgün yapıda başlık bu yığının içindeydi ve dar gövdelerde gövdeden
                // geniş ölçülerek içeriğin önerilen genişliğini belirliyordu. İskelet aynı yerleşimi korur.
                HeaderSkeleton(visible: visible, gap: Self.headerCenterGap(metrics))
                    .padding(.horizontal, headerPadding)
                    .frame(height: metrics.notchSize.height)
                    .hidden()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)

                HUDBannerHost(model: model)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, IslandSpacing.s)
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
        }
        .frame(width: frameWidth, height: layout.size.height, alignment: .top)
        .foregroundStyle(IslandPalette.primary)
        .compositingGroup()
    }

    /// Başlık satırının kutusu ve kayması. Hızlı yol: kutu sabit (simetrik satır) + `headerRowShift`. Kayma piksel
    /// düzeyinde garanti edilemiyorsa (ör. 1× ekran) özgün yerleşim: kutu gövde genişliğinde, kayma yok.
    private struct HeaderPlacement {
        let boxWidth: CGFloat
        let shift: CGFloat
        /// Görünmez iskeletin (dolgu dahil) yerleşim genişliği: satır sığmazsa en küçük satır genişliği.
        let skeletonWidth: CGFloat

        init(bodyWidth: CGFloat, boxWidth: CGFloat, padding: CGFloat, metrics: NotchMetrics, visible: [ExpandedTab]) {
            let tab = IslandLayoutEngine.tabButtonSize.width
            let spacing = IslandLayoutEngine.tabSpacing
            let leading = CGFloat(IslandLayoutEngine.leadingTabOrder.filter(visible.contains).count)
            let trailing = CGFloat(IslandLayoutEngine.trailingTabOrder.filter(visible.contains).count)
            let leadingRow = leading > 0 ? leading * tab + (leading - 1) * spacing : 0
            let trailingRow = trailing * (tab + spacing) + IslandIconButton.diameter(for: PinButton.iconSize)
            let gap = ExpandedIslandView.headerCenterGap(metrics)
            skeletonWidth = 2 * padding + max(bodyWidth - 2 * padding, leadingRow + gap + trailingRow)
            func shift(_ width: CGFloat) -> CGFloat? {
                IslandLayoutEngine.headerRowShift(bodyWidth: width, sidePadding: padding, centerGap: gap,
                                                  leadingRowWidth: leadingRow, trailingRowWidth: trailingRow, scale: metrics.scale)
            }
            if let bodyShift = shift(bodyWidth), shift(boxWidth) == 0 {
                self.boxWidth = boxWidth
                self.shift = bodyShift
            } else {
                self.boxWidth = bodyWidth
                self.shift = 0
            }
        }
    }

    fileprivate static func headerCenterGap(_ metrics: NotchMetrics) -> CGFloat {
        metrics.style == .notch ? metrics.notchSize.width : IslandSpacing.m
    }

    /// Tüm sekmeler her zaman doğrudan tıklanabilir ve her görünümde aynı yerde durur (çentiğe yaslı):
    /// solda Müzik, Nook, Raf, Pano, Ses Mikseri; sağda Odak, Notlar, Ayna, Sistem ve iğne. Kapalı modüllerin sekmesi gösterilmez.
    private func header(metrics: NotchMetrics, visible: [ExpandedTab]) -> some View {
        let spacing = IslandLayoutEngine.tabSpacing
        let leadingTabs = IslandLayoutEngine.leadingTabOrder.filter(visible.contains)
        let trailingTabs = IslandLayoutEngine.trailingTabOrder.filter(visible.contains)
        return HStack(spacing: 0) {
            HStack(spacing: spacing) {
                ForEach(leadingTabs, id: \.self) { item in
                    TabButton(item: item, isSelected: item == tab, namespace: tabSelection) {
                        guard item != tab else { return }
                        model.send(.selectTab(item))
                    }
                    .equatable()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            Color.clear.frame(width: Self.headerCenterGap(metrics))
            HStack(spacing: spacing) {
                ForEach(trailingTabs, id: \.self) { item in
                    TabButton(item: item, isSelected: item == tab, namespace: tabSelection) {
                        guard item != tab else { return }
                        model.send(.selectTab(item))
                    }
                    .equatable()
                }
                PinButton(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func content(for tab: ExpandedTab, metrics: NotchMetrics) -> some View {
        switch tab {
        case .nook:
            NookPanel(environment: environment, metrics: metrics)
        case .media:
            MediaPanel(media: environment.media, metrics: metrics)
        case .shelf:
            ShelfPanel(shelf: environment.shelf)
        case .clipboard:
            ClipboardPanel(history: environment.clipboard, colors: environment.colorPicker)
        case .focus:
            FocusPanel(timer: environment.focusTimer)
        case .notes:
            NotesPanel(notes: environment.notes, launcher: environment.launcher)
        case .mirror:
            MirrorPanel(mirror: environment.mirror)
        case .mixer:
            AudioMixerPanel(mixer: environment.audioMixer, settings: environment.openSettings)
        case .system:
            SystemPanel(system: environment.system)
        }
    }
}

/// Başlık satırının yalnızca yerleşimi: aynı yığın, aynı ölçüler, düğme yerine boş kutular (çizim, odak, izleme yok).
private struct HeaderSkeleton: View {
    let visible: [ExpandedTab]
    let gap: CGFloat

    var body: some View {
        let size = IslandLayoutEngine.tabButtonSize
        let pin = IslandIconButton.diameter(for: PinButton.iconSize)
        HStack(spacing: 0) {
            HStack(spacing: IslandLayoutEngine.tabSpacing) {
                ForEach(IslandLayoutEngine.leadingTabOrder.filter(visible.contains), id: \.self) { _ in
                    Color.clear.frame(width: size.width, height: size.height)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            Color.clear.frame(width: gap)
            HStack(spacing: IslandLayoutEngine.tabSpacing) {
                ForEach(IslandLayoutEngine.trailingTabOrder.filter(visible.contains), id: \.self) { _ in
                    Color.clear.frame(width: size.width, height: size.height)
                }
                Color.clear.frame(width: pin, height: pin)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Sekme butonu: Equatable ile sarmalanır; sekme değiştiğinde yalnızca durumu değişen
/// butonlar yeniden değerlendirilir, değişmeyen sekmelerin modifier zinciri atlanır.
private struct TabButton: View, Equatable {
    let item: ExpandedTab
    let isSelected: Bool
    let namespace: Namespace.ID
    let onSelect: () -> Void
    /// Yalnızca geçersiz kılma tetikleyicisi: Kontrastı Artır değişince gövde yeniden değerlendirilir ve alfa,
    /// `IslandPalette.tertiary` ile aynı kaynaktan yeniden okunur.
    @Environment(\.colorSchemeContrast) private var contrast

    nonisolated static func == (lhs: TabButton, rhs: TabButton) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected
    }

    private var unselectedAlpha: Double {
        _ = contrast
        return IslandPalette.currentTertiaryAlpha
    }

    var body: some View {
        Button(action: onSelect) {
            Image(systemName: item.symbol)
                .font(.system(size: 12, weight: .semibold))
                .modifier(TabIconTint(isSelected: isSelected, unselectedAlpha: unselectedAlpha,
                                      usesLayerOpacity: item.tintsWithLayerOpacity))
                .frame(width: IslandLayoutEngine.tabButtonSize.width, height: IslandLayoutEngine.tabButtonSize.height)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(IslandPalette.fillHover)
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .contentShape(Capsule())
                .restoringLayoutAnimation()
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Sekme ikonunun seçili/seçili değil tonu. Seçili: beyaz; değil: `IslandPalette.tertiary` ile aynı beyaz × alfa.
/// Tek katmanlı sembollerde alfa katman opaklığı olarak canlanır (aynı piksel, ancak her yay karesinde renk çözümleme
/// ve CPU'da yeniden çizim yok). Alt yolları üst üste binen sembollerde renk alfası her alt yola ayrı uygulandığı için
/// sonuç farklıdır; bunlarda özgün renk animasyonu birebir korunur.
private struct TabIconTint: ViewModifier {
    let isSelected: Bool
    let unselectedAlpha: Double
    let usesLayerOpacity: Bool

    func body(content: Content) -> some View {
        if usesLayerOpacity {
            content
                .foregroundStyle(IslandPalette.primary)
                .opacity(isSelected ? 1 : unselectedAlpha)
        } else {
            content.foregroundStyle(isSelected ? IslandPalette.primary : IslandPalette.tertiary)
        }
    }
}

private extension ExpandedTab {
    /// `Tools/PerformanceChecks/TabIconTintCheck.swift`: 2x piksel karşılaştırmasında üst üste binen alt yolları olan
    /// mixer ve pano sembolleri renk alfası ile katman opaklığı arasında fark üretti (≤16/255); diğerleri ≤1/255 aynı.
    var tintsWithLayerOpacity: Bool { self != .mixer && self != .clipboard }
}

/// Pin durumu kendi alt görünümünde okunur: pin değişimi tüm genişletilmiş içeriği yeniden çizdirmez.
private struct PinButton: View {
    let model: IslandViewModel
    static let iconSize: CGFloat = 9.5 // 20 pt'lik sekme yuvasına sığar

    var body: some View {
        IslandIconButton(
            systemName: model.isPinned ? "pin.fill" : "pin",
            label: model.isPinned ? "Sabitlemeyi kaldır" : "Adayı açık tut",
            size: Self.iconSize
        ) {
            model.send(.togglePin)
        }
    }
}

/// HUD seviyesi (tuş tekrarında saniyede onlarca kez değişebilir) ve olay bildirimleri yalnızca bu küçük
/// görünümü günceller. Genişletilmiş adada bildirim içeriği kapatmaz, alt kenarda kısa bir kapsül olur.
private struct HUDBannerHost: View {
    let model: IslandViewModel

    var body: some View {
        ZStack {
            if let hud = model.hud {
                HUDBanner(payload: hud)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            } else if let notice = model.notice, NoticePresentation(notice).showsInExpandedIsland {
                NoticeBanner(notice: notice)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(IslandMotion.hud, value: model.hud == nil)
        .animation(IslandMotion.hud, value: model.notice)
    }
}

private struct NoticeBanner: View {
    let notice: IslandNotice

    var body: some View {
        let presentation = NoticePresentation(notice)
        HStack(spacing: IslandSpacing.s) {
            Image(systemName: presentation.bannerSymbol)
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            Text(presentation.bannerText)
                .font(IslandType.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, IslandSpacing.m)
        .padding(.vertical, 6)
        .background(Capsule().fill(IslandPalette.surface))
        .background(Capsule().fill(IslandPalette.fillHover).padding(-0.5))
        .accessibilityElement(children: .combine)
    }
}

/// Genişletilmiş görünümde HUD, içeriği kapatmadan alt kenarda kısa bir kapsül olarak görünür.
struct HUDBanner: View {
    let payload: HUDPayload

    var body: some View {
        HStack(spacing: IslandSpacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            LevelBar(level: payload.level).frame(width: 120, height: 4)
        }
        .padding(.horizontal, IslandSpacing.m)
        .padding(.vertical, 6)
        .background(Capsule().fill(IslandPalette.surface))
        .background(Capsule().fill(IslandPalette.fillHover).padding(-0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Seviye")
        .accessibilityValue("%\(Int((payload.level * 100).rounded()))")
    }

    private var symbol: String {
        switch payload.kind {
        case .volume(let muted): muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .brightness: "sun.max.fill"
        case .keyboardBacklight: "light.max"
        }
    }
}
