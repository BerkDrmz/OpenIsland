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
    /// Konum okumasındaki süre (oynatıcının birimiyle); nil ise liste 3 öğe döner.
    var syncDuration: Double?
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
            if let syncDuration { result.insert(.init(double: syncDuration), at: 4) }
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
        fast.trackSettle = 0.05; fast.commandSettle = 0.05
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
        // 8. Visible panel + playing: a mouse-up in the frontmost player triggers one debounced read; the click
        // watcher exists only while the scrubber is visible and the source is playing.
        var clickTiming = fast
        clickTiming.clickSettle = 0.02
        var playerIsFront = true
        let clicks = ScriptedPlayerSource(player: metadataPlayer, isRunning: { true }, positionTiming: clickTiming,
                                          isFrontmost: { playerIsFront }, downloadArtwork: { _ in nil })
        clicks.onUpdate = { latest = $0 }
        clicks.start()
        await clicks.pendingUpdate?.value
        event(clicks, id: runner.trackID, state: "Paused", position: 20)
        clicks.setPositionWatch(true)
        precondition(!clicks.isWatchingPlayerClicks, "Click watcher installed while paused")
        runner.syncState = "playing"
        runner.syncPosition = 20
        event(clicks, id: runner.trackID, state: "Playing", position: 20)
        precondition(clicks.isWatchingPlayerClicks, "Click watcher missing while visible and playing")
        await settle(clicks)
        runner.syncPosition = 150
        let clickReads = positionReads()
        clicks.receivePlayerClick()
        await settle(clicks)
        let clicked = latest!.elapsed(at: Date())
        precondition(clicked > 149 && clicked < 152 && positionReads() == clickReads + 1, "Player click did not resync: \(clicked)")
        playerIsFront = false
        let backgroundReads = positionReads()
        clicks.receivePlayerClick()
        await settle(clicks)
        precondition(positionReads() == backgroundReads, "Click outside the player issued a read")
        playerIsFront = true
        let burstReads = positionReads()
        for _ in 0..<5 { clicks.receivePlayerClick() }
        await settle(clicks)
        precondition(positionReads() == burstReads + 1, "Click burst was not coalesced into one read")
        clicks.setPositionWatch(false)
        precondition(!clicks.isWatchingPlayerClicks, "Click watcher survived the hidden panel")
        let hiddenReads = positionReads()
        clicks.receivePlayerClick()
        await settle(clicks)
        precondition(positionReads() == hiddenReads, "Hidden panel click issued a read")
        clicks.setPositionWatch(true)
        precondition(clicks.isWatchingPlayerClicks)
        event(clicks, id: runner.trackID, state: "Paused", position: 30)
        precondition(!clicks.isWatchingPlayerClicks, "Click watcher survived pause")
        event(clicks, id: runner.trackID, state: "Playing", position: 30)
        precondition(clicks.isWatchingPlayerClicks)
        clicks.stop()
        precondition(!clicks.isWatchingPlayerClicks && clicks.pendingPositionSync == nil, "Click watcher survived stop")
        print("PASS Spotify position: player click resync only while visible+playing+frontmost; bursts coalesced; watcher removed on hide/pause/stop")

        // 9. Scenario matrix: restart same track, delayed metadata, Music (no position in notification),
        // stopped player, player quit, wake recovery. Each step bounds the Apple Events it may issue.
        var running = true
        let matrix = ScriptedPlayerSource(player: metadataPlayer, isRunning: { running }, positionTiming: clickTiming,
                                          isFrontmost: { true }, downloadArtwork: { _ in nil })
        matrix.onUpdate = { latest = $0 }
        matrix.start()
        await matrix.pendingUpdate?.value
        await settle(matrix)
        matrix.setPositionWatch(true)
        // Restart the same track: the notification is fresh truth (no read), elapsed jumps back to 0.
        event(matrix, id: runner.trackID, state: "Playing", position: 200)
        let restartReads = runner.calls.count
        event(matrix, id: runner.trackID, state: "Playing", position: 0)
        precondition(latest!.elapsed == 0 && latest!.isPlaying && runner.calls.count == restartReads, "Same-track restart issued reads or kept the old position")
        // Delayed metadata: a notification without a title falls back to one full refresh.
        runner.position = 12
        runner.state = "playing"
        let delayedCalls = runner.calls.count
        matrix.receivePlayerNotification(["Player State": "Playing", "Track ID": runner.trackID])
        await matrix.pendingUpdate?.value
        precondition(runner.calls[delayedCalls...].contains { $0.contains("return {name") } && abs(latest!.elapsed(at: latest!.timestamp) - 12) < 0.01,
                     "Metadata-less notification did not refresh once")
        // Stopped: model cleared, watcher removed, nothing scheduled.
        event(matrix, id: runner.trackID, state: "Stopped", position: 0)
        precondition(latest == nil && !matrix.isWatchingPlayerClicks && matrix.pendingPositionSync == nil, "Stopped player kept work")
        // Player quit: the next notification publishes nil without Apple Events.
        event(matrix, id: runner.trackID, state: "Playing", position: 5)
        precondition(matrix.isWatchingPlayerClicks)
        running = false
        let quitCalls = runner.calls.count
        event(matrix, id: runner.trackID, state: "Playing", position: 6)
        precondition(latest == nil && runner.calls.count == quitCalls && !matrix.isWatchingPlayerClicks, "Quit player was queried or kept the watcher")
        // Wake: a denial backoff is reset by recover() and the running player is read once.
        running = true
        runner.denied = true
        matrix.recover()
        await matrix.pendingUpdate?.value
        runner.denied = false
        let wakeCalls = runner.calls.count
        matrix.recover()
        await matrix.pendingUpdate?.value
        precondition(latest?.title == "Track" && runner.calls.count > wakeCalls, "Wake recovery did not read the player")
        matrix.stop()
        precondition(!matrix.isWatchingPlayerClicks && matrix.pendingPositionSync == nil)

        // Music: notifications carry no position, so playing state is read once; the click resync uses the title.
        let musicPlayer = ScriptedPlayerSource.Player(bundleID: "test.music", appName: "Test", notification: "OpenIsland.Music.\(UUID())", durationScale: 1, artwork: .rawData("cover"))
        runner.refreshDuration = 300
        runner.position = 40
        let music = ScriptedPlayerSource(player: musicPlayer, isRunning: { true }, positionTiming: clickTiming,
                                         isFrontmost: { true }, downloadArtwork: { _ in nil })
        music.onUpdate = { latest = $0 }
        music.start()
        await music.pendingUpdate?.value
        precondition(latest?.duration == 300 && latest!.isPlaying, "Music refresh did not publish playing state")
        let musicCalls = runner.calls.count
        music.receivePlayerNotification(["Player State": "Playing", "Name": "Track", "Artist": "Artist", "Total Time": 300000.0])
        await music.pendingUpdate?.value
        precondition(runner.calls.count == musicCalls + 1 && runner.calls.last!.contains("return {name"), "Music notification did not read position once")
        music.setPositionWatch(true)
        precondition(music.isWatchingPlayerClicks)
        await settle(music)
        runner.syncID = "Track"
        runner.syncPosition = 250
        music.receivePlayerClick()
        await settle(music)
        precondition(abs(latest!.elapsed(at: Date()) - 250) < 2, "Music click resync failed")
        runner.syncID = "Other Song"
        music.receivePlayerClick()
        await settle(music)
        await music.pendingUpdate?.value
        precondition(runner.calls.last(where: { !$0.contains("return {player position") })?.contains("return {name") == true,
                     "Music title mismatch did not refresh")
        music.stop()
        precondition(!music.isWatchingPlayerClicks && music.pendingPositionSync == nil)
        // 10. Spotify corrects a new track's duration ≈0.5 s after the notification without notifying. One delayed
        // read per new playing track publishes the corrected duration and updates the same-ID cache.
        let settleSource = ScriptedPlayerSource(player: metadataPlayer, isRunning: { true }, positionTiming: clickTiming,
                                                isFrontmost: { true }, downloadArtwork: { _ in nil })
        settleSource.onUpdate = { latest = $0 }
        settleSource.start()
        await settleSource.pendingUpdate?.value
        await settle(settleSource)
        runner.trackID = "spotify:track:Settle"
        runner.duration = 240000      // artwork query right after the change still reports the notification value
        runner.syncID = runner.trackID
        runner.syncPosition = 2
        runner.syncState = "playing"
        runner.syncDuration = 233714  // ms, the value Spotify settles on
        let settleReads = positionReads()
        event(settleSource, id: runner.trackID, state: "Playing", position: 0)
        await settleSource.pendingUpdate?.value
        precondition(latest?.duration == 240, "Notification duration should show first")
        for _ in 0..<300 where latest!.duration != 233.714 { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(latest?.duration == 233.714 && positionReads() == settleReads + 1, "Settled duration not published with one read")
        event(settleSource, id: runner.trackID, state: "Playing", position: 5) // same ID: cache keeps the settled value
        precondition(latest?.duration == 233.714, "Same-ID notification restored the stale duration")
        await settle(settleSource)
        let sameTrackReads = positionReads()
        event(settleSource, id: runner.trackID, state: "Paused", position: 5)
        event(settleSource, id: runner.trackID, state: "Playing", position: 5)
        await settle(settleSource)
        precondition(positionReads() == sameTrackReads, "Same-track play/pause scheduled a settle read")
        // 11. App command without a notification (previous track restarts the song): one read after the command.
        runner.syncPosition = 0.4
        let commandReads = positionReads()
        settleSource.perform(.previousTrack)
        await settle(settleSource)
        precondition(positionReads() == commandReads + 1 && latest!.elapsed(at: Date()) < 2, "Restart via app command not resynced")
        // A command answered by a notification issues no extra read.
        let notifiedReads = positionReads()
        settleSource.perform(.pause)
        event(settleSource, id: runner.trackID, state: "Paused", position: 1)
        await settle(settleSource)
        precondition(positionReads() == notifiedReads, "Notified command still issued a read")
        settleSource.stop()
        runner.syncDuration = nil
        print("PASS Spotify settle: late duration correction published once per new track; app-command restart resynced; notified commands read nothing")
        print("PASS Media matrix: same-track restart, delayed metadata, stopped, quit, wake recovery; Music position read, click resync and title mismatch")
        print("PASS Spotify position: unnotified backward/forward scrub corrected; no read at playback start; bounded end checks; paused/denied/mismatch safe")
        print("PASS Spotify: distinct IDs/durations, initial identity, cached restart, boundary seek, rapid play/pause, denied events")
        print("PASS Spotify artwork: duration before gated download; pause/cancel/stop/restart reject stale publication and cache mutation")
        print("PASS ScriptedPlayer: explicit controls/seek recover from denial; Music raw artwork recovers; repeated start does no extra work")
    }
}
