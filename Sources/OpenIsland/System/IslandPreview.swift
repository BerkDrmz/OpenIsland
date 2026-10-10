import AppKit
import IslandCore
import SwiftUI

/// Ayarlardaki ada önizlemesi: gerçek yerleşim motoru (`IslandLayoutEngine`), gerçek şekil (`IslandShape`) ve
/// seçili hareket stilinin yaylarıyla kompakt medya ↔ Nook arasında açılıp kapanır. İçerik yalnızca yer
/// tutucudur. Animasyon yalnızca etkileşimde (üzerine gelme, tıklama, stil değişimi) çalışır; boştayken çizim yok.
struct IslandPreview: View {
    let motionStyle: MotionStyle
    let nookWidgetCount: Int
    let expandedSurfaceSize: ExpandedSurfaceSize
    /// Bu Mac'in ölçülen donanım çentiği; çentiksiz ekranda (veya ölçülemezse) tipik MacBook çentiği.
    var notchSize: CGSize = IslandPreview.typicalNotch

    @State private var isExpanded = false
    @State private var demo: Task<Void, Never>?

    /// 14"/16" MacBook Pro çentiği: yalnızca gerçek ölçü yoksa kullanılır.
    static let typicalNotch = CGSize(width: 185, height: 32)
    private static let scale: CGFloat = 0.62

    private var metrics: NotchMetrics {
        NotchMetrics(notchSize: notchSize, style: .notch, nookWidgetCount: nookWidgetCount,
                     expandedSurfaceSize: expandedSurfaceSize)
    }

    private var style: MotionStyle {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .reduced : motionStyle
    }

    private var presentation: IslandPresentation { isExpanded ? .expanded(.nook) : .compact(.media) }

    var body: some View {
        let metrics = metrics
        let layout = IslandLayoutEngine.layout(for: presentation, metrics: metrics)
        let tallest = IslandLayoutEngine.layout(for: .expanded(.nook), metrics: metrics).size.height
        let shape = IslandShape(style: .notch, topRadius: layout.topCornerRadius, bottomRadius: layout.bottomCornerRadius)

        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.34), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)
            Color.white.opacity(0.06).frame(height: notchSize.height * Self.scale) // menü çubuğu bandı
            island(layout: layout, shape: shape, metrics: metrics)
                .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
                .scaleEffect(Self.scale, anchor: .topLeading)
                .frame(width: layout.size.width * Self.scale, height: layout.size.height * Self.scale, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: tallest * Self.scale + 14)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { inside in
            demo?.cancel()
            setExpanded(inside)
        }
        .onTapGesture { setExpanded(!isExpanded) }
        .onChange(of: motionStyle) { play() }
        .onChange(of: expandedSurfaceSize) { play() }
        .accessibilityElement()
        .accessibilityLabel("Ada önizlemesi, \(motionStyle.title) hareket")
        .accessibilityAction(named: "Oynat") { play() }
    }

    private func island(layout: IslandLayout, shape: IslandShape, metrics: NotchMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            shape.fill(IslandPalette.surface)
            if isExpanded {
                expandedPlaceholder(layout: layout, metrics: metrics)
                    .transition(.islandReveal(style))
            } else {
                compactPlaceholder(layout: layout, metrics: metrics)
                    .transition(.islandReveal(style))
            }
            // Kapak tek kalıcı katmandır: gerçek adadaki gibi kanattan panele aynı yayla akar.
            if let slot = IslandLayoutEngine.artworkSlot(for: presentation, metrics: metrics) {
                RoundedRectangle(cornerRadius: slot.cornerRadius, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.3), Color(red: 0.55, green: 0.2, blue: 0.6)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: slot.rect.width, height: slot.rect.height)
                    .offset(x: slot.rect.minX, y: slot.rect.minY)
            }
        }
        .clipShape(shape)
    }

    private func compactPlaceholder(layout: IslandLayout, metrics: NotchMetrics) -> some View {
        let slot = IslandLayoutEngine.waveformSlot(for: .compact(.media), metrics: metrics) ?? .zero
        return HStack(alignment: .center, spacing: 2) {
            ForEach([0.5, 0.9, 0.6, 1.0, 0.7], id: \.self) { level in
                Capsule().fill(IslandPalette.pulse).frame(width: 3, height: slot.height * level)
            }
        }
        .frame(width: slot.width, height: slot.height)
        .offset(x: slot.minX, y: slot.minY)
    }

    private func expandedPlaceholder(layout: IslandLayout, metrics: NotchMetrics) -> some View {
        let top = metrics.notchSize.height + IslandLayoutEngine.headerGap
        let inset = IslandLayoutEngine.contentSideInset(for: layout, style: metrics.style, size: metrics.expandedSurfaceSize)
        let artwork = IslandLayoutEngine.artworkSlot(for: .expanded(.nook), metrics: metrics)?.rect.width ?? 0
        let height = layout.size.height - top - IslandLayoutEngine.expandedBottomInset(for: metrics)
        return HStack(spacing: IslandLayoutEngine.contentInset) {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(IslandPalette.primary.opacity(0.85)).frame(width: 90, height: 9)
                RoundedRectangle(cornerRadius: 3).fill(IslandPalette.secondary).frame(width: 60, height: 7)
                Spacer(minLength: 0)
                Capsule().fill(IslandPalette.track).frame(height: 4)
            }
            .padding(.leading, artwork + IslandLayoutEngine.contentInset)
            .frame(width: artwork + 150, alignment: .leading)
            ForEach(0..<nookWidgetCount, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(IslandPalette.fill)
            }
        }
        .frame(width: layout.size.width - inset * 2, height: height, alignment: .leading)
        .offset(x: inset, y: top)
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        let from = presentation
        let to: IslandPresentation = expanded ? .expanded(.nook) : .compact(.media)
        withAnimation(IslandMotion.morph(from: from, to: to, style: style)) { isExpanded = expanded }
    }

    /// Stil değişince bir kez aç-kapat: fark hemen görülsün.
    private func play() {
        demo?.cancel()
        setExpanded(true)
        demo = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            setExpanded(false)
        }
    }
}
