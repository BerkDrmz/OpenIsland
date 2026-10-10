import AppKit
import IslandCore
import SwiftUI

/// Bir bildirimin nasıl görüneceğinin **tek** tanımı. Kompakt bildirim (`NoticeView`) ve genişletilmiş
/// adadaki kapsül (`NoticeBanner`) aynı modeli kullanır; yeni bir bildirim türü yalnızca burada eklenir.
/// HUD (ses/parlaklık) bu modelin parçası değildir: kullanıcının kendi eylemidir ve ayrı katmanda çizilir.
struct NoticePresentation {
    enum Leading {
        case symbol(String, Color)
        case battery(PowerEvent)
        case swatch(String)
        /// Kalıcı albüm kapağı katmanı bu yuvada çizilir.
        case artworkLayer
    }

    enum Trailing {
        case value(String, Color)
        case symbol(String)
        /// Kalıcı dalga biçimi katmanı bu yuvada çizilir.
        case waveformLayer
    }

    let leading: Leading
    let trailing: Trailing
    /// Çentiğin altındaki tek satır; aynı zamanda VoiceOver etiketi.
    let caption: String
    /// Genişletilmiş adada gösterilir mi (medya paneli çalan parçayı zaten gösterir).
    let showsInExpandedIsland: Bool
    let bannerSymbol: String
    let bannerText: String

    init(_ notice: IslandNotice) {
        switch notice {
        case .power(let event):
            let percent = "%\(Int((event.level * 100).rounded()))"
            leading = .battery(event)
            trailing = .value(percent, event.tint)
            caption = switch event.kind {
            case .pluggedIn: event.isCharging ? "Şarj oluyor" : "Güç adaptörü bağlandı"
            case .unplugged: "Pil gücüne geçildi"
            case .chargingStarted: "Şarj başladı"
            case .chargingStopped: "Şarj durdu"
            case .low: "Pil zayıf"
            case .critical: "Pil kritik seviyede — şarj aletini takın"
            case .full: "Tamamen şarj oldu"
            }
            showsInExpandedIsland = true
            bannerSymbol = event.isCharging || event.kind == .pluggedIn ? "battery.100percent.bolt" : "battery.25percent"
            bannerText = "Pil \(percent) · \(caption)"
        case let .audioOutput(name, kind, connected):
            leading = .symbol(kind.symbol, connected ? IslandPalette.primary : IslandPalette.tertiary)
            trailing = .symbol(connected ? "checkmark" : "xmark")
            caption = "\(name) · \(connected ? "Bağlandı" : "Bağlantı kesildi")"
            showsInExpandedIsland = true
            bannerSymbol = kind.symbol
            bannerText = caption
        case let .nowPlaying(title, artist):
            leading = .artworkLayer
            trailing = .waveformLayer
            caption = artist.isEmpty ? title : "\(title) — \(artist)"
            showsInExpandedIsland = false
            bannerSymbol = "music.note"
            bannerText = title
        case let .meeting(title, minutes):
            leading = .symbol("calendar", IslandPalette.primary)
            trailing = .value("\(minutes) dk", IslandPalette.primary)
            caption = title
            showsInExpandedIsland = true
            bannerSymbol = "calendar"
            bannerText = "\(title) · \(minutes) dk"
        case .timerFinished(let title):
            leading = .symbol("checkmark.circle.fill", .green)
            trailing = .symbol("checkmark")
            caption = title
            showsInExpandedIsland = true
            bannerSymbol = "checkmark.circle.fill"
            bannerText = title
        case .transferFinished(let name):
            leading = .symbol("arrow.down.circle.fill", .green)
            trailing = .symbol("checkmark")
            caption = "\(name) indirildi"
            showsInExpandedIsland = true
            bannerSymbol = "arrow.down.circle.fill"
            bannerText = caption
        case let .transferEnded(name, outcome):
            let cancelled = outcome == .cancelled
            leading = .symbol(cancelled ? "xmark.circle" : "exclamationmark.circle", .orange)
            trailing = .symbol(cancelled ? "xmark" : "exclamationmark")
            caption = "\(name) · \(cancelled ? "Aktarım iptal edildi" : "Aktarım tamamlanamadı")"
            showsInExpandedIsland = true
            bannerSymbol = cancelled ? "xmark.circle" : "exclamationmark.circle"
            bannerText = caption
        case .networkChanged(let available):
            leading = .symbol(available ? "network" : "wifi.slash", available ? .green : .orange)
            trailing = .symbol(available ? "checkmark" : "xmark")
            caption = available ? "Ağ bağlantısı geri geldi" : "Ağ bağlantısı kesildi"
            showsInExpandedIsland = true
            bannerSymbol = available ? "network" : "wifi.slash"
            bannerText = caption
        case let .displayChanged(name, kind):
            leading = .symbol("display", IslandPalette.primary)
            trailing = .symbol(kind == .disconnected ? "xmark" : "checkmark")
            let detail = switch kind {
            case .connected: "Ekran bağlandı"
            case .disconnected: "Ekran çıkarıldı"
            case .configuration: "Ekran düzeni değişti"
            }
            caption = "\(name) · \(detail)"
            showsInExpandedIsland = true
            bannerSymbol = "display"
            bannerText = caption
        case .colorPicked(let hex):
            leading = .swatch(hex)
            trailing = .value(hex, IslandPalette.primary)
            caption = "Renk panoya kopyalandı"
            showsInExpandedIsland = true
            bannerSymbol = "eyedropper"
            bannerText = "\(hex) kopyalandı"
        case .airDropSent(let count):
            leading = .symbol("antenna.radiowaves.left.and.right", .blue)
            trailing = .symbol("checkmark")
            caption = count == 1 ? "AirDrop ile gönderildi" : "\(count) öğe AirDrop ile gönderildi"
            showsInExpandedIsland = true
            bannerSymbol = "antenna.radiowaves.left.and.right"
            bannerText = caption
        case .unlocked:
            leading = .symbol("lock.open.fill", IslandPalette.primary)
            trailing = .symbol("checkmark")
            caption = "Kilit açıldı"
            showsInExpandedIsland = true
            bannerSymbol = "lock.open.fill"
            bannerText = caption
        }
    }
}

/// Geçici olay bildirimi (iPhone Dynamic Island'daki şarj/AirPods göstergeleri gibi).
///
/// Düzen: kanat satırı (solda simge, sağda değer; ortası donanım çentiğinin arkasında) + çentiğin hemen
/// altında tek satırlık açıklama. Yüzey hafifçe genişleyip aşağı uzar, süre dolunca aynı yayla söner.
struct NoticeView: View {
    let notice: IslandNotice
    let metrics: NotchMetrics

    var body: some View {
        let presentation = NoticePresentation(notice)
        let layout = IslandLayoutEngine.layout(for: .notice(notice), metrics: metrics)
        let wingHeight = metrics.notchSize.height
        let side = IslandLayoutEngine.bodyInset(for: layout, style: metrics.style) + (wingHeight - 20) / 2

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading(presentation.leading).frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: metrics.style == .notch ? metrics.notchSize.width : IslandSpacing.s)
                trailing(presentation.trailing).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, side)
            .frame(height: wingHeight)

            Text(presentation.caption)
                .font(IslandType.caption)
                .foregroundStyle(IslandPalette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, IslandSpacing.l)
                .frame(maxHeight: .infinity, alignment: .center)
                .padding(.bottom, IslandSpacing.xxs)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .foregroundStyle(IslandPalette.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.caption)
    }

    @ViewBuilder
    private func leading(_ leading: NoticePresentation.Leading) -> some View {
        switch leading {
        case let .symbol(name, color):
            Image(systemName: name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .symbolRenderingMode(.hierarchical)
        case .battery(let event):
            BatteryGlyph(level: event.level, isCharging: event.isCharging || event.kind == .pluggedIn, tint: event.tint)
        case .swatch(let hex):
            Circle()
                .fill(Color(hex: hex) ?? .white)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .frame(width: 16, height: 16)
        case .artworkLayer:
            EmptyView()
        }
    }

    @ViewBuilder
    private func trailing(_ trailing: NoticePresentation.Trailing) -> some View {
        switch trailing {
        case let .value(text, color):
            Text(text)
                .font(IslandType.numeric)
                .foregroundStyle(color)
                .contentTransition(.numericText())
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IslandPalette.secondary)
        case .waveformLayer:
            EmptyView()
        }
    }
}

/// Device feedback uses only the wings; the physical notch stays unobstructed.
struct AudioConnectionNoticeView: View {
    let name: String
    let kind: AudioOutputKind
    let connected: Bool
    let metrics: NotchMetrics

    var body: some View {
        let notice = IslandNotice.audioOutput(name: name, kind: kind, connected: connected)
        let layout = IslandLayoutEngine.layout(for: .notice(notice), metrics: metrics)
        let wing = (layout.size.width - metrics.notchSize.width) / 2
        HStack(spacing: 0) {
            Image(systemName: kind.symbol)
                .font(.system(size: min(layout.size.height * 0.48, 17), weight: .medium))
                .frame(width: wing)
            Color.clear.frame(width: metrics.notchSize.width)
            VStack(spacing: 1) {
                Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(connected ? "Bağlandı" : "Bağlantı kesildi")
                    .font(.system(size: 9)).foregroundStyle(IslandPalette.secondary)
            }
            .padding(.horizontal, 10)
            .frame(width: wing)
        }
        .foregroundStyle(IslandPalette.primary)
        .frame(width: layout.size.width, height: layout.size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NoticePresentation(notice).caption)
    }
}

/// Dolum animasyonlu pil simgesi. Görünür olduğu an bir kez yay ile dolar; sürekli animasyon yok.
struct BatteryGlyph: View {
    let level: Double
    let isCharging: Bool
    let tint: Color
    @State private var displayedLevel = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(IslandPalette.primary.opacity(0.45), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: max(2, 21 * displayedLevel))
                    .padding(2)
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 25, height: 12)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(IslandPalette.primary.opacity(0.45))
                .frame(width: 1.5, height: 4)
        }
        .onAppear {
            guard !reduceMotion else { displayedLevel = level; return }
            withAnimation(.spring(response: 0.8, dampingFraction: 0.86).delay(0.12)) { displayedLevel = level }
        }
        .onChange(of: level) { _, value in
            withAnimation(IslandMotion.hud) { displayedLevel = value }
        }
        .accessibilityHidden(true)
    }
}

extension PowerEvent {
    /// Yeşil: şarj/dolu/normal · Sarı: %20 ve altı · Kırmızı: %10 ve altı.
    var tint: Color {
        if kind == .full || isCharging || kind == .pluggedIn { return Color(red: 0.2, green: 0.84, blue: 0.35) }
        if level <= 0.1 { return Color(red: 1, green: 0.27, blue: 0.23) }
        if level <= 0.2 { return Color(red: 1, green: 0.8, blue: 0.0) }
        return Color(red: 0.2, green: 0.84, blue: 0.35)
    }
}

extension AudioOutputKind {
    var symbol: String {
        switch self {
        case .builtIn: "laptopcomputer"
        case .airPods: "airpods"
        case .airPodsPro: "airpodspro"
        case .airPodsMax: "airpodsmax"
        case .headphones: "headphones"
        case .display: "display"
        case .airPlay: "airplayaudio"
        case .external: "hifispeaker.fill"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        }
    }
}

extension Color {
    /// "#RRGGBB" → Color
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - Kilit açılma geri bildirimi

/// iPhone'daki Face ID başarı geri bildirimine benzer kilit sembolü geçişi (`lock.fill` → `lock.open.fill`).
///
/// Düzen: sembol **sol kanadın ortasında** durur. Adanın merkezi donanım çentiğinin arkasındadır (orada ekran
/// pikseli yok); merkeze konan sembol fiziksel ekranda görünmezdi. Açıklama satırı yok; çentik yalnızca yatay
/// genişleyerek fiziksel donanımın doğal uzantısı gibi görünür.
///
/// Senkron: sembolün konumu, adanın genişlemesiyle **aynı yay** (`IslandMotion.morph`) ile sürülen `expansion`
/// değerinden hesaplanır; sembol her karede adanın o anki görünen sol kanadının ortasındadır (çentiğin
/// arkasından kanatla birlikte çıkar). Kilidin açılma geçişi de genişlemenin tepe noktasında biter.
struct UnlockNoticeView: View {
    let metrics: NotchMetrics
    /// Adanın dinlenmeden tam genişliğe ilerleyişi (0…1); yüzeyi büyüten yayla birlikte animasyonlanır.
    @State private var expansion: CGFloat = 0
    @State private var isUnlocked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandMotionStyle) private var motionStyle

    /// Kilit, genişlemeyle aynı anda açılmaya başlar ve daha kısa bir yayla genişlemeyle birlikte oturur
    /// (ölçüm: genişleme ~0,2 sn'de tepeye varır; kilit ~0,35 sn'de açık görünüyordu).
    private static let unlockDelay: Duration = .milliseconds(180)

    var body: some View {
        let layout = IslandLayoutEngine.layout(for: .notice(.unlocked), metrics: metrics)
        let wingWidth = max((layout.size.width - metrics.notchSize.width) / 2, 0)
        // Görünen siyah gövde, üst kulaklar (içbükey köşeler) yüzünden dış kenardan `topCornerRadius` içeridedir.
        let visibleWing = max(wingWidth * expansion - layout.topCornerRadius, 0)
        let symbolX = -(metrics.notchSize.width / 2 + visibleWing / 2)

        ZStack {
            lockSymbol.offset(x: symbolX) // yalnızca sol kanat: medya kapağıyla aynı yan
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .task {
            LifecycleLog.note("unlock-view: görünüm hazır reduceMotion=\(reduceMotion) boyut=\(Int(layout.size.width))x\(Int(layout.size.height)) kanat=\(Int(wingWidth))")
            let style: MotionStyle = reduceMotion ? .reduced : motionStyle
            withAnimation(IslandMotion.morph(from: .idle, to: .notice(.unlocked), style: style)) { expansion = 1 }
            try? await Task.sleep(for: Self.unlockDelay) // görünüm kapanırsa görev iptal olur
            guard !Task.isCancelled else { return }
            if reduceMotion || motionStyle == .reduced {
                // Hareketi Azalt: yay ve ölçek yok, yalnızca yumuşak geçiş.
                withAnimation(.easeInOut(duration: 0.12)) { isUnlocked = true }
            } else {
                withAnimation(.spring(response: 0.16, dampingFraction: 0.85)) { isUnlocked = true }
            }
        }
        .onChange(of: isUnlocked) { _, value in
            LifecycleLog.note("unlock-view: isUnlocked=\(value)")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kilit açıldı")
    }

    private var lockSymbol: some View {
        Image(systemName: isUnlocked ? "lock.open.fill" : "lock.fill")
            .font(.system(size: symbolSize, weight: .medium))
            .foregroundStyle(IslandPalette.primary)
            .contentTransition(reduceMotion || motionStyle == .reduced ? .opacity : .symbolEffect(.replace.downUp.byLayer))
            .scaleEffect(isUnlocked || reduceMotion || motionStyle == .reduced ? 1 : 0.7)
            .opacity(isUnlocked ? 1 : 0.6)
    }

    /// Sembol boyutu çentik yüksekliğiyle orantılı; aşırı büyümez.
    private var symbolSize: CGFloat {
        min(metrics.notchSize.height * 0.48, 18).rounded()
    }
}
