import AppKit
import IslandCore
import SwiftUI
import Darwin

// Preferences storage is unrelated to feedback delivery; use the existing three style values.
enum MotionStyle { case expressive, natural, reduced }

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// Exercise the real view model and motion definitions without vibrating the user's trackpad.
@main struct HapticsCheck {
    @MainActor static func main() async {
        do { try await runChecks() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    @MainActor private static func runChecks() async throws {
        try await checkMountedOpening()
        let configurable = IslandViewModel(metrics: .init(notchSize: CGSize(width: 185, height: 33.5), style: .notch),
                                           configuration: .init(hoverExpandDelay: 0.05), hapticPerformer: { _ in })
        var styleChanges = 0
        withObservationTracking { _ = configurable.motionStyle } onChange: {
            MainActor.assumeIsolated { styleChanges += 1 }
        }
        configurable.motionStyle = .natural
        try check(styleChanges == 1, "Changing motion must invalidate the style read by the visible island")
        configurable.send(.pointerEntered)
        try check(configurable.pendingEffectCount == 1, "Hover must schedule expansion")
        configurable.configure(.init(expandsOnHover: false))
        try check(configurable.pendingEffectCount == 0, "Disabling hover must immediately cancel pending expansion")
        try await Task.sleep(for: .milliseconds(80))
        try check(!configurable.machine.isExpanded, "A disabled hover must not open from a stale timer")
        configurable.send(.pointerExited)
        configurable.configure(.init(expandsOnHover: true, hoverExpandDelay: 0.001))
        configurable.send(.pointerEntered)
        try await waitUntil { configurable.machine.isExpanded }
        configurable.cancelPendingEffects()
        for style in [MotionStyle.expressive, .natural, .reduced] {
            var patterns: [NSHapticFeedbackManager.FeedbackPattern] = []
            let model = IslandViewModel(
                metrics: .init(notchSize: CGSize(width: 185, height: 33.5), style: .notch),
                configuration: .init(hoverExpandDelay: 0.001),
                hapticPerformer: { patterns.append($0) })
            model.motionStyle = style

            model.send(.tapped)
            try check(patterns == [.alignment], "Opening feedback must be delivered at expansion, independently of animation completion")
            model.send(.tapped)
            model.send(.pointerEntered)
            model.send(.selectTab(.clipboard))
            try check(patterns.count == 1, "Already expanded interactions must not repeat opening feedback")
            model.send(.pointerExited)
            model.send(.escapePressed)
            patterns.removeAll()

            for _ in 0..<1000 {
                model.send(.pointerEntered)
                model.send(.pointerExited)
            }
            try await Task.sleep(for: .milliseconds(25))
            try check(patterns.isEmpty && !model.machine.isExpanded && model.pendingEffectCount == 0,
                      "Canceled short hovers must not vibrate or retain tasks")

            for index in 0..<100 {
                model.send(.pointerEntered)
                try await waitUntil { model.machine.isExpanded }
                try check(patterns.count == index + 1 && patterns.last == .alignment,
                          "Each real hover expansion must deliver exactly one alignment feedback")
                model.send(.pointerEntered)
                model.send(.tapped)
                try check(patterns.count == index + 1, "Repeated entry/tap must not duplicate feedback")
                model.send(.pointerExited)
                model.send(.escapePressed)
                try check(model.pendingEffectCount == 0, "Closing must clean pending effects")
            }
            try await Task.sleep(for: .milliseconds(350))
            try check(patterns.count == 100, "Closed expansions must not generate late feedback")

            model.hapticsEnabled = false
            model.send(.tapped)
            model.send(.togglePin)
            model.send(.escapePressed)
            try check(patterns.count == 100, "The user's disabled haptics setting must be respected")
            model.hapticsEnabled = true
            model.send(.togglePin)
            try check(patterns.last == .generic && patterns.count == 101, "Pin feedback must retain its original pattern")
            model.send(.escapePressed)
            model.cancelPendingEffects()
            try check(model.pendingEffectCount == 0, "No tasks may remain after teardown")
        }
        print("PASS: real view model + motion: immediate exact-once opening feedback across 3 motion styles, 300 expansions, 3000 canceled hovers, disabled setting, pin pattern, no late feedback or retained tasks")
    }

    @MainActor private static func checkMountedOpening() async throws {
        var requests = 0
        let model = IslandViewModel(
            metrics: .init(notchSize: CGSize(width: 185, height: 33.5), style: .notch),
            configuration: .init(), hapticPerformer: { _ in requests += 1 })
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 640, height: 250),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "OpenIsland haptic regression"
        window.contentView = NSHostingView(rootView: HapticTestSurface(model: model))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        model.send(.tapped)
        try check(requests == 1, "Mounted animated opening must request feedback immediately, not after animation settles")
        model.send(.escapePressed)
        try await Task.sleep(for: .milliseconds(600))
        try check(requests == 1, "Interrupted mounted animation must not leave a delayed or duplicate feedback")
        model.cancelPendingEffects()
        print("PASS: mounted NSHostingView opening: one synchronous feedback request, no delayed feedback after interruption")
    }

    @MainActor private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try check(condition(), "Hover expansion timed out")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(description: message) }
    }
}

private struct HapticTestSurface: View {
    let model: IslandViewModel
    var body: some View {
        Color.black.frame(width: model.layout.size.width, height: model.layout.size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
