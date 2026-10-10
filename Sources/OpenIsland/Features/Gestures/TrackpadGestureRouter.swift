import AppKit
import IslandCore

/// Ada üzerindeki iki parmak trackpad kaydırmalarını jestlere çevirir.
///
/// - Yatay kaydırma (tek tetik/jest): sola → sonraki parça, sağa → önceki parça (`reversesTrackDirection` ile tersi).
/// - Dikey kaydırma (sürekli): yukarı → ses artar, aşağı → ses azalır.
/// - Genişletilmiş görünümde olaylar içeriğe (ScrollView'lar) bırakılır.
/// "Doğal kaydırma" ayarı `isDirectionInvertedFromDevice` ile normalize edilir; böylece jest
/// her zaman parmak hareketinin fiziksel yönünü izler. Momentum (atalet) olayları yutulur.
@MainActor
final class TrackpadGestureRouter {
    private enum Axis { case horizontal, vertical }

    var onNextTrack: () -> Void = {}
    var onPreviousTrack: () -> Void = {}
    var onVolumeStep: (Float) -> Void = { _ in }
    /// Ayar: sağa kaydırma sonraki parçaya geçer (dikey ses jesti etkilenmez).
    var reversesTrackDirection = false

    private var axis: Axis?
    private var accumulated = CGSize.zero
    private var didTriggerTrack = false
    private var volumeRemainder: CGFloat = 0

    private let axisLockDistance: CGFloat = 8
    private let trackSwipeDistance: CGFloat = 60
    private let volumeStepDistance: CGFloat = 12

    /// `true` dönerse olay tüketilir.
    func handle(_ event: NSEvent, phase: IslandPhase) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false } // fare tekerleği
        if case .expanded = phase { return false }
        if !event.momentumPhase.isEmpty { return true }

        switch event.phase {
        case .began, .mayBegin:
            reset()
        case .changed:
            let inverted = event.isDirectionInvertedFromDevice
            let fingerRight = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
            let fingerUp = inverted ? -event.scrollingDeltaY : event.scrollingDeltaY
            accumulated.width += fingerRight
            accumulated.height += fingerUp

            if axis == nil, hypot(accumulated.width, accumulated.height) > axisLockDistance {
                axis = abs(accumulated.width) > abs(accumulated.height) ? .horizontal : .vertical
            }
            switch axis {
            case .horizontal where !didTriggerTrack && abs(accumulated.width) > trackSwipeDistance:
                didTriggerTrack = true
                (accumulated.width < 0) != reversesTrackDirection ? onNextTrack() : onPreviousTrack()
            case .vertical:
                volumeRemainder += fingerUp
                while abs(volumeRemainder) >= volumeStepDistance {
                    let direction: CGFloat = volumeRemainder > 0 ? 1 : -1
                    onVolumeStep(Float(direction) / 32)
                    volumeRemainder -= direction * volumeStepDistance
                }
            default:
                break
            }
        case .ended, .cancelled:
            reset()
        default:
            break
        }
        return true
    }

    private func reset() {
        axis = nil
        accumulated = .zero
        didTriggerTrack = false
        volumeRemainder = 0
    }
}
