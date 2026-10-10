import AppKit
import Darwin
import IslandCore
import Quartz

// Only unrelated panel integration and preference storage are stubbed.
enum AppPaths { static let isRunningAsBundle = false }
enum LifecycleLog { static func note(_ message: String) {} }
enum PublicStationaryProvider { static let collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary] }
@MainActor final class QuickLookController {
    static let shared = QuickLookController()
    var isPreviewing = false
    var hasItems = false
    func begin(_ panel: QLPreviewPanel) {}
    func end(_ panel: QLPreviewPanel) {}
}

private final class HoverEvent: NSEvent {
    var area: NSTrackingArea?
    override var trackingArea: NSTrackingArea? { area }
}

private struct CheckFailure: Error, CustomStringConvertible { let description: String }

@main struct HoverExitCheck {
    @MainActor static func main() async {
        do { try await runChecks() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    @MainActor private static func runChecks() async throws {
        try await checkClosingLatency()
        let model = IslandViewModel(
            metrics: .init(notchSize: CGSize(width: 185, height: 33.5), style: .notch),
            configuration: .init(collapseGraceDelay: 0.002), hapticPerformer: { _ in })
        let window = NSWindow(contentRect: CGRect(x: -800, y: 100, width: 700, height: 350),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); model.cancelPendingEffects() }
        var pointer = window.convertPoint(toScreen: CGPoint(x: 150, y: 30))
        let container = IslandContainerView(content: NSView(), mouseLocation: { pointer })
        window.contentView = container
        var entries = 0, exits = 0
        container.onPointerEntered = { entries += 1; model.send(.pointerEntered) }
        container.onPointerExited = { exits += 1; model.send(.pointerExited) }
        let small = CGRect(x: 50, y: 0, width: 185, height: 34)
        let expanded = CGRect(x: 0, y: 0, width: 600, height: 250)
        container.setTrackingRect(small, pointerInside: true)
        let retiredArea = container.trackingAreas[0]
        model.send(.pointerEntered)
        model.send(.tapped)
        container.setTrackingRect(expanded, pointerInside: true)
        pointer = window.convertPoint(toScreen: CGPoint(x: 650, y: 300))
        let delayedExit = HoverEvent(); delayedExit.area = retiredArea
        container.mouseExited(with: delayedExit)
        try await Task.sleep(for: .milliseconds(30))
        try check(exits == 1 && !model.machine.isExpanded && model.pendingEffectCount == 0,
                  "A delayed exit from the replaced tracking area must close an unpinned island when the pointer is outside")

        pointer = window.convertPoint(toScreen: CGPoint(x: 150, y: 30))
        container.setTrackingRect(expanded, pointerInside: true)
        let stableArea = container.trackingAreas[0]
        for _ in 0..<1000 { container.setTrackingRect(expanded, pointerInside: true) }
        try check(container.trackingAreas.count == 1 && container.trackingAreas[0] === stableArea,
                  "Unchanged geometry/inside state must preserve one native tracking area")
        let entered = HoverEvent(); entered.area = stableArea
        container.mouseEntered(with: entered)
        model.send(.tapped)
        let count = exits
        container.mouseExited(with: delayedExit)
        try check(exits == count && model.machine.isExpanded, "A stale exit after reentry must not close the island")

        // The top and right boundary stay included, including nonzero/negative screen origins.
        pointer = window.convertPoint(toScreen: CGPoint(x: expanded.maxX, y: expanded.maxY))
        let currentExit = HoverEvent(); currentExit.area = stableArea
        container.mouseExited(with: currentExit)
        try check(exits == count, "The exact tracking boundary must remain inside")
        pointer = window.convertPoint(toScreen: CGPoint(x: 650, y: 300))
        container.mouseExited(with: currentExit)
        try await Task.sleep(for: .milliseconds(30))
        try check(!model.machine.isExpanded && model.pendingEffectCount == 0, "Normal exit must close without retained tasks")
        let entryCount = entries
        container.mouseEntered(with: entered)
        try check(entries == entryCount, "A delayed enter delivered after the pointer left must not reopen the island")

        for _ in 0..<100 {
            pointer = window.convertPoint(toScreen: CGPoint(x: 150, y: 30))
            container.setTrackingRect(expanded, pointerInside: false)
            let event = HoverEvent(); event.area = container.trackingAreas[0]
            container.mouseEntered(with: event)
            model.send(.tapped)
            pointer = window.convertPoint(toScreen: CGPoint(x: 650, y: 300))
            container.mouseExited(with: event)
            try await Task.sleep(for: .milliseconds(10))
            try check(!model.machine.isExpanded && model.pendingEffectCount == 0 && container.trackingAreas.count == 1,
                      "Repeated native enter/exit must close without accumulating areas or tasks")
        }

        // Pin, menu hold, demo and drag intentionally keep the island open after a real exit.
        for event in [IslandEvent.togglePin, .holdChanged(isHeld: true), .demoModeChanged(isOn: true), .fileDragEntered] {
            pointer = window.convertPoint(toScreen: CGPoint(x: 150, y: 30))
            container.setTrackingRect(expanded, pointerInside: false)
            let hover = HoverEvent(); hover.area = container.trackingAreas[0]
            container.mouseEntered(with: hover)
            model.send(.tapped)
            model.send(event)
            pointer = window.convertPoint(toScreen: CGPoint(x: 650, y: 300))
            container.mouseExited(with: hover)
            try await Task.sleep(for: .milliseconds(10))
            try check(model.machine.isExpanded, "Intentional pin/hold/demo/drag behavior must be retained")
            model.send(.holdChanged(isHeld: false)); model.send(.demoModeChanged(isOn: false))
            model.send(.escapePressed)
        }
        print("PASS: actual NSView tracking + view model: delayed retired exit closes; stale exit/enter cannot reopen or falsely close; inclusive edges and negative screen origin; 1000 unchanged regions retain one area; 100 enter/exit cycles clean tasks; pin/hold/demo/drag preserved")
    }

    @MainActor private static func checkClosingLatency() async throws {
        let model = IslandViewModel(
            metrics: .init(notchSize: CGSize(width: 185, height: 33.5), style: .notch),
            configuration: .init(collapseGraceDelay: MotionStyle.expressive.collapseGraceDelay),
            hapticPerformer: { _ in })
        defer { model.cancelPendingEffects() }
        model.send(.pointerEntered)
        model.send(.tapped)
        for _ in 0..<10 {
            model.send(.pointerExited)
            try await Task.sleep(for: .milliseconds(50))
            try check(model.machine.isExpanded, "A brief accidental exit must retain the island")
            model.send(.pointerEntered)
            try check(model.pendingEffectCount == 0, "Reentry must cancel the old close without retained tasks")
        }
        let start = ContinuousClock.now
        model.send(.pointerExited)
        let deadline = start + .milliseconds(160)
        while model.machine.isExpanded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try check(!model.machine.isExpanded && model.pendingEffectCount == 0,
                  "Expressive closing must begin within 160 ms after the real exit, with no pending effects")
        print("PASS: real motion preference + view model: close begins after \(start.duration(to: .now)); 10 brief exits/reentries cancel old closes without flicker or retained tasks")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(description: message) }
    }
}
