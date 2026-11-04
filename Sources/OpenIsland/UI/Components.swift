import AppKit
import SwiftUI

/// Albüm kapağı. Boyutu ve yarıçapı dışarıdan (eş-merkezli yuvadan) gelir; ikisi de yay ile
/// animasyonlanır. Siyah yüzey üzerinde kenarı kaybolmasın diye 0,5 pt'lik ince iç çizgi taşır.
struct ArtworkView: View {
    let image: NSImage?
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.24), Color(white: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
                GeometryReader { proxy in
                    Image(systemName: "music.note")
                        .font(.system(size: proxy.size.width * 0.38, weight: .semibold))
                        .foregroundStyle(IslandPalette.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// HUD seviye çubuğu.
struct LevelBar: View {
    let level: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(IslandPalette.track)
                Capsule().fill(tint).frame(width: max(proxy.size.height, proxy.size.width * level))
                    .opacity(level > 0 ? 1 : 0)
            }
        }
        .animation(IslandMotion.hud, value: level)
    }
}

/// Ada içindeki yuvarlak ikon düğmesi. Yalnızca imleç giriş/çıkışında tepki verir.
struct IslandIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 14
    var isProminent = false
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Dairesel düğmenin çapı (sembol boyutunun 2,1 katı). Başlık satırı genişliği de bundan türetilir.
    static func diameter(for size: CGFloat) -> CGFloat { size * 2.1 }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isProminent ? IslandPalette.primary : IslandPalette.primary.opacity(0.85))
                .frame(width: Self.diameter(for: size), height: Self.diameter(for: size))
                .background(Circle().fill(isHovering ? IslandPalette.fillHover : (isProminent ? IslandPalette.fill : .clear)))
                .scaleEffect(isHovering && !reduceMotion ? 1.06 : 1)
                .contentTransition(.symbolEffect(.replace))
                .contentShape(Circle())
                .restoringLayoutAnimation()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .onHover { hovering in
            withAnimation(IslandMotion.control) { isHovering = hovering }
        }
    }
}

/// `layoutWithoutAnimation()` ile ertelenen animasyon (yalnız o transaction'da dolu).
private struct DeferredLayoutAnimation: TransactionKey {
    static let defaultValue: Animation? = nil
}

extension View {
    /// Bu görünümün (ve içindekilerin) yerleşim değişimini animasyonsuz uygular; transaction'ın animasyonu
    /// `restoringLayoutAnimation()` ile işaretli alt görünümlerde sürer. Böylece görünen hareket aynı eğriyle canlanırken
    /// odak, erişilebilirlik ve isabet geometrisi son konuma tek adımda geçer (SwiftUI odak köprüsü her karede yeniden
    /// kurulmaz).
    func layoutWithoutAnimation() -> some View {
        transaction { transaction in
            transaction[DeferredLayoutAnimation.self] = transaction.animation
            transaction.animation = nil
        }
    }

    /// `layoutWithoutAnimation()` altında ertelenen animasyonu geri yükler; başka transaction'larda etkisizdir.
    func restoringLayoutAnimation() -> some View {
        transaction { transaction in
            if let animation = transaction[DeferredLayoutAnimation.self] { transaction.animation = animation }
        }
    }
}

extension TimeInterval {
    /// Kapalı adanın dar kanadı için yalnız dakika, yukarı yuvarlanır (45:12 → "46", son dakika → "1", bitince "0"):
    /// "dakika:saniye" kanada sığmıyor, "46:…" diye kesiliyordu.
    var compactMinutesString: String {
        guard isFinite, self > 0 else { return "0" }
        return String(Int((self / 60).rounded(.up)))
    }

    /// 3:07 veya 1:02:45 biçimi.
    var clockString: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self.rounded(.down))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
