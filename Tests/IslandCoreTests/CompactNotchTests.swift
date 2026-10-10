import CoreGraphics
import Testing
@testable import IslandCore

@Suite("Fiziksel çentikle bütünleşen küçük ada")
struct CompactNotchTests {
    @Test func restingAndHoverHeightsMatchHardwareNotchHeight() {
        for height: CGFloat in [24, 28.25, 30, 32, 33.5, 38.2] {
            for scale: CGFloat in [1, 2, 3] {
                let metrics = NotchMetrics(notchSize: CGSize(width: 185, height: height), style: .notch, scale: scale)
                let states: [IslandPresentation] = [.idle, .compact(.media), .compact(.timer),
                    .compact(.transfer), .compact(.shelf), .peek(nil), .peek(.media), .peek(.timer),
                    .hud(HUDPayload(kind: .brightness, level: 0.5))]
                for state in states {
                    let layout = IslandLayoutEngine.layout(for: state, metrics: metrics)
                    #expect(abs(layout.size.height - height) <= 0.5 / scale + 0.10 + 0.0001, "Çentikle aynı yükseklik (piksel yuvarlama + 0,10 pt kırpma)")
                    #expect(layout.topInset == 0 && layout.elevation == 0 && layout.edgeHighlight == 0)
                    #expect(layout.bottomCornerRadius <= layout.size.height)
                }
                let compact = IslandLayoutEngine.layout(for: .compact(.media), metrics: metrics)
                let hover = IslandLayoutEngine.layout(for: .peek(.media), metrics: metrics)
                #expect(compact.size.height == hover.size.height)
                #expect(hover.size.width > compact.size.width)
            }
        }
    }

    @Test func mediaStaysCenteredInsideBothWings() throws {
        for height: CGFloat in [24, 28.25, 33.5, 38.2] {
            let metrics = NotchMetrics(notchSize: CGSize(width: 185, height: height), style: .notch)
            for state in [IslandPresentation.compact(.media), .peek(.media)] {
                let layout = IslandLayoutEngine.layout(for: state, metrics: metrics)
                let artwork = try #require(IslandLayoutEngine.artworkSlot(for: state, metrics: metrics))
                let waveform = try #require(IslandLayoutEngine.waveformSlot(for: state, metrics: metrics))
                #expect(artwork.rect.midY == layout.size.height / 2)
                #expect(waveform.midY == layout.size.height / 2)
                #expect(artwork.rect.minY >= 0 && artwork.rect.maxY <= layout.size.height)
                #expect(waveform.minY >= 0 && waveform.maxY <= layout.size.height)
                #expect(artwork.rect.maxX <= (layout.size.width - metrics.notchSize.width) / 2)
                #expect(waveform.minX >= (layout.size.width + metrics.notchSize.width) / 2)
            }
        }
    }

    @Test func expandedGeometryStillUsesUnmodifiedHardwareHeight() {
        for height: CGFloat in [28.25, 33.5, 38.2] {
            for surface in ExpandedSurfaceSize.allCases {
                let metrics = NotchMetrics(notchSize: CGSize(width: 185, height: height), style: .notch,
                                           expandedSurfaceSize: surface)
                for tab in ExpandedTab.allCases {
                    let content = IslandLayoutEngine.contentSize(for: tab, metrics: metrics)
                    let layout = IslandLayoutEngine.layout(for: .expanded(tab), metrics: metrics)
                    let expected = height + IslandLayoutEngine.headerGap + content.height
                        + IslandLayoutEngine.expandedBottomInset(for: metrics)
                    #expect(layout.size.height == IslandLayoutEngine.pixelAligned(expected, scale: metrics.scale))
                }
            }
        }
    }

    @Test func unnotchedDisplayKeepsItsVerticalHoverAnimation() {
        let metrics = NotchMetrics.pill(menuBarHeight: 24)
        let compact = IslandLayoutEngine.layout(for: .compact(.media), metrics: metrics)
        let hover = IslandLayoutEngine.layout(for: .peek(.media), metrics: metrics)
        #expect(compact.size.height == 30)
        #expect(hover.size.height == compact.size.height + IslandLayoutEngine.hoverSwell.height)
        #expect(hover.topInset == metrics.floatOffset)
    }
}
