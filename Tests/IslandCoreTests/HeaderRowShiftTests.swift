import CoreGraphics
import Testing
@testable import IslandCore

/// `headerRowShift` beklenen değerleri, gerçek SwiftUI yığınının ölçülen konumlarından alındı
/// (Evidence/20261015-k5k6/harness/HeaderShiftEquivalence.swift: 180 yapılandırma, 22.860 genişlikte birebir).
@Suite("Başlık satırı kayması") struct HeaderRowShiftTests {
    /// Kompakt yüzey, 185 pt çentik: solda 5 sekme (80 pt), sağda 4 sekme + iğne (85,95 pt), yan boşluk 8.
    private func shift(_ width: CGFloat, scale: CGFloat = 2) -> CGFloat? {
        IslandLayoutEngine.headerRowShift(bodyWidth: width, sidePadding: 8, centerGap: 185,
                                          leadingRowWidth: 80, trailingRowWidth: 85.95, scale: scale)
    }

    @Test func wideBodiesKeepTheGapCentred() {
        #expect(shift(380) == 0)
        #expect(shift(672) == 0)
        #expect(shift(374) == 0)
    }

    @Test func narrowBodiesShiftByHalfTheRowDifferenceRoundedToPixels() {
        // Harness ölçümü: 340 pt gövdede her düğme 3 pt sola kayar.
        #expect(shift(340) == -3)
        #expect(shift(361) == -3)
    }

    @Test func intermediateBodiesShiftPartially() {
        // rest = 370 − 16 − 185 = 169 → sol pay 169 − 85,95 = 83,05 → kayma −1,45 → 2× pikselde −1,5.
        #expect(shift(370) == -1.5)
    }

    @Test func halfPointStepsAtOneTimesScaleUseTheOriginalLayout() {
        #expect(shift(340, scale: 1) == nil)
    }

    @Test func nonFiniteInputUsesTheOriginalLayout() {
        #expect(shift(.nan) == nil)
        #expect(shift(.infinity) == nil)
    }

    @Test func longerLeadingRowShiftsRight() {
        let value = IslandLayoutEngine.headerRowShift(bodyWidth: 340, sidePadding: 8, centerGap: 185,
                                                      leadingRowWidth: 90, trailingRowWidth: 80, scale: 2)
        #expect(value == 5)
    }

    @Test func unalignedLeadingRowOrExactHalfPixelUsesTheOriginalLayout() {
        // Sol satır tam piksel değilse simetrik konumlar da değildir.
        #expect(IslandLayoutEngine.headerRowShift(bodyWidth: 340, sidePadding: 8, centerGap: 185,
                                                  leadingRowWidth: 85.95, trailingRowWidth: 80, scale: 2) == nil)
        // (96,5 − 80) / 2 = 8,25 pt = 16,5 piksel: yuvarlama yönü yığına göre belirsiz.
        #expect(IslandLayoutEngine.headerRowShift(bodyWidth: 340, sidePadding: 8, centerGap: 185,
                                                  leadingRowWidth: 96.5, trailingRowWidth: 80, scale: 2) == nil)
    }
}
