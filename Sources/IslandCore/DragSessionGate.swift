/// Destinations shared by the native receiver and SwiftUI highlight.
public enum IslandDropZone: Equatable, Sendable { case shelf, airDrop }

/// A drag pasteboard must change during the current mouse gesture before an
/// invisible drop receiver may take input. Old clipboard/drag contents cannot
/// turn an ordinary window drag into a file drop.
public struct DragSessionGate: Sendable {
    private var baseline: Int
    public private(set) var isActive = false

    public init(changeCount: Int) { baseline = changeCount }

    // AppKit can clear the new drag pasteboard *before* the global mouseDown
    // notification arrives. Retain the last completed gesture's baseline.
    public mutating func mouseDown() { isActive = false }

    public mutating func activate(changeCount: Int, support: @autoclosure () -> Bool?) -> Bool {
        guard !isActive, changeCount != baseline else { return false }
        // An empty board can be populated later without another changeCount.
        guard let supported = support() else { return false }
        baseline = changeCount
        guard supported else { return false }
        isActive = true
        return true
    }

    public mutating func end(changeCount: Int) { baseline = changeCount; isActive = false }
}
