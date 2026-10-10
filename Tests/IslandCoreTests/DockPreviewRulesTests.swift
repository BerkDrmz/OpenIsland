import Foundation
import Testing
@testable import IslandCore

@Suite("Dock pencere önizlemeleri")
struct DockPreviewRulesTests {
    @Test func ignoresInteriorAndSupportsDisplaysWithNegativeOrigins() {
        let screens = [CGRect(x: 0, y: 0, width: 1710, height: 1107), CGRect(x: -1920, y: 300, width: 1920, height: 1080)]
        #expect(!DockPreviewRules.nearDockEdge(CGPoint(x: 800, y: 600), screens: screens))
        #expect(!DockPreviewRules.nearDockEdge(CGPoint(x: -800, y: 1000), screens: screens))
        for point in [CGPoint(x: 500, y: 20), CGPoint(x: 15, y: 800), CGPoint(x: 1695, y: 700),
                      CGPoint(x: -1900, y: 600), CGPoint(x: -500, y: 315)] {
            #expect(DockPreviewRules.nearDockEdge(point, screens: screens))
        }
        #expect(!DockPreviewRules.nearDockEdge(CGPoint(x: 4000, y: 40), screens: screens))
    }

    @Test func panelsStayInsideVisibleScreenForEveryDockPosition() {
        for screen in [CGRect(x: 0, y: 0, width: 1710, height: 1107), CGRect(x: -1920, y: -500, width: 1920, height: 1080)] {
            let visible = screen.insetBy(dx: 0, dy: 32)
            let anchors = [CGRect(x: screen.midX, y: screen.minY + 4, width: 52, height: 68),
                           CGRect(x: screen.minX + 4, y: screen.maxY - 100, width: 68, height: 52),
                           CGRect(x: screen.maxX - 72, y: screen.minY + 100, width: 68, height: 52)]
            for (index, anchor) in anchors.enumerated() {
                #expect(DockPreviewRules.edge(anchor: anchor, screen: screen) == [.bottom, .left, .right][index])
                for count in [1, 3, 50] {
                    let panel = DockPreviewRules.panelFrame(anchor: anchor, screen: screen, visibleFrame: visible,
                        windowCount: count, permissionFooter: true)
                    #expect(visible.contains(panel))
                    #expect(panel.width <= 800)
                    #expect(panel.height == DockPreviewRules.permissionPanelHeight)
                }
            }
        }
    }

    @Test func hoverBridgeDoesNotSwallowNeighbouringDockIcons() {
        let anchor = CGRect(x: 500, y: 4, width: 52, height: 68)
        let panel = CGRect(x: 300, y: 80, width: 800, height: 220)
        let bridge = DockPreviewRules.bridge(anchor: anchor, panel: panel, edge: .bottom)
        #expect(bridge.contains(CGPoint(x: 526, y: 76)))
        #expect(!bridge.contains(CGPoint(x: 580, y: 40)))
        #expect(!bridge.contains(CGPoint(x: 580, y: 76)))
    }

    @Test func thumbnailMatchingHandlesDuplicateTitlesAndRejectsAmbiguousSurfaces() {
        let first = DockPreviewRules.WindowIdentity(title: "Document", frame: CGRect(x: 20, y: 30, width: 700, height: 500))
        let second = DockPreviewRules.WindowIdentity(title: "Document", frame: CGRect(x: 800, y: 30, width: 700, height: 500))
        #expect(DockPreviewRules.captureIndex(for: second, candidates: [first, second]) == 1)
        #expect(DockPreviewRules.captureIndex(for: first, candidates: [second, first]) == 1)
        let unknown = DockPreviewRules.WindowIdentity(title: "Document", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(DockPreviewRules.captureIndex(for: unknown, candidates: [first, second]) == nil)
        let unnamed = DockPreviewRules.WindowIdentity(title: "", frame: first.frame)
        #expect(DockPreviewRules.captureIndex(for: unnamed, candidates: [first]) == 0)
        #expect(DockPreviewRules.captureIndex(for: unnamed, candidates: [first, first]) == nil)
    }
}
