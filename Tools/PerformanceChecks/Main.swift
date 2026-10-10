import AppKit
import SwiftUI
import IslandCore

enum MotionStyle { case expressive, natural, reduced }
enum IslandMotion {
    static let reduced = Animation.linear(duration: 0.01)
    static let relax = reduced
    static func resize(style: MotionStyle) -> Animation { reduced }
    static func morph(from: IslandPresentation, to: IslandPresentation, style: MotionStyle) -> Animation { reduced }
}

@main struct PerformanceChecks {
    @MainActor static func main() async throws {
        let model = IslandViewModel(metrics: .init(notchSize: CGSize(width: 185, height: 33.5), style: .notch), configuration: .init())
        model.hapticsEnabled = false
        for _ in 0..<1000 {
            model.send(.pointerEntered)
            precondition(model.pendingEffectCount == 1)
            model.send(.pointerExited)
            precondition(model.pendingEffectCount == 0)
        }
        try await Task.sleep(for: .milliseconds(150))
        precondition(!model.machine.isExpanded && model.pendingEffectCount == 0)
        let start = ContinuousClock.now
        model.send(.pointerEntered)
        try await waitUntil { model.machine.isExpanded }
        print("PASS: actual view model: 1000 rapid hover cycles retain no tasks; expansion after \(start.duration(to: .now))")
        model.send(.pointerExited)
        model.send(.escapePressed)
        model.cancelPendingEffects()
        precondition(model.pendingEffectCount == 0)

        let monitor = TransferMonitor()
        var completions = 0
        var outcomes: [TransferOutcome] = []
        var activeStates: [Bool] = []
        monitor.onFinished = { _ in precondition(!monitor.isActive); completions += 1 }
        monitor.onEnded = { _, outcome in outcomes.append(outcome) }
        monitor.onActiveChange = { activeStates.append($0) }
        monitor.start(); monitor.start()
        precondition(monitor.subscriptionCount == 3)
        let id = UUID(), progress = Progress(totalUnitCount: 10000)
        monitor.track(progress, id: id)
        monitor.track(progress, id: UUID())
        precondition(monitor.trackedTransferCount == 1)
        for count in 1..<10000 { progress.completedUnitCount = Int64(count) }
        try await Task.sleep(for: .milliseconds(150))
        precondition(monitor.isActive && monitor.trackedTransferCount == 1 && monitor.fraction == 0.99)
        progress.completedUnitCount = 10000
        try await waitUntil { !monitor.isActive }
        precondition(completions == 1 && monitor.trackedTransferCount == 0)
        monitor.untrack(id)
        monitor.track(progress, id: UUID())
        precondition(completions == 1 && monitor.trackedTransferCount == 0)
        let cancelID = UUID(), cancelled = Progress(totalUnitCount: 100)
        monitor.track(cancelled, id: cancelID)
        cancelled.cancel()
        try await waitUntil { !monitor.isActive }
        precondition(outcomes == [.cancelled])
        let incompleteID = UUID(), incomplete = Progress(totalUnitCount: 100)
        incomplete.completedUnitCount = 99
        monitor.track(incomplete, id: incompleteID)
        monitor.untrack(incompleteID)
        precondition(outcomes == [.cancelled, .interrupted])
        for _ in 0..<100 {
            monitor.start()
            let token = UUID(), item = Progress(totalUnitCount: 10)
            monitor.track(item, id: token)
            item.completedUnitCount = 5
            monitor.stop()
            item.completedUnitCount = 10 // stale callback cannot revive the stopped monitor
            precondition(monitor.subscriptionCount == 0 && monitor.trackedTransferCount == 0 && !monitor.isActive)
        }
        try await Task.sleep(for: .milliseconds(150))
        precondition(completions == 1)
        print("PASS: real Progress KVO: 9999 update burst, completed/cancelled/incomplete dedup, 100 start/stop cycles; no leftover tokens/tasks")

        // Exercise the publication path too: direct track() calls cannot prove folder subscriptions work.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let published = TransferMonitor(folders: [folder, folder.appendingPathComponent(".")])
        var publishedNames: [String] = []
        published.onFinished = { publishedNames.append($0) }
        published.start(); published.start()
        precondition(published.subscriptionCount == 1)
        let publisher = Process()
        publisher.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        publisher.arguments = [folder.appendingPathComponent("OpenIsland Test.appdownload").path]
        try publisher.run()
        try await waitUntil { published.isActive }
        try await waitUntil { published.primaryName == "OpenIsland Test" }
        precondition(published.primaryName == "OpenIsland Test")
        try await waitUntil { !published.isActive }
        precondition(publishedNames == ["OpenIsland Test"])
        published.stop()
        precondition(published.subscriptionCount == 0 && published.trackedTransferCount == 0)
        try await waitUntil { !publisher.isRunning }
        print("PASS: cross-process application Progress publication, bundle name, completion and duplicate-folder subscription cleanup")

        let network = NetworkMonitor()
        var networkChanges = 0
        network.onChange = { _ in networkChanges += 1 }
        network.start(); network.start()
        precondition(network.isMonitoring)
        try await Task.sleep(for: .milliseconds(500))
        precondition(networkChanges == 0) // startup path is baseline
        network.stop(); network.stop()
        precondition(!network.isMonitoring)
        print("PASS: real NWPathMonitor startup baseline, idempotent registration and cancellation")
    }
    @MainActor static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out")
    }
}
