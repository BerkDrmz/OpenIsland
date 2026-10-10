import IslandCore
import SwiftUI

extension ExpandedTab {
    var symbol: String {
        switch self {
        case .nook: "square.grid.2x2.fill"
        case .media: "music.note"
        case .shelf: "tray.and.arrow.down.fill"
        case .clipboard: "doc.on.clipboard"
        case .focus: "timer"
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
    let tab: ExpandedTab
    let model: IslandViewModel
    let environment: AppEnvironment
    @Namespace private var tabSelection

    var body: some View {
        let metrics = model.metrics
        let layout = IslandLayoutEngine.layout(for: .expanded(tab), metrics: metrics)
        let side = IslandLayoutEngine.contentSideInset(for: layout, style: metrics.style, size: metrics.expandedSurfaceSize)

        ZStack(alignment: .top) {
            header(metrics: metrics)
                .padding(.horizontal, IslandLayoutEngine.headerSidePadding(style: metrics.style, size: metrics.expandedSurfaceSize))
                .frame(height: metrics.notchSize.height)

            content(metrics: metrics)
                .id(tab)
                .transition(.islandReveal(motionStyle, expanded: true))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(EdgeInsets(
                    top: metrics.notchSize.height + IslandLayoutEngine.headerGap,
                    leading: side,
                    bottom: IslandLayoutEngine.expandedBottomInset(for: metrics),
                    trailing: side
                ))

            HUDBannerHost(model: model)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, IslandSpacing.s)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
        .foregroundStyle(IslandPalette.primary)
        .compositingGroup()
    }

    /// Tüm sekmeler her zaman doğrudan tıklanabilir ve her görünümde aynı yerde durur (çentiğe yaslı):
    /// solda Müzik, Nook, Raf, Pano, Ses Mikseri; sağda Odak, Notlar, Ayna, Sistem ve iğne. Kapalı modüllerin sekmesi gösterilmez.
    private func header(metrics: NotchMetrics) -> some View {
        let visible = environment.preferences.visibleTabs
        let spacing = IslandLayoutEngine.tabSpacing
        return HStack(spacing: 0) {
            HStack(spacing: spacing) {
                ForEach(IslandLayoutEngine.leadingTabOrder.filter(visible.contains), id: \.self, content: tabButton)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            Color.clear.frame(width: metrics.style == .notch ? metrics.notchSize.width : IslandSpacing.m)
            HStack(spacing: spacing) {
                ForEach(IslandLayoutEngine.trailingTabOrder.filter(visible.contains), id: \.self, content: tabButton)
                PinButton(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tabButton(_ item: ExpandedTab) -> some View {
        let isSelected = item == tab
        return Button {
            model.send(.selectTab(item))
        } label: {
            Image(systemName: item.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? IslandPalette.primary : IslandPalette.tertiary)
                .frame(width: IslandLayoutEngine.tabButtonSize.width, height: IslandLayoutEngine.tabButtonSize.height)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(IslandPalette.fillHover)
                            .matchedGeometryEffect(id: "selection", in: tabSelection)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func content(metrics: NotchMetrics) -> some View {
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

/// Pin durumu kendi alt görünümünde okunur: pin değişimi tüm genişletilmiş içeriği yeniden çizdirmez.
private struct PinButton: View {
    let model: IslandViewModel

    var body: some View {
        IslandIconButton(
            systemName: model.isPinned ? "pin.fill" : "pin",
            label: model.isPinned ? "Sabitlemeyi kaldır" : "Adayı açık tut",
            size: 9.5 // 20 pt'lik sekme yuvasına sığar
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
