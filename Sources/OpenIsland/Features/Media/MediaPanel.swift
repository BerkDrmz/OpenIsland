import IslandCore
import SwiftUI

/// Genişletilmiş medya düzeni. Albüm kapağı ve dalga biçimi burada çizilmez: kök görünümdeki kalıcı
/// katmanlar aynı yuvalara (`IslandLayoutEngine`) yerleşir; bu görünüm yalnızca onlara yer ayırır.
struct MediaPanel: View {
    let media: MediaController
    let metrics: NotchMetrics

    var body: some View {
        if let info = media.nowPlaying {
            let artwork = IslandLayoutEngine.artworkSlot(for: .expanded(.media), metrics: metrics)?.rect.size ?? .zero
            let wave = IslandLayoutEngine.waveformSlot(for: .expanded(.media), metrics: metrics)?.size ?? .zero

            HStack(alignment: .top, spacing: IslandLayoutEngine.mediaArtworkGap) {
                // Kapak ve başlık: gerçek oynatıcıya geçiş. Hızlı işlemler (oynat/atla/sar) adada kalır.
                SourceAppButton(media: media) {
                    Color.clear.frame(width: artwork.width, height: artwork.height)
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: IslandSpacing.s) {
                        SourceAppButton(media: media) {
                            VStack(alignment: .leading, spacing: IslandSpacing.xxs) {
                                Text(info.title)
                                    .font(IslandType.title)
                                    .foregroundStyle(IslandPalette.primary)
                                    .lineLimit(1)
                                Text(info.artist.isEmpty ? info.album : info.artist)
                                    .font(IslandType.body)
                                    .foregroundStyle(IslandPalette.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: IslandSpacing.s)
                        Color.clear.frame(width: wave.width, height: wave.height)
                    }
                    Spacer(minLength: 4)
                    ScrubberView(info: info, tint: media.accentNSColor, canSeek: media.canSeek, onSeek: media.seek)
                    Spacer(minLength: 4)
                    TransportControls(isPlaying: info.isPlaying, media: media)
                }
                .frame(height: artwork.height)
            }
        } else {
            VStack(spacing: IslandSpacing.s) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(IslandPalette.tertiary)
                Text("Şu anda çalan bir şey yok")
                    .font(IslandType.bodyEmphasized)
                Text("Spotify, Müzik veya tarayıcıda bir şey başlatın. Ada üzerinde iki parmakla yatay kaydırarak parça değiştirebilirsiniz.")
                    .font(IslandType.caption)
                    .foregroundStyle(IslandPalette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Ana medya içeriği → müziği çalan gerçek uygulama. Uygulama bilinmiyorsa tıklama alınmaz (sahte bir
/// tıklanabilirlik gösterilmez); içerik soluklaştırılmaz.
struct SourceAppButton<Label: View>: View {
    let media: MediaController
    @ViewBuilder let label: () -> Label

    var body: some View {
        let application = media.sourceApplication
        Button(action: media.revealSourceApplication) {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(application != nil)
        .help(application?.localizedName.map { "\($0) uygulamasında aç" } ?? "")
        .accessibilityHint(application?.localizedName.map { "\($0) uygulamasını öne getirir" } ?? "")
    }
}

private struct TransportControls: View {
    let isPlaying: Bool
    let media: MediaController

    var body: some View {
        HStack(spacing: 22) {
            IslandIconButton(systemName: "backward.fill", label: "Önceki parça", size: 12, action: media.previousTrack)
            IslandIconButton(systemName: isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Duraklat" : "Oynat",
                             size: 15, isProminent: true, action: media.togglePlayPause)
            IslandIconButton(systemName: "forward.fill", label: "Sonraki parça", size: 12, action: media.nextTrack)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Satır içi süre çubuğu: `1:12 ━━━━━━━━ -2:35`.
///
/// Çubuk Core Animation ile akar (kare başına SwiftUI güncellemesi yok); süre etiketleri tam saniye
/// sınırlarında ve yalnızca çalarken güncellenir. Tıklama istenen noktaya atlar, sürükleme sarar; sürüklerken
/// çubuk kalınlaşır ve süre anlık güncellenir, bırakınca seek gönderilir.
struct ScrubberView: View {
    let info: NowPlayingInfo
    let tint: NSColor
    /// Kaynak seek desteklemiyorsa çubuk yalnızca ilerlemeyi gösterir (sürükleme ve vurgulama yok).
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void
    @State private var dragProgress: Double?
    @State private var isHovering = false

    private var timing: TimeProgressView.Timing {
        let rate = info.duration > 0 ? (info.playbackRate > 0 ? info.playbackRate : 1) / info.duration : 0
        if let dragProgress {
            return .init(progress: dragProgress, reference: info.timestamp, rate: 0, isRunning: false)
        }
        return .init(progress: info.duration > 0 ? info.elapsed / info.duration : 0,
                     reference: info.timestamp, rate: rate, isRunning: info.isPlaying)
    }

    var body: some View {
        let isActive = canSeek && (dragProgress != nil || isHovering)

        HStack(spacing: IslandSpacing.s) {
            ElapsedLabel(info: info, dragProgress: dragProgress, showsRemaining: false)
                .frame(minWidth: 30, alignment: .leading)
            GeometryReader { proxy in
                TimeProgressView(style: .bar, timing: timing, tint: tint)
                    .frame(height: isActive ? 6 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    // Tıklama da bir "sürükleme"dir (minimumDistance 0): istenen noktaya atlar.
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragProgress = min(max(value.location.x / max(proxy.size.width, 1), 0), 1)
                            }
                            .onEnded { _ in
                                if let dragProgress, info.duration > 0 { onSeek(dragProgress * info.duration) }
                                dragProgress = nil
                            },
                        including: canSeek ? .all : .none
                    )
            }
            .onHover { hovering in withAnimation(IslandMotion.control) { isHovering = hovering } }
            .animation(IslandMotion.control, value: isActive)
            .help(canSeek ? "" : "Bu kaynakta ileri/geri sarma desteklenmiyor")
            .accessibilityHidden(true)
            .overlay { ScrubberAccessibility(info: info, dragProgress: dragProgress, canSeek: canSeek, onSeek: onSeek) }
            ElapsedLabel(info: info, dragProgress: dragProgress, showsRemaining: true)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .frame(height: 14)
    }
}

/// Süre çubuğunun erişilebilirlik öğesi. Değeri görünen süre etiketleriyle aynı zaman çizelgesinde (tam saniye
/// sınırlarında, yalnızca çalarken) yenilenir. Önceden değer yalnızca parça bilgisi değişince hesaplanıyordu;
/// ekran okuyucu eski süreyi okuyordu (QA OI-01: ekranda 2:14, erişilebilirlikte 1:39).
private struct ScrubberAccessibility: View {
    let info: NowPlayingInfo
    let dragProgress: Double?
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        let anchor = info.timestamp.addingTimeInterval(-info.elapsed.truncatingRemainder(dividingBy: 1))
        TimelineView(PausablePeriodicSchedule(anchor: anchor, interval: 1, isPaused: !info.isPlaying || dragProgress != nil)) { context in
            let elapsed = dragProgress.map { $0 * info.duration } ?? info.elapsed(at: context.date)
            Color.clear
                .accessibilityElement()
                .accessibilityLabel("Süre")
                .accessibilityValue("\(elapsed.clockString) / \(info.duration.clockString)")
                .accessibilityAdjustableAction { direction in
                    guard canSeek else { return }
                    let step: TimeInterval = direction == .increment ? 10 : -10
                    onSeek(min(max(info.elapsed(at: .now) + step, 0), info.duration))
                }
        }
        .allowsHitTesting(false) // fare olayları alttaki çubuğa (sürükleme) gider
    }
}

/// Geçen / kalan süre: tam saniye sınırlarında ve yalnızca çalarken güncellenir.
private struct ElapsedLabel: View {
    let info: NowPlayingInfo
    let dragProgress: Double?
    let showsRemaining: Bool

    var body: some View {
        // Geçen süre tam saniyeye geçtiği anlara hizalı çapa.
        let anchor = info.timestamp.addingTimeInterval(-info.elapsed.truncatingRemainder(dividingBy: 1))
        TimelineView(PausablePeriodicSchedule(anchor: anchor, interval: 1, isPaused: !info.isPlaying || dragProgress != nil)) { context in
            let elapsed = dragProgress.map { $0 * info.duration } ?? info.elapsed(at: context.date)
            Text(showsRemaining ? "-" + max(info.duration - elapsed, 0).clockString : elapsed.clockString)
                .font(IslandType.numericSmall)
                .foregroundStyle(IslandPalette.tertiary)
                .lineLimit(1)
        }
        .accessibilityHidden(true)
    }
}
