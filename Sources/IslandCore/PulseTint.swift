import Foundation

/// "Albüm renginde nabız" kuralı (saf, testli). Renk parça değişince bir kez, küçültülmüş kapağın pikselleriyle
/// hesaplanır; nabzın kendi maliyeti değişmez (aynı katmanların yalnızca rengi değişir).
///
/// Kapağın **ortalaması** kullanılmaz: renkli kapakların ortalaması griye yakın, bulanık bir tona düşüyordu ve
/// okunurluk için beyaza karıştırılınca çoğu kapak varsayılan ambere benzeyen ten rengi oluyordu (kullanıcı
/// "albüm rengi olmamış" dedi). Bunun yerine baskın **canlı** ton seçilir:
/// - Doygunluğu ve parlaklığı yeterli pikseller ton kutularına (24) doygunluk × parlaklık ağırlığıyla dağıtılır;
///   komşu kutularla birlikte en ağır bölgenin ortalama rengi alınır.
/// - Renk tonu korunarak parlaklık en üste çıkarılır (beyaza karıştırmak rengi soldurur); yine de koyu kalan
///   tonlar (saf mavi gibi) siyah üzerinde en az `minimumLuminance` olacak kadar beyaza karıştırılır.
/// - Canlı piksel yok denecek kadar azsa (siyah-beyaz kapak) gümüş: kapağın gerçek rengi budur.
public enum PulseTint {
    /// Siyah üzerinde kontrast (L + 0,05) / 0,05 ≥ 5:1. İnce çubuklar için yeterli, renkleri soldurmaz.
    public static let minimumLuminance = 0.2
    /// Bundan az doygun veya karanlık pikseller ton seçimine katılmaz.
    public static let minimumPixelSaturation = 0.25
    public static let minimumPixelBrightness = 0.25
    /// Canlı piksellerin toplam ağırlığı piksel başına bundan azsa kapak gri tonlu sayılır.
    public static let minimumVibrantShare = 0.03
    /// Seçilen rengin doygunluğu bu aralığa çekilir: soluk kalmaz, neon da olmaz.
    public static let saturationRange = 0.45...0.9
    public static let hueBins = 24
    /// Siyah-beyaz kapak için nabız rengi.
    public static let silver = RGB(red: 0.92, green: 0.92, blue: 0.94)

    public struct RGB: Equatable, Sendable {
        public var red: Double, green: Double, blue: Double
        public init(red: Double, green: Double, blue: Double) {
            self.red = red; self.green = green; self.blue = blue
        }
    }

    /// `pixels`: küçültülmüş kapağın sRGB pikselleri (0…1). Boşsa `nil` (varsayılan amber kalır).
    public static func albumTint(pixels: [RGB]) -> RGB? {
        let valid = pixels.filter { $0.red.isFinite && $0.green.isFinite && $0.blue.isFinite }
        guard !valid.isEmpty else { return nil }

        var weights = [Double](repeating: 0, count: hueBins)
        var sums = [RGB](repeating: RGB(red: 0, green: 0, blue: 0), count: hueBins)
        for pixel in valid {
            let color = clamped(pixel)
            let (hue, saturation, brightness) = hsv(color)
            guard saturation >= minimumPixelSaturation, brightness >= minimumPixelBrightness else { continue }
            let weight = saturation * brightness
            let bin = min(Int(hue * Double(hueBins)), hueBins - 1)
            weights[bin] += weight
            sums[bin].red += color.red * weight
            sums[bin].green += color.green * weight
            sums[bin].blue += color.blue * weight
        }
        guard weights.reduce(0, +) / Double(valid.count) >= minimumVibrantShare else { return silver }

        // Ton sınırına düşen bir renk iki kutuya bölünmesin: komşularla birlikte en ağır bölge.
        func regionWeight(_ bin: Int) -> Double {
            weights[bin] + 0.5 * (weights[(bin + 1) % hueBins] + weights[(bin + hueBins - 1) % hueBins])
        }
        guard let best = (0..<hueBins).max(by: { regionWeight($0) < regionWeight($1) }), weights[best] > 0 else { return silver }
        let dominant = RGB(red: sums[best].red / weights[best], green: sums[best].green / weights[best],
                           blue: sums[best].blue / weights[best])
        let (hue, saturation, _) = hsv(dominant)
        let vivid = rgb(hue: hue, saturation: min(max(saturation, saturationRange.lowerBound), saturationRange.upperBound),
                        brightness: 1)
        return readable(vivid)
    }

    /// WCAG göreli parlaklık (sRGB).
    public static func luminance(_ color: RGB) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    // MARK: - Yardımcılar

    /// Gerekenden fazla beyazlatmadan (ikili arama) en az `minimumLuminance`.
    private static func readable(_ color: RGB) -> RGB {
        guard luminance(color) < minimumLuminance else { return color }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if luminance(mix(color, mid)) < minimumLuminance { low = mid } else { high = mid }
        }
        return mix(color, high)
    }

    private static func mix(_ color: RGB, _ t: Double) -> RGB {
        RGB(red: color.red + (1 - color.red) * t, green: color.green + (1 - color.green) * t, blue: color.blue + (1 - color.blue) * t)
    }

    private static func clamped(_ color: RGB) -> RGB {
        RGB(red: min(max(color.red, 0), 1), green: min(max(color.green, 0), 1), blue: min(max(color.blue, 0), 1))
    }

    static func hsv(_ color: RGB) -> (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(color.red, color.green, color.blue)
        let delta = maximum - min(color.red, color.green, color.blue)
        var hue = 0.0
        if delta > 0 {
            switch maximum {
            case color.red: hue = ((color.green - color.blue) / delta).truncatingRemainder(dividingBy: 6)
            case color.green: hue = (color.blue - color.red) / delta + 2
            default: hue = (color.red - color.green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maximum > 0 ? delta / maximum : 0, maximum)
    }

    static func rgb(hue: Double, saturation: Double, brightness: Double) -> RGB {
        let sector = (hue * 6).rounded(.down)
        let f = hue * 6 - sector
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - f * saturation)
        let t = brightness * (1 - (1 - f) * saturation)
        switch Int(sector) % 6 {
        case 0: return RGB(red: brightness, green: t, blue: p)
        case 1: return RGB(red: q, green: brightness, blue: p)
        case 2: return RGB(red: p, green: brightness, blue: t)
        case 3: return RGB(red: p, green: q, blue: brightness)
        case 4: return RGB(red: t, green: p, blue: brightness)
        default: return RGB(red: brightness, green: p, blue: q)
        }
    }
}
