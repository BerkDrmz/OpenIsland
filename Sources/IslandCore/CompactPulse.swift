import Foundation

/// Kompakt medyadaki tahmini "müzik nabzı": gerçek ses analizi **kullanmaz** (tap, FFT, ses geri çağrısı yok).
///
/// Ölçüm: kompakt ritim için açılan Core Audio tap'i uygulamanın kendisinde %0,3–0,5, ses sunucusunda
/// (coreaudiod) %1,7–2,7 ek CPU tutuyordu. Bu kadar küçük bir gösterge için gerçek ses gerekmez; amaç
/// "müzik çalıyor ve çentik canlı" hissidir.
///
/// Desenler elle tasarlanmıştır (çalışma zamanında rastgele değer üretilmez). Her çubuğun kendi yükseklik
/// aralığı, deseni, adım süreleri ve başlangıç fazı vardır. Süreler birbirinin katı olmadığından birleşik
/// hareketin tekrar ettiği fark edilmez. UI bu verileri Core Animation keyframe'lerine çevirir; hareket
/// render sunucusunda akar, süreç yalnızca çalıyor/duraklatıldı değişiminde uyanır.
/// Değerler normalizedir: 0 = nokta (çubuk kalınlığı kadar), 1 = yuvanın tam yüksekliği.
public enum CompactPulse {
    public struct Bar: Sendable, Equatable {
        /// Döngü içindeki yükseklikler; döngü sonunda ilk değere döner (dikişsiz).
        public let levels: [Double]
        /// Her adımın (bir değerden sonrakine) süresi, saniye.
        public let steps: [Double]

        public var cycleDuration: Double { steps.reduce(0, +) }
        /// Bir yükselip inme ≈ iki adım.
        public var averagePeriod: Double { 2 * cycleDuration / Double(steps.count) }
    }

    /// Adım süresi çarpanları: aynı çubukta bile adımlar eşit uzunlukta değil (metronom hissini kırar).
    private static let rhythm: [Double] = [1.0, 0.86, 1.14, 0.93, 1.07, 0.9, 1.1, 0.95, 1.05, 1.0]

    private static func bar(range: ClosedRange<Double>, pattern: [Double], period: Double,
                            phase: Int, rhythmOffset: Int) -> Bar {
        let count = pattern.count
        let levels = (0..<count).map { index in
            range.lowerBound + (range.upperBound - range.lowerBound) * pattern[(index + phase) % count]
        }
        let steps = (0..<count).map { index in period / 2 * rhythm[(index + rhythmOffset) % rhythm.count] }
        return Bar(levels: levels, steps: steps)
    }

    /// Soldan sağa 5 çubuk. Kenarlar kısa hareketler yapar (en fazla ~%72), orta çubuk zaman zaman
    /// belirgin uzar; böylece beşi birden hiçbir zaman tepeye ulaşmaz ve grup merkezden atıyormuş görünür.
    /// Bir iniş-çıkış süreleri: 0,82 · 0,68 · 0,96 · 0,74 · 1,05 sn.
    public static let bars: [Bar] = [
        bar(range: 0.20...0.74, pattern: [0.10, 0.55, 0.30, 0.85, 0.45, 0.15, 0.62, 0.38, 0.75, 0.25],
            period: 0.82, phase: 0, rhythmOffset: 0),
        bar(range: 0.24...0.88, pattern: [0.55, 0.20, 0.72, 0.40, 0.65, 0.90, 0.35, 0.58, 0.15, 0.68],
            period: 0.68, phase: 3, rhythmOffset: 5),
        bar(range: 0.30...1.00, pattern: [0.35, 0.80, 0.50, 0.20, 0.70, 0.95, 0.55, 0.30, 0.85, 0.60],
            period: 0.96, phase: 6, rhythmOffset: 2),
        bar(range: 0.24...0.90, pattern: [0.68, 0.38, 0.15, 0.75, 0.48, 0.25, 0.82, 0.52, 0.32, 0.58],
            period: 0.74, phase: 1, rhythmOffset: 7),
        bar(range: 0.18...0.72, pattern: [0.25, 0.62, 0.80, 0.30, 0.52, 0.12, 0.70, 0.45, 0.78, 0.38],
            period: 1.05, phase: 8, rhythmOffset: 4),
    ]

    /// Duraklatıldığında yerleşilen sakin form: ▃ ▂ ▃ ▂ ▃.
    public static let restingLevels: [Double] = [0.30, 0.18, 0.34, 0.20, 0.28]

    /// Duraklatma ve yeniden başlama geçişi (istenen 150–250 ms bandının ortası).
    public static let settleDuration: Double = 0.2

    /// Nabzın saniyedeki örnek sayısı. Animasyon, bu hızda örneklenmiş **ayrık** anahtar karelerdir: iki örnek
    /// arasında değer değişmediği için render sunucusu ProMotion ekranda (120 Hz) her kareyi yeniden birleştirmez.
    /// Ölçüm (ProMotion built-in ekran, müzik çalarken, 3 tur, 40 sn'de WindowServer CPU süresi):
    /// sürekli enterpolasyon + 30 fps ipucu 14,5 sn · 24 örnek/sn 11,9 sn · 12 örnek/sn 11,6 sn · sabit nabız 11,3 sn.
    /// Yani kare hızı *ipucu* bu ekranda işe yaramıyordu; ayrık örnekleme nabzın maliyetinin ~%80'ini kaldırıyor.
    /// 24 örnek/sn, çubukların yavaş (0,3–0,5 sn'lik) hareketinde enterpolasyondan ayırt edilemeyecek kadar akıcıdır.
    public static let sampleRate: Double = 24

    /// Kare hızı ipucu (örnekleme hızıyla aynı; ayrık anahtar karelerde yalnızca tutarlılık için).
    public static let maximumFrameRate: Float = Float(sampleRate)

    /// Bir çubuğun döngüsünü `rate` örnek/sn ile örnekler. Örnekler döngüye eşit aralıklıdır
    /// (`t = i · döngü / sayı`), böylece döngü sonu ilk örneğe dikişsiz bağlanır; gerçek hız `rate`'e en yakın tam sayıdır.
    public static func sampledLevels(bar index: Int, rate: Double = sampleRate) -> [Double] {
        let cycle = bars[index].cycleDuration
        let count = max(Int((cycle * rate).rounded()), 2)
        return (0..<count).map { level(bar: index, at: Double($0) * cycle / Double(count)) }
    }

    /// Test ve analiz için: CA'nın `easeInEaseOut` adımlarına denk, monoton (aşımsız) enterpolasyon.
    public static func level(bar index: Int, at time: Double) -> Double {
        let bar = bars[index]
        let cycle = bar.cycleDuration
        var t = time.truncatingRemainder(dividingBy: cycle)
        if t < 0 { t += cycle }
        for (step, duration) in bar.steps.enumerated() {
            if t <= duration {
                let from = bar.levels[step]
                let to = bar.levels[(step + 1) % bar.levels.count]
                let x = duration > 0 ? t / duration : 1
                let eased = x * x * (3 - 2 * x)
                return from + (to - from) * eased
            }
            t -= duration
        }
        return bar.levels[0]
    }
}
