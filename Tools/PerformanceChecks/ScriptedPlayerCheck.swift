import AppKit
import IslandCore

// Real player lifecycle/command code; no real Apple Events, permissions or network traffic.
@MainActor final class ScriptRunner {
    static let shared = ScriptRunner()
    struct Outcome<T: Sendable>: Sendable { let value: T?; let errorCode: Int? }
    var denied = true
    var deniedCover = false
    var trackID = "spotify:track:A"
    var duration: Int32 = 230000
    var refreshDuration: Int32 = 240000
    var position: Double = 10
    var state = "playing"
    var coverURL = ""
    var includeRefreshID = true
    /// Konum eşitleme okuması ({player position, state, id}).
    var syncPosition: Double = 0
    var syncState = "playing"
    var syncID = "spotify:track:A"
    var calls: [String] = []
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func waitForCalls(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }

    func execute<T: Sendable>(_ source: String, cacheResult: Bool = true, transform: @escaping @Sendable (NSAppleEventDescriptor) -> T?) async -> Outcome<T> {
        calls.append(source)
        let ready = callWaiters.filter { calls.count >= $0.0 }
        callWaiters.removeAll { calls.count >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
        if denied || (deniedCover && source == "cover") { return .init(value: nil, errorCode: -1743) }
        let result: NSAppleEventDescriptor
        if source.contains("return {player position") {
            result = .list()
            result.insert(.init(double: syncPosition), at: 1)
            result.insert(.init(string: syncState), at: 2)
            result.insert(.init(string: syncID), at: 3)
        } else if source.contains("return {name") {
            result = .list()
            var items: [NSAppleEventDescriptor] = [.init(string: "Track"), .init(string: "Artist"), .init(string: "Album"), .init(int32: refreshDuration), .init(double: position), .init(string: state)]
            if includeRefreshID && source.contains("id of current track") { items.append(.init(string: trackID)) }
            for (offset, item) in items.enumerated() { result.insert(item, at: offset + 1) }
        } else if source == "coverDuration" {
            result = .list()
            result.insert(.init(string: coverURL), at: 1)
            result.insert(.init(int32: duration), at: 2)
            result.insert(.init(string: trackID), at: 3)
        } else if source == "cover" {
            result = NSAppleEventDescriptor(descriptorType: typeData, data: Data([1, 2, 3]))!
        } else if let value = source.components(separatedBy: "set player position to ").last,
                  source.contains("set player position to "), let time = Double(value) {
            precondition(!cacheResult, "Seek scripts must not be cached")
            position = time
            result = .init(boolean: true)
        } else { result = .init(boolean: true) }
        return .init(value: transform(result), errorCode: nil)
    }
}

// Deliberately ignores cancellation: a late completion must not mutate source state/cache.
@MainActor final class DownloadGate {
    private(set) var urls: [URL] = []
    private var downloads: [Int: CheckedContinuation<Data?, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func download(_ url: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            let index = urls.count
            urls.append(url)
            downloads[index] = continuation
            let ready = waiters.filter { urls.count >= $0.0 }
            waiters.removeAll { urls.count >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForDownloads(_ count: Int) async {
        if urls.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func finish(_ index: Int, data: Data?) {
        guard let continuation = downloads.removeValue(forKey: index) else { preconditionFailure("Unknown download") }
        continuation.resume(returning: data)
    }

    var isIdle: Bool { downloads.isEmpty && waiters.isEmpty }
}

@main struct ScriptedPlayerCheck {
    @MainActor static func event(_ source: ScriptedPlayerSource, id: String? = "spotify:track:A", state: String = "Paused", position: Double = 10) {
        var info: [AnyHashable: Any] = ["Name": "Track", "Artist": "Artist", "Album": "Album", "Player State": state, "Duration": 240000.0, "Playback Position": position]
        if let id { info["Track ID"] = id }
        source.receivePlayerNotification(info)
    }

    @MainActor static func main() async {
        let runner = ScriptRunner.shared
        let player = ScriptedPlayerSource.Player(bundleID: "test.player", appName: "Test", notification: "OpenIsland.TestPlayer.\(UUID())", durationScale: 0.001, artwork: .rawData("cover"))
        let source = ScriptedPlayerSource(player: player, isRunning: { true })
        var latest: NowPlayingInfo?
        source.onUpdate = { latest = $0 }
        source.start()
        await source.pendingUpdate?.value
        precondition(runner.calls.count == 1)
        // Permission becomes available while the source is in backoff.
        source.stop()
        runner.denied = false
        source.start()
        await source.pendingUpdate?.value
        precondition(runner.calls.count == 1, "Background refresh must respect denial backoff")
        source.perform(.pause)
        await runner.waitForCalls(2)
        precondition(runner.calls.last!.contains("pause"), "Explicit command was discarded by permission backoff")
        runner.denied = true
        source.perform(.play)
        await runner.waitForCalls(3)
        let beforeSeek = runner.calls.count
        runner.denied = false
        let accepted = await source.seek(to: 40)
        precondition(accepted && runner.calls.count > beforeSeek)
        source.stop()

        // Music raw-artwork behavior and denied-artwork recovery remain unchanged.
        let artwork = ScriptedPlayerSource(player: player, isRunning: { true })
        runner.deniedCover = true
        artwork.onUpdate = { latest = $0 }
        artwork.start()
        await artwork.pendingUpdate?.value
        precondition(latest?.title == "Track" && latest?.artworkData == nil)
        runner.deniedCover = false
        artwork.recover()
        await artwork.pendingUpdate?.value
        precondition(latest?.artworkData == Data([1, 2, 3]), "Permission recovery reused a failed cover")
        let count = runner.calls.count
        for _ in 0..<100 { artwork.start() }
        precondition(artwork.pendingUpdate == nil && runner.calls.count == count, "Repeated start duplicated background queries")
        artwork.stop()

        let metadataPlayer = ScriptedPlayerSource.Player(bundleID: "test.metadata", appName: "Test", notification: "OpenIsland.Metadata.\(UUID())", durationScale: 0.001, artwork: .urlWithDuration("coverDuration"))
        let metadataSource = ScriptedPlayerSource(player: metadataPlayer, isRunning: { true })
        metadataSource.onUpdate = { latest = $0 }
        metadataSource.start()
        await metadataSource.pendingUpdate?.value
        precondition(latest?.duration == 230, "Authoritative duration was discarded")
        precondition(runner.calls.contains { $0.contains("(player state as string), id of current track") }, "Initial refresh omitted Spotify identity")
        let metadataCalls = runner.calls.count
        event(metadataSource)
        precondition(latest?.duration == 230 && latest?.isPlaying == false)
        precondition(runner.calls.count == metadataCalls && metadataSource.pendingUpdate == nil, "Same-track event repeated the metadata query")
        event(metadataSource, id: nil)
        precondition(latest?.duration == 230 && metadataSource.pendingUpdate == nil, "ID-less event lost authoritative initial identity")

        // Same display metadata, distinct IDs and canonical durations must not share a cache.
        runner.trackID = "spotify:track:B"
        runner.duration = 170000
        event(metadataSource, id: runner.trackID, state: "Playing")
        await metadataSource.pendingUpdate?.value
        precondition(latest?.duration == 170, "Distinct Spotify IDs shared display-key duration")
        precondition(runner.calls.count == metadataCalls + 1 && runner.calls.last == "coverDuration")
        event(metadataSource, id: runner.trackID)
        precondition(latest?.duration == 170 && metadataSource.pendingUpdate == nil)

        // A same-ID restart reuses artwork when the fresh control API duration is unchanged.
        runner.refreshDuration = runner.duration
        metadataSource.stop()
        let restartCalls = runner.calls.count
        metadataSource.start()
        await metadataSource.pendingUpdate?.value
        precondition(latest?.duration == 170 && runner.calls.count == restartCalls + 1, "Same-track restart re-queried metadata or lost canonical duration")

        // Boundary seeks use one command and one refresh, never a cover query or periodic loop.
        for boundary in [0.0, 170.0] {
            let before = runner.calls.count
            let accepted = await metadataSource.seek(to: boundary)
            precondition(accepted && latest?.elapsed == boundary && latest?.duration == 170)
            precondition(runner.calls.count == before + 2 && runner.calls.last!.contains("return {name"))
            precondition(latest?.elapsed(at: latest!.timestamp.addingTimeInterval(1000)) == 170)
        }
        runner.refreshDuration = 169000
        let freshDurationSeek = await metadataSource.seek(to: 30)
        precondition(freshDurationSeek && latest?.duration == 169, "Fresh same-ID control metadata lost to stale duration cache")
        let rapidCalls = runner.calls.count
        for index in 0..<100 {
            event(metadataSource, id: runner.trackID, state: index.isMultiple(of: 2) ? "Playing" : "Paused", position: Double(index))
            precondition(latest?.duration == 169 && latest?.elapsed == Double(index))
        }
        precondition(latest?.isPlaying == false && runner.calls.count == rapidCalls && metadataSource.pendingUpdate == nil, "Rapid play/pause repeated queries")
        metadataSource.stop()

        // Missing initial ID is upgraded by the existing authoritative metadata query.
        runner.includeRefreshID = false
        let fallback = ScriptedPlayerSource(player: metadataPlayer, isRunning: { true })
        fallback.onUpdate = { latest = $0 }
        fallback.start()
        await fallback.pendingUpdate?.value
        let fallbackCalls = runner.calls.count
        event(fallback, id: runner.trackID)
        precondition(latest?.duration == 170 && runner.calls.count == fallbackCalls && fallback.pendingUpdate == nil)
        fallback.stop()
        runner.includeRefreshID = true

        // A mismatched authoritative ID cannot poison the notification track's cache.
        // Use a running source but cancel its initial refresh with the first notification.
        let identityRace = ScriptedPlayerSource(player: metadataPlayer, isRunning: { true })
        identityRace.onUpdate = { latest = $0 }
        identityRace.start()
        event(identityRace, id: "spotify:track:C")
        await identityRace.pendingUpdate?.value
        precondition(latest?.duration == 240, "Mismatched metadata ID was applied")
        runner.trackID = "spotify:track:C"
        runner.duration = 190000
        event(identityRace, id: runner.trackID)
        await identityRace.pendingUpdate?.value
        precondition(latest?.duration == 190, "Mismatched metadata poisoned the next cache lookup")
        identityRace.stop()

        // Canonical duration is visible while the network is gated, including same-track pause.
        runner.trackID = "spotify:track:Gated"
        runner.duration = 210000
        runner.coverURL = "https://artwork.invalid/gated"
        let gate = DownloadGate()
        let gated = ScriptedPlayerSource(player: metadataPlayer, isRunning: { true }, downloadArtwork: { await gate.download($0) })
        var updateCount = 0
        gated.onUpdate = { latest = $0; updateCount += 1 }
        gated.start()
        await gate.waitForDownloads(1)
        precondition(latest?.duration == 210 && latest?.artworkData == nil, "Duration was gated on artwork download")
        let initialTask = gated.pendingUpdate!
        let gatedCalls = runner.calls.count
        event(gated, id: runner.trackID)
        precondition(latest?.duration == 210 && latest?.isPlaying == false, "Pause discarded canonical duration")
        await gate.waitForDownloads(2)
        let pauseTask = gated.pendingUpdate!
        let pauseUpdates = updateCount
        gate.finish(0, data: Data([99]))
        await initialTask.value
        precondition(updateCount == pauseUpdates && latest?.artworkData == nil, "Cancelled download published stale artwork")
        gate.finish(1, data: Data([7]))
        await pauseTask.value
        precondition(latest?.duration == 210 && latest?.artworkData == Data([7]) && runner.calls.count == gatedCalls)
        event(gated, id: runner.trackID, state: "Playing")
        precondition(latest?.artworkData == Data([7]) && gated.pendingUpdate == nil && runner.calls.count == gatedCalls, "Cancelled download mutated completed cache")

        // Late completion after stop/restart cannot publish or replace the new track's cache.
        runner.trackID = "spotify:track:Stopped"
        runner.duration = 180000
        runner.coverURL = "https://artwork.invalid/stopped"
        event(gated, id: runner.trackID, state: "Playing")
        await gate.waitForDownloads(3)
        let stoppedTask = gated.pendingUpdate!
        gated.stop()
        let stoppedUpdates = updateCount
        event(gated, id: runner.trackID)
        precondition(updateCount == stoppedUpdates, "Stopped source still delivered notifications")
        runner.trackID = "spotify:track:Restarted"
        runner.duration = 160000
        runner.coverURL = "https://artwork.invalid/restarted"
        runner.refreshDuration = runner.duration
        gated.start()
        await gate.waitForDownloads(4)
        let restartedTask = gated.pendingUpdate!
        gate.finish(3, data: Data([8]))
        await restartedTask.value
        let restartUpdates = updateCount
        gate.finish(2, data: Data([98]))
        await stoppedTask.value
        precondition(updateCount == restartUpdates && latest?.duration == 160 && latest?.artworkData == Data([8]))
        let afterStopCalls = runner.calls.count
        event(gated, id: runner.trackID)
        precondition(latest?.duration == 160 && latest?.artworkData == Data([8]) && gated.pendingUpdate == nil && runner.calls.count == afterStopCalls, "Stopped download mutated new cache")
        gated.stop()
        precondition(gate.isIdle)

        // Denied metadata does not suppress event delivery or produce repeated Apple Events.
        runner.denied = true
        let denied = ScriptedPlayerSource(player: metadataPlayer, isRunning: { true }, downloadArtwork: { _ in preconditionFailure("Denied events downloaded artwork") })
        denied.onUpdate = { latest = $0 }
        denied.start()
        event(denied, id: "spotify:track:Denied", state: "Playing")
        await denied.pendingUpdate?.value
        let deniedCalls = runner.calls.count
        for index in 0..<20 {
            event(denied, id: "spotify:track:Denied", state: index.isMultiple(of: 2) ? "Playing" : "Paused", position: Double(index))
            await denied.pendingUpdate?.value
            precondition(latest?.elapsed == Double(index) && latest?.duration == 240)
        }
        precondition(runner.calls.count == deniedCalls && latest?.isPlaying == false, "Denied events repeated Apple Events or lost state")
        denied.stop()

        // Unnotified seeks (Spotify posts no distributed notification for its own scrubbing) are corrected by
        // bounded, event-driven position reads; never by a periodic loop.
        var fast = ScriptedPlayerSource.PositionSyncTiming()
        fast.endGrace = 0.05
        fast.tolerance = 0.01; fast.visibleMinimumInterval = 0
        func positionReads() -> Int { runner.calls.filter { $0.contains("return {player position") }.count }
        // Waits until no Apple Event has been issued for 200 ms; a far predicted-end check stays scheduled.
        func settle(_ source: ScriptedPlayerSource) async {
            var last = -1, stable = 0
            for _ in 0..<500 {
                try? await Task.sleep(for: .milliseconds(10))
                if runner.calls.count == last { stable += 1; if stable >= 20 { return } } else { stable = 0; last = runner.calls.count }
            }
        }
        runner.denied = false
        runner.trackID = "spotify:track:Sync"
        runner.duration = 240000
        runner.refreshDuration = 240000
        runner.coverURL = ""
        runner.syncID = runner.trackID
        let sync = ScriptedPlayerSource(player: metadataPlayer, isRunning: { true }, positionTiming: fast,
                                        downloadArtwork: { _ in nil })
        sync.onUpdate = { latest = $0 }
        sync.start()
        await sync.pendingUpdate?.value
        // 1. Backward scrub without a notification: the model ran to the end and clamped (4:00 / -0:00).
        runner.state = "playing"
        runner.syncState = "playing"
        runner.syncPosition = 100
        event(sync, id: runner.trackID, state: "Playing", position: 239.95)
        let readsBefore = positionReads()
        await settle(sync)
        let corrected = latest!.elapsed(at: Date())
        precondition(corrected > 99 && corrected < 102 && latest!.isPlaying && latest!.duration == 240,
                     "Backward scrub left the model clamped at the end: \(corrected)")
        precondition(positionReads() > readsBefore, "No position read after the predicted end")
        // 1b. The reported case: the model is in sync near the end, then the user scrubs back in the player
        // (no notification). Without the predicted-end read the model would stay at "4:00 / -0:00".
        runner.syncPosition = 239.05
        event(sync, id: runner.trackID, state: "Playing", position: 239.0)
        await settle(sync)
        runner.syncPosition = 100
        for _ in 0..<300 where latest!.elapsed(at: Date()) > 150 { try? await Task.sleep(for: .milliseconds(10)) }
        let rewound = latest!.elapsed(at: Date())
        precondition(rewound > 99 && rewound < 103, "Predicted-end read did not catch an unnotified backward scrub: \(rewound)")
        // 2. Visible panel catches a forward scrub immediately (one read).
        runner.syncPosition = 200
        let panelReads = positionReads()
        sync.synchronizePosition()
        await settle(sync)
        let forward = latest!.elapsed(at: Date())
        precondition(forward > 199 && forward < 201 && positionReads() >= panelReads + 1, "Panel sync missed a forward scrub")
        // 3. A playing notification is fresh truth: no read at playback start, only the far predicted-end check.
        runner.syncPosition = 30
        event(sync, id: runner.trackID, state: "Playing", position: 30)
        let startReads = positionReads()
        await settle(sync)
        precondition(positionReads() == startReads && sync.pendingPositionSync != nil,
                     "Playback start issued a position read")
        // 4. A player stuck at its end produces at most `endChecks` idle reads, then nothing (no polling).
        runner.syncPosition = 240
        event(sync, id: runner.trackID, state: "Playing", position: 240)
        let endReads = positionReads()
        await settle(sync)
        precondition(positionReads() - endReads <= fast.endChecks && sync.pendingPositionSync == nil,
                     "Stuck end kept issuing position reads")
        // 5. Paused: nothing is scheduled and the panel does not read.
        event(sync, id: runner.trackID, state: "Paused", position: 50)
        let pausedReads = positionReads()
        sync.synchronizePosition()
        precondition(sync.pendingPositionSync == nil && positionReads() == pausedReads, "Paused source scheduled position work")
        // 6. A different track at the read point uses the existing full refresh instead of mixing metadata.
        runner.syncPosition = 5
        runner.syncID = "spotify:track:Other"
        event(sync, id: runner.trackID, state: "Playing", position: 10)
        sync.synchronizePosition()
        await settle(sync)
        await sync.pendingUpdate?.value
        precondition(runner.calls.last(where: { !$0.contains("return {player position") })?.contains("return {name") == true,
                     "Track mismatch did not fall back to the full refresh")
        // 7. Denied position read: no publication change and no rescheduling loop.
        runner.syncID = runner.trackID
        event(sync, id: runner.trackID, state: "Playing", position: 10)
        runner.denied = true
        let deniedReads = positionReads()
        sync.synchronizePosition()
        await settle(sync)
        precondition(sync.pendingPositionSync == nil && positionReads() - deniedReads <= 1, "Denied read rescheduled")
        runner.denied = false
        sync.stop()
        precondition(sync.pendingPositionSync == nil)
        print("PASS Spotify position: unnotified backward/forward scrub corrected; no read at playback start; bounded end checks; paused/denied/mismatch safe")
        print("PASS Spotify: distinct IDs/durations, initial identity, cached restart, boundary seek, rapid play/pause, denied events")
        print("PASS Spotify artwork: duration before gated download; pause/cancel/stop/restart reject stale publication and cache mutation")
        print("PASS ScriptedPlayer: explicit controls/seek recover from denial; Music raw artwork recovers; repeated start does no extra work")
    }
}
