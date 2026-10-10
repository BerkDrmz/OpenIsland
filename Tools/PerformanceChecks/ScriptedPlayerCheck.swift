import AppKit
import IslandCore

// Real player health/lifecycle/command code; Apple Events are replaced so no system permission is changed.
@MainActor final class ScriptRunner {
    static let shared = ScriptRunner()
    struct Outcome<T: Sendable>: Sendable { let value: T?; let errorCode: Int? }
    var denied = true
    var deniedCover = false
    var calls: [String] = []
    func execute<T: Sendable>(_ source: String, cacheResult: Bool = true, transform: @escaping @Sendable (NSAppleEventDescriptor) -> T?) async -> Outcome<T> {
        calls.append(source)
        if denied || (deniedCover && source == "cover") { return .init(value: nil, errorCode: -1743) }
        let result: NSAppleEventDescriptor
        if source.contains("return {name") {
            result = .list()
            let items: [NSAppleEventDescriptor] = [.init(string: "Track"), .init(string: "Artist"), .init(string: "Album"), .init(int32: 240000), .init(int32: 10), .init(string: "playing")]
            for (offset, item) in items.enumerated() { result.insert(item, at: offset + 1) }
        } else if source == "cover" {
            result = NSAppleEventDescriptor(descriptorType: typeData, data: Data([1, 2, 3]))!
        } else { result = .init(boolean: true) }
        return .init(value: transform(result), errorCode: nil)
    }
}

@main struct ScriptedPlayerCheck {
    @MainActor static func settle() async { for _ in 0..<100 { await Task.yield() } }
    @MainActor static func main() async {
        let runner = ScriptRunner.shared
        let player = ScriptedPlayerSource.Player(bundleID: "test.player", appName: "Test", notification: "OpenIsland.TestPlayer.\(UUID())", durationScale: 0.001, artwork: .rawData("cover"))
        let source = ScriptedPlayerSource(player: player, isRunning: { true })
        var latest: NowPlayingInfo?
        source.onUpdate = { latest = $0 }
        source.start()
        await settle()
        precondition(runner.calls.count == 1)
        // Permission becomes available while the source is in backoff.
        source.stop()
        runner.denied = false
        source.start()
        await settle()
        precondition(runner.calls.count == 1, "Background refresh must respect denial backoff")
        source.perform(.pause)
        await settle()
        precondition(runner.calls.count == 2 && runner.calls.last!.contains("pause"), "Explicit command was discarded by permission backoff")
        runner.denied = true
        source.perform(.play)
        await settle()
        let beforeSeek = runner.calls.count
        runner.denied = false
        let accepted = await source.seek(to: 40)
        precondition(accepted && runner.calls.count > beforeSeek)
        source.stop()

        // A failed cover cached while denied must be retried after permission recovery for the same track.
        let artwork = ScriptedPlayerSource(player: player, isRunning: { true })
        runner.denied = false
        runner.deniedCover = true
        artwork.onUpdate = { latest = $0 }
        artwork.start()
        await settle()
        precondition(latest?.title == "Track" && latest?.artworkData == nil)
        runner.deniedCover = false
        artwork.onUpdate = { latest = $0 }
        artwork.recover()
        await settle()
        precondition(latest?.artworkData == Data([1, 2, 3]), "Permission recovery reused a failed cover")
        let count = runner.calls.count
        for _ in 0..<100 { artwork.start() }
        await settle()
        precondition(runner.calls.count == count, "Repeated start duplicated background queries")
        artwork.stop()
        print("PASS ScriptedPlayer: explicit controls and seek recover from denial; failed artwork retries after grant; repeated start performs no extra work")
    }
}
