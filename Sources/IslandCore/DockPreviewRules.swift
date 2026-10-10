import Foundation

/// Dock previews have no polling clock: these limits apply only to incoming pointer events.
public enum DockPreviewRules {
    public static let hoverDelay = 0.28
    public static let exitGrace = 0.16
    public static let probeInterval = 0.08
    public static let cardWidth: CGFloat = 164
    public static let cardImageHeight: CGFloat = 96
    public static let cardRowHeight: CGFloat = 122
    public static let panelHeight: CGFloat = 168
    public static let permissionPanelHeight: CGFloat = 208
    public static let thumbnailPixels = CGSize(width: 320, height: 200)
    public static let concurrentCaptures = 2

    public enum Edge: Sendable { case bottom, left, right }

    public static func nearDockEdge(_ point: CGPoint, screens: [CGRect], band: CGFloat = 160) -> Bool {
        screens.contains { screen in
            screen.contains(point) && (point.y - screen.minY < band
                || point.x - screen.minX < band || screen.maxX - point.x < band)
        }
    }

    public static func edge(anchor: CGRect, screen: CGRect) -> Edge {
        let bottom = abs(anchor.midY - screen.minY)
        let left = abs(anchor.midX - screen.minX)
        let right = abs(screen.maxX - anchor.midX)
        if bottom <= min(left, right) { return .bottom }
        return left < right ? .left : .right
    }

    public static func panelFrame(anchor: CGRect, screen: CGRect, visibleFrame: CGRect,
                                  windowCount: Int, permissionFooter: Bool) -> CGRect {
        let safe = visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(CGFloat(max(1, windowCount)) * (cardWidth + 8) + 12, min(800, safe.width))
        let height = min(permissionFooter ? permissionPanelHeight : panelHeight, safe.height)
        var origin: CGPoint
        switch edge(anchor: anchor, screen: screen) {
        case .bottom: origin = CGPoint(x: anchor.midX - width / 2, y: anchor.maxY + 8)
        case .left: origin = CGPoint(x: anchor.maxX + 8, y: anchor.midY - height / 2)
        case .right: origin = CGPoint(x: anchor.minX - width - 8, y: anchor.midY - height / 2)
        }
        origin.x = min(max(origin.x, safe.minX), safe.maxX - width)
        origin.y = min(max(origin.y, safe.minY), safe.maxY - height)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    /// Only the narrow gap from this icon to the panel keeps the hover alive. A broad union
    /// would swallow neighbouring icons and prevent switching previews between applications.
    public static func bridge(anchor: CGRect, panel: CGRect, edge: Edge) -> CGRect {
        switch edge {
        case .bottom:
            CGRect(x: anchor.minX - 6, y: anchor.maxY - 2, width: anchor.width + 12,
                   height: max(0, panel.minY - anchor.maxY) + 4)
        case .left:
            CGRect(x: anchor.maxX - 2, y: anchor.minY - 6, width: max(0, panel.minX - anchor.maxX) + 4,
                   height: anchor.height + 12)
        case .right:
            CGRect(x: panel.maxX - 2, y: anchor.minY - 6, width: max(0, anchor.minX - panel.maxX) + 4,
                   height: anchor.height + 12)
        }
    }

    public struct WindowIdentity: Equatable, Sendable {
        public var title: String
        public var frame: CGRect
        public init(title: String, frame: CGRect) { self.title = title; self.frame = frame }
    }

    /// Public AX title/geometry identifies the real windows; ScreenCaptureKit also lists
    /// auxiliary surfaces. Never blindly equate every layer-zero surface with a user window.
    public static func captureIndex(for window: WindowIdentity, candidates: [WindowIdentity]) -> Int? {
        func sameFrame(_ other: CGRect) -> Bool {
            abs(window.frame.minX - other.minX) < 8 && abs(window.frame.minY - other.minY) < 8
                && abs(window.frame.width - other.width) < 8 && abs(window.frame.height - other.height) < 8
        }
        let titles = candidates.indices.filter { !window.title.isEmpty && candidates[$0].title == window.title }
        if let exact = titles.first(where: { sameFrame(candidates[$0].frame) }) { return exact }
        if titles.count == 1 { return titles.first }
        let frames = candidates.indices.filter { sameFrame(candidates[$0].frame) }
        return frames.count == 1 ? frames.first : nil
    }
}
