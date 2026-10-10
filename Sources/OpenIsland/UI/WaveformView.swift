import AppKit
import IslandCore
import QuartzCore
import SwiftUI

/// Dynamic Island tarzı "müzik nabzı": birbirine yakın, dikey, tam yuvarlatılmış 5 çubuk.
///
/// Tamamen tahminidir: ses kaydedilmez ve analiz edilmez (tap, FFT, ses geri çağrısı, izin istemi yok).
/// `CompactPulse` desenleri çubuk başına bir `CAKeyframeAnimation` olarak render sunucusunda döner (30 Hz üst
/// sınır); süreç yalnızca çalıyor/duraklatıldı değişiminde uyanır. Çubuklar kendi dikey merkezlerinden büyüyüp
/// küçülür; grubun merkezi sabittir. Duraklatınca 0,2 sn'de sakin forma (▃▂▃▂▃), yeniden çalınca 0,2 sn'de
/// desene geçer; her geçiş ekranda görünen yükseklikten başlar (sıçrama yok).
/// Hareketi Azalt'ta ve pil tasarrufunda (Düşük Güç Modu / ısınma) desen ilk karesinde sabit kalır: render
/// sunucusunda sürekli dönen animasyon yoktur.
struct WaveformView: NSViewRepresentable {
    let isPlaying: Bool
    let color: NSColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandEnergySaving) private var energySaving

    func makeNSView(context: Context) -> WaveformLayerView {
        WaveformLayerView()
    }

    func updateNSView(_ view: WaveformLayerView, context: Context) {
        view.update(isPlaying: isPlaying, color: color, reduceMotion: reduceMotion || energySaving)
    }

    static func dismantleNSView(_ view: WaveformLayerView, coordinator: ()) {
        view.stopAnimations()
    }
}

@MainActor
final class WaveformLayerView: NSView {
    private enum Mode: Equatable { case resting, estimated }

    private static let heightKey = "bounds.size.height"
    private static let pulseKey = "pulse"
    private static let transitionKey = "transition"
    private static let settleTiming = CAMediaTimingFunction(name: .easeOut)
    private static let estimatedFrameRate = CAFrameRateRange(
        minimum: 10, maximum: CompactPulse.maximumFrameRate, preferred: CompactPulse.maximumFrameRate)

    /// The normalized rhythm and key times never depend on view size or playback state.
    private static let pulseSamples = CompactPulse.bars.indices.map { index in
        let levels = CompactPulse.sampledLevels(bar: index).map { CGFloat($0) }
        let times = levels.indices.map { NSNumber(value: Double($0) / Double(levels.count)) }
        // All bars share the same 24 Hz grid. Keeping each original fractional
        // duration made their discrete changes fall on different frames, potentially
        // refreshing the compositor five times as often. Round each cycle by at most
        // half a sample; independent shapes/rhythms and their seamless loop remain.
        return (levels: levels, times: times, duration: Double(levels.count) / CompactPulse.sampleRate)
    }

    private let bars: [CALayer]
    private var color: NSColor = IslandPalette.pulseNSColor
    private var mode: Mode?
    private var reduceMotion = false
    /// Model yüksekliklerinin seviyeleri (0…1): yeniden yerleşimde animasyonsuz korunur.
    private var targets: [CGFloat]
    /// Animasyonların hesaplandığı boyut. Boyut değişince (ilk yerleşim, kompakt ↔ genişletilmiş) mod
    /// yeniden uygulanır; aksi halde animasyonlar yalnızca mod değişiminde kurulur.
    private var appliedSize: CGSize = .zero
    private var laidOutBounds: CGRect?
    private var laidOutScale: CGFloat = 0

    init() {
        targets = CompactPulse.restingLevels.map { CGFloat($0) }
        bars = CompactPulse.bars.indices.map { _ in CALayer() }
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        for bar in bars {
            bar.backgroundColor = color.cgColor
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5) // dikeyde merkezden büyür: grup yukarı-aşağı zıplamaz
            layer?.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) desteklenmiyor") }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        guard bounds != laidOutBounds || scale != laidOutScale else { return }
        laidOutBounds = bounds
        laidOutScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = barWidth
        let spacing = barSpacing
        // Grup yuvanın sağ kenarına yaslanır: sol kanattaki kapakla çentiğe göre ayna simetrik.
        for (index, bar) in bars.enumerated() {
            let fromTrailing = CGFloat(bars.count - 1 - index)
            let x = bounds.maxX - width / 2 - fromTrailing * (width + spacing)
            bar.position = CGPoint(x: (x * scale).rounded() / scale, y: bounds.midY)
            bar.bounds.size = CGSize(width: width, height: height(for: targets[index]))
            bar.cornerRadius = width / 2
        }
        CATransaction.commit()
        if bounds.size != appliedSize, let mode {
            // A resize changes heights, not playback phase. In particular, the
            // island's spring must not repeatedly restart five settle animations
            // and postpone the pulse by another 0.2 seconds on every layout.
            let pulseBegin = appliedSize == .zero ? nil : bars.first?.animation(forKey: Self.pulseKey)?.beginTime
            appliedSize = bounds.size
            apply(mode, animated: true, preservingPulseBegin: pulseBegin)
        }
    }

    func update(isPlaying: Bool, color: NSColor, reduceMotion: Bool) {
        if color != self.color {
            self.color = color
            bars.forEach { $0.backgroundColor = color.cgColor } // örtük CA animasyonuyla yumuşak geçiş
        }
        let newMode: Mode = isPlaying ? .estimated : .resting
        guard newMode != mode || reduceMotion != self.reduceMotion else { return }
        let isFirst = mode == nil
        self.reduceMotion = reduceMotion
        mode = newMode
        apply(newMode, animated: !isFirst)
    }

    // MARK: - Modlar

    func stopAnimations() {
        bars.forEach { $0.removeAllAnimations() }
        mode = nil
    }

    private func apply(_ mode: Mode, animated: Bool, preservingPulseBegin: CFTimeInterval? = nil) {
        guard bounds.height > 0 else { return } // ilk yerleşimde yeniden uygulanır
        let now = layer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()
        let entry: CFTimeInterval
        if let preservingPulseBegin {
            // Finish an entry already in progress on its original deadline.
            // A settled pulse needs no extra transition while resizing.
            entry = max(preservingPulseBegin - now, 0)
        } else {
            entry = animated && !reduceMotion ? CompactPulse.settleDuration : 0
        }

        switch mode {
        case .resting:
            transition(to: CompactPulse.restingLevels.map { CGFloat($0) }, duration: entry)

        case .estimated:
            let firsts = CompactPulse.bars.map { CGFloat($0.levels[0]) }
            transition(to: firsts, duration: entry)
            guard !reduceMotion else { return } // Hareketi Azalt: desenin ilk karesinde sabit
            let begin = preservingPulseBegin ?? (now + entry)
            for (index, bar) in bars.enumerated() {
                bar.add(Self.pulseAnimation(index: index, heights: height(for:), begin: begin), forKey: Self.pulseKey)
            }
        }
    }

    /// Desen: döngü, `CompactPulse.sampleRate` hızında örneklenmiş **ayrık** anahtar kareler. Sürekli enterpolasyon
    /// (`calculationMode = .linear`) render sunucusunu ekranın tam yenileme hızında (ProMotion'da 120 Hz) uyandırıyordu
    /// ve kare hızı ipucu etkili değildi (ölçüm: `CompactPulse.sampleRate`). Örnekler `level(bar:at:)` ile aynı
    /// yumuşak, aşımsız eğriden alınır; döngü sonu ilk örneğe dikişsiz bağlanır.
    private static func pulseAnimation(index: Int, heights: (CGFloat) -> CGFloat,
                                       begin: CFTimeInterval) -> CAKeyframeAnimation {
        let samples = pulseSamples[index]
        let animation = CAKeyframeAnimation(keyPath: heightKey)
        animation.values = samples.levels.map(heights)
        animation.keyTimes = samples.times
        animation.calculationMode = .discrete
        animation.duration = samples.duration
        animation.repeatCount = .infinity
        animation.beginTime = begin
        animation.preferredFrameRateRange = estimatedFrameRate
        return animation
    }

    /// Ekranda görünen yükseklikten hedef seviyelere `duration` içinde geçer (0 ise anında).
    private func transition(to levels: [CGFloat], duration: CFTimeInterval) {
        let current = bars.map { $0.presentation()?.bounds.height ?? $0.bounds.height }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: Self.pulseKey)
            targets[index] = levels[index]
            let target = height(for: levels[index])
            bar.bounds.size.height = target
            guard duration > 0 else { bar.removeAnimation(forKey: Self.transitionKey); continue }
            let animation = CABasicAnimation(keyPath: Self.heightKey)
            animation.fromValue = current[index]
            animation.toValue = target
            animation.duration = duration
            animation.timingFunction = Self.settleTiming
            bar.add(animation, forKey: Self.transitionKey)
        }
        CATransaction.commit()
    }

    // MARK: - Geometri

    /// Çubuk kalınlığı yuva yüksekliğinin ~%20'si, yarım noktaya yuvarlı (kompakt 12 pt → 2,5 pt,
    /// genişletilmiş 18 pt → 3,5 pt). Kalınlık aynı zamanda en kısa boydur: sakin formda çubuklar noktaya iner.
    private var barWidth: CGFloat {
        min(max((bounds.height * 0.2 * 2).rounded() / 2, 2), 3.5)
    }

    /// Çubuklar birbirine yakın: aralık kalınlığın ~%80'i (kompakt 2 pt, genişletilmiş 3 pt).
    private var barSpacing: CGFloat {
        (barWidth * 0.8 * 2).rounded() / 2
    }

    private func height(for level: CGFloat) -> CGFloat {
        let minimum = barWidth
        return minimum + max(bounds.height - minimum, 0) * min(max(level, 0), 1)
    }
}
