import AppKit
import IslandCore
import SwiftUI

// Adanın görsel dili tek dosyada: renk, tipografi, boşluk, yükselti ve hareket.
// Geometri ölçüleri (boyutlar, yarıçaplar, yuvalar) test edilebilsin diye IslandCore'daki
// `IslandLayoutEngine`'dedir.

enum IslandPalette {
    /// Donanım çentiğiyle birebir: #000000. Yaklaşık siyah değil, saf siyah.
    static let surface = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)
    static let primary = Color.white
    /// #9E9E9E eşdeğeri; siyah üzerinde ~7,5:1 kontrast. "Kontrastı Artır"da ~12:1.
    static let secondary = white(0.62, increased: 0.8)
    /// Yardımcı metin; siyah üzerinde ~4,8:1 (WCAG AA). "Kontrastı Artır"da ~9:1.
    static let tertiary = white(0.48, increased: 0.7)
    static let fill = white(0.07, increased: 0.14)
    static let fillHover = white(0.12, increased: 0.22)
    static let separator = white(0.12, increased: 0.32)
    static let track = white(0.18, increased: 0.34)
    /// Ses nabzı: sıcak açık amber. Siyah üzerinde ~13:1 kontrast; parıltı veya gölge verilmez.
    static let pulseNSColor = NSColor(srgbRed: 1.0, green: 0.8, blue: 0.42, alpha: 1)
    static let pulse = Color(nsColor: pulseNSColor)

    /// Gövde her durumda saf siyah kalır; yalnızca metin, dolgu ve ayırıcılar belirginleşir.
    /// Ayar, renk çözümlendiği anda okunur (ekstra gözlemci veya yeniden çizim zorlaması yok).
    private static func white(_ standard: CGFloat, increased: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { _ in
            let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: highContrast ? increased : standard)
        })
    }
}

/// Sistem fontu: SF Pro, boyuta göre Text/Display optik varyantını kendisi seçer.
/// Sürekli değişen sayılar `monospacedDigit` ile yatayda oynamaz; sayaçlarda SF Pro Rounded.
enum IslandType {
    static let title = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 12, weight: .regular)
    static let bodyEmphasized = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11, weight: .regular)
    static let caption2 = Font.system(size: 10, weight: .medium)
    static let sectionLabel = Font.system(size: 10, weight: .semibold)
    static let numeric = Font.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit()
    static let numericSmall = Font.system(size: 10, weight: .medium, design: .rounded).monospacedDigit()
    static let numericLarge = Font.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit()
}

enum IslandSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    /// İç kartların köşe yarıçapı; genişletilmiş yüzeyle eş-merkezli.
    static let cardRadius = IslandLayoutEngine.concentricRadius(
        outer: IslandLayoutEngine.expandedBottomRadius, inset: IslandLayoutEngine.contentInset)
}

/// Yüzen yüzey gölgesi: kısa bir temas gölgesi + yumuşak ortam gölgesi. Gri hale oluşturmaz.
enum IslandElevation {
    static let contactOpacity = 0.34
    static let contactRadius: CGFloat = 1.5
    static let contactOffset: CGFloat = 1
    static let ambientOpacity = 0.26
    static let ambientRadius: CGFloat = 18
    static let ambientOffset: CGFloat = 10
}

/// Yay fiziği. Değerler rastgele değil, sönüm oranından (ζ) hesaplanan aşıma göre seçildi:
/// aşım = e^(−ζπ / √(1−ζ²)).
enum IslandMotion {
    /// Açılma — ζ 0,78 → ~%2 aşım (280→600 pt genişlemede ≈ 6 pt), tek küçük geri sekme.
    static let expand = Animation.spring(response: 0.44, dampingFraction: 0.78, blendDuration: 0.12)
    /// Kapanma — ζ 0,94 → aşım ≈ %0,02: enerjisini yumuşakça bırakıp çentiğe karışır.
    /// Açılmanın tersi değil: daha uzun `response`, sekmesiz son.
    static let collapse = Animation.spring(response: 0.5, dampingFraction: 0.94, blendDuration: 0.12)
    /// Hover kabarması — ζ 0,72 → 10 pt'lik değişimde ~0,4 pt canlılık.
    static let hover = Animation.spring(response: 0.3, dampingFraction: 0.72, blendDuration: 0.08)
    /// Kanatlar arası dinlenme geçişleri (idle ↔ compact).
    static let rest = Animation.spring(response: 0.4, dampingFraction: 0.84, blendDuration: 0.1)
    /// Geçici bildirim (pil, AirPods…) — ζ 0,8 → ~%1,5 aşım: çentikten canlı ama ölçülü bir damla gibi
    /// iki yana ve aşağı uzar; süre dolunca `collapse` ile sekmeden söner.
    static let notice = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0.1)
    /// HUD — ζ 0,86 → ~%0,5 aşım; tuş tekrarında çevik.
    static let hud = Animation.spring(response: 0.3, dampingFraction: 0.86, blendDuration: 0.05)
    /// İmleç ayrıldığında "sönümlenme" (kritik sönüm, aşımsız).
    static let relax = Animation.spring(response: 0.55, dampingFraction: 1)
    static let relaxScale: CGFloat = 0.994
    /// İçerik yüzey büyümeye başladıktan hemen sonra belirir; kaybolurken hızla söner.
    static let contentIn = Animation.spring(response: 0.34, dampingFraction: 1).delay(0.06)
    static let contentOut = Animation.spring(response: 0.16, dampingFraction: 1)
    static let control = Animation.spring(response: 0.26, dampingFraction: 0.8)
    /// "Hareketi Azalt": aşımsız, kısa.
    static let reduced = Animation.spring(response: 0.24, dampingFraction: 1)

    /// "Canlı" stil (varsayılan): hızlı ve çevik. Tepeye varış t = π / (ω√(1−ζ²)), ω = 2π / response.
    /// Açılış: response 0,26, ζ 0,80 → tepe ~0,22 sn, aşım ~%1,5.
    /// İlk büyümeyi daha yumuşak yayar; yüzey ve içerik aynı yayı paylaşır.
    /// Kapanış: kritik sönüm, response 0,19 → ~0,18 sn'de %98, aşımsız (çentiğe sekmeden karışır).
    /// Ayarlar önizlemesi aynı sabitleri kullanır; ikisi birebir aynı hızdadır.
    static let livelyExpand = Animation.spring(response: 0.26, dampingFraction: 0.8, blendDuration: 0.08)
    static let livelyCollapse = Animation.spring(response: 0.19, dampingFraction: 1)
    static let livelyNotice = Animation.spring(response: 0.32, dampingFraction: 0.76, blendDuration: 0.08)
    static let livelyHover = Animation.spring(response: 0.21, dampingFraction: 0.7, blendDuration: 0.06)
    static let livelyContentIn = Animation.spring(response: 0.19, dampingFraction: 1).delay(0.02)
    static let livelyContentOut = Animation.spring(response: 0.11, dampingFraction: 1)

    static func morph(from old: IslandPresentation, to new: IslandPresentation, style: MotionStyle) -> Animation {
        if style == .reduced { return reduced }
        let lively = style == .expressive
        switch (old, new) {
        case (_, .expanded), (_, .dropTarget): return lively ? livelyExpand : expand
        case (.expanded, _), (.dropTarget, _): return lively ? livelyCollapse : collapse
        case (_, .hud), (.hud, _): return hud
        case (_, .notice): return lively ? livelyNotice : notice
        case (.notice, _): return lively ? livelyCollapse : collapse
        case (_, .peek), (.peek, _): return lively ? livelyHover : hover
        default: return rest
        }
    }

    /// Gövde yeniden boyutlanırken (içerik miktarı değişti) kullanılan yay.
    static func resize(style: MotionStyle) -> Animation {
        switch style {
        case .reduced: reduced
        case .natural: expand
        case .expressive: livelyExpand
        }
    }
}

extension AnyTransition {
    /// Yüzey büyürken içerik bulanıklıktan netleşir; ölçek yok (açılır pencere hissi vermez).
    /// Canlı stilde içerik de hızlı yüzeye yetişir; Sakin ve Azaltılmış'ta eski zamanlama korunur.
    /// Azaltılmış'ta (Hareketi Azalt ve pil tasarrufu) yalnızca opaklık: bulanıklık render sunucusunda GPU filtresidir
    /// (ölçüm: yoğun geçiş dizisinde adanın WindowServer maliyetinin ~%20'si).
    @MainActor static func islandReveal(_ style: MotionStyle, expanded: Bool = false) -> AnyTransition {
        let lively = style == .expressive
        let blurs = style != .reduced && !expanded
        return .asymmetric(
            insertion: .modifier(active: RevealModifier(progress: 0, blurs: blurs), identity: RevealModifier(progress: 1, blurs: blurs))
                .animation(expanded ? IslandMotion.resize(style: style) : lively ? IslandMotion.livelyContentIn : IslandMotion.contentIn),
            removal: .opacity.animation(lively ? IslandMotion.livelyContentOut : IslandMotion.contentOut)
        )
    }
}

/// Adanın hareket stili (içerik geçişleri stile göre hızlanır). `@Entry` makrosu Command Line Tools'ta
/// bulunmadığı için klasik ortam anahtarı.
private struct IslandMotionStyleKey: EnvironmentKey {
    static let defaultValue = MotionStyle.expressive
}

private struct IslandEnergySavingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var islandMotionStyle: MotionStyle {
        get { self[IslandMotionStyleKey.self] }
        set { self[IslandMotionStyleKey.self] = newValue }
    }

    /// Pil tasarrufu: sürekli dönen animasyonlar (müzik nabzı) durur.
    var islandEnergySaving: Bool {
        get { self[IslandEnergySavingKey.self] }
        set { self[IslandEnergySavingKey.self] = newValue }
    }
}

private struct RevealModifier: ViewModifier {
    let progress: Double
    let blurs: Bool

    // Aynı geçişte iki durum da aynı `blurs` değerini taşır; dal kimliği değişmez. Azaltılmış'ta filtre düğümü hiç kurulmaz.
    @ViewBuilder
    func body(content: Content) -> some View {
        if blurs {
            content.opacity(progress).blur(radius: (1 - progress) * 6)
        } else {
            content.opacity(progress)
        }
    }
}

extension IslandPresentation {
    var isExpanded: Bool {
        if case .expanded = self { true } else { false }
    }
}
