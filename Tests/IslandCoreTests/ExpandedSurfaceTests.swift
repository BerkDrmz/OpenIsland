import CoreGraphics
import Testing
@testable import IslandCore

struct ExpandedSurfaceTests {
    @Test func systemPanelAlignsColumnsAndFitsStorageWithoutGrowingTabHeader() {
        let metrics = NotchMetrics(notchSize: CGSize(width: 185, height: 33.5), style: .notch)
        #expect(IslandLayoutEngine.contentSize(for: .system, metrics: metrics) == CGSize(width: 539, height: 166.5))
        #expect(IslandLayoutEngine.System.columnWidths == [140, 190, 160])
        #expect(CGFloat(IslandLayoutEngine.tabsPerSide) * IslandLayoutEngine.tabButtonSize.width + CGFloat(IslandLayoutEngine.tabsPerSide - 1) * IslandLayoutEngine.tabSpacing == 80)
    }

    @Test func compactOnlyRemovesOuterSpace() {
        for scale: CGFloat in [1, 2] {
            for widgets in 1...3 {
                for count in [0, 1, 3, 99] {
                    let standard = NotchMetrics(notchSize: CGSize(width: 185, height: 33.5), style: .notch,
                                                scale: scale, nookWidgetCount: widgets,
                                                content: ExpandedContent(clipboardItems: count, shelfItems: count,
                                                                         upcomingEvents: count, reminders: count,
                                                                         launcherItems: count))
                    var compact = standard
                    compact.expandedSurfaceSize = .compact
                    for tab in ExpandedTab.allCases {
                        let old = IslandLayoutEngine.layout(for: .expanded(tab), metrics: standard)
                        let new = IslandLayoutEngine.layout(for: .expanded(tab), metrics: compact)
                        let oldSide = IslandLayoutEngine.contentSideInset(for: old, style: .notch)
                        let newSide = IslandLayoutEngine.contentSideInset(for: new, style: .notch, size: .compact)
                        #expect(old.size.width - new.size.width == 8)
                        #expect(old.size.height - new.size.height == 4)
                        #expect(old.size.width - oldSide * 2 == new.size.width - newSide * 2)
                        #expect(old.size.height - IslandLayoutEngine.expandedBottomInset(for: standard)
                                == new.size.height - IslandLayoutEngine.expandedBottomInset(for: compact))
                        #expect(-old.size.width / 2 + oldSide == -new.size.width / 2 + newSide)
                        #expect(IslandLayoutEngine.contentSize(for: tab, metrics: standard)
                                == IslandLayoutEngine.contentSize(for: tab, metrics: compact))
                        #expect(new.topInset == 0 && new.elevation == 0 && new.edgeHighlight == 0)
                    }
                }
            }
        }
    }

    @Test func mediaLayersKeepTheirScreenPositionAndSize() throws {
        let standard = NotchMetrics(notchSize: CGSize(width: 185, height: 33.5), style: .notch)
        var compact = standard
        compact.expandedSurfaceSize = .compact
        for tab in [ExpandedTab.media, .nook] {
            let presentation = IslandPresentation.expanded(tab)
            let oldLayout = IslandLayoutEngine.layout(for: presentation, metrics: standard)
            let newLayout = IslandLayoutEngine.layout(for: presentation, metrics: compact)
            let old = try #require(IslandLayoutEngine.artworkSlot(for: presentation, metrics: standard))
            let new = try #require(IslandLayoutEngine.artworkSlot(for: presentation, metrics: compact))
            #expect(old.rect.size == new.rect.size && old.cornerRadius == new.cornerRadius)
            #expect(old.rect.minY == new.rect.minY)
            #expect(old.rect.minX - oldLayout.size.width / 2 == new.rect.minX - newLayout.size.width / 2)
        }
        let old = try #require(IslandLayoutEngine.waveformSlot(for: .expanded(.media), metrics: standard))
        let new = try #require(IslandLayoutEngine.waveformSlot(for: .expanded(.media), metrics: compact))
        let oldWidth = IslandLayoutEngine.layout(for: .expanded(.media), metrics: standard).size.width
        let newWidth = IslandLayoutEngine.layout(for: .expanded(.media), metrics: compact).size.width
        #expect(old.size == new.size && old.minY == new.minY)
        #expect(old.minX - oldWidth / 2 == new.minX - newWidth / 2)
    }

    @Test func tabsFitOutsideHardwareNotch() {
        for width: CGFloat in [156, 185, 210] {
            let compact = NotchMetrics(notchSize: CGSize(width: width, height: 33.5), style: .notch,
                                       expandedSurfaceSize: .compact)
            for tab in ExpandedTab.allCases {
                let layout = IslandLayoutEngine.layout(for: .expanded(tab), metrics: compact)
                let wing = (layout.size.width - width) / 2
                let buttons = CGFloat(IslandLayoutEngine.tabsPerSide) * IslandLayoutEngine.tabButtonSize.width
                #expect(wing >= buttons + IslandLayoutEngine.headerSidePadding(style: .notch, size: .compact))
                #expect(layout.size.width - layout.topCornerRadius * 2 > width)
            }
        }
    }

    @Test func settingKeepsCanvasAndOtherPresentationsUnchanged() {
        let standard = NotchMetrics(notchSize: CGSize(width: 185, height: 33.5), style: .notch)
        var compact = standard
        compact.expandedSurfaceSize = .compact
        #expect(IslandLayoutEngine.canvasSize(for: standard) == IslandLayoutEngine.canvasSize(for: compact))
        let resting: [IslandPresentation] = [.idle, .compact(.media), .peek(nil), .peek(.media),
                                             .hud(HUDPayload(kind: .brightness, level: 0.5)),
                                             .notice(.unlocked), .dropTarget]
        for presentation in resting {
            #expect(IslandLayoutEngine.layout(for: presentation, metrics: standard)
                    == IslandLayoutEngine.layout(for: presentation, metrics: compact))
        }
    }

    @Test func unnotchedDisplayKeepsItsExistingGeometry() {
        let standard = NotchMetrics.pill(menuBarHeight: 24)
        var compact = standard
        compact.expandedSurfaceSize = .compact
        for tab in ExpandedTab.allCases {
            #expect(IslandLayoutEngine.layout(for: .expanded(tab), metrics: standard)
                    == IslandLayoutEngine.layout(for: .expanded(tab), metrics: compact))
            #expect(IslandLayoutEngine.artworkSlot(for: .expanded(tab), metrics: standard)
                    == IslandLayoutEngine.artworkSlot(for: .expanded(tab), metrics: compact))
        }
    }
}
