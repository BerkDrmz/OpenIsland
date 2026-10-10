import AppKit

// Only unrelated navigation dependencies are stubbed; all permission task/state logic is real.
@MainActor enum AppPaths { static let isRunningAsBundle = false }
@MainActor enum Notifier { static func requestAuthorization() {} }
@MainActor final class RemindersService { func requestAccess() {} }
@MainActor final class CalendarService { func requestAccess() {} }

@MainActor final class PermissionProbe {
    struct Read {
        let bundleID: String
        let ask: Bool
        let completion: CheckedContinuation<PermissionsCenter.State, Never>
    }
    var reads: [Read] = []
    var launches: [String] = []
    var launchSucceeds = true
    func read(_ bundleID: String, _ ask: Bool) async -> PermissionsCenter.State {
        await withCheckedContinuation { reads.append(Read(bundleID: bundleID, ask: ask, completion: $0)) }
    }
    func launch(_ bundleID: String) async -> Bool {
        launches.append(bundleID)
        return launchSucceeds
    }
    func complete(_ index: Int, _ state: PermissionsCenter.State) { reads[index].completion.resume(returning: state) }
}

@main struct PermissionsCheck {
    @MainActor static func settle() async { for _ in 0..<50 { await Task.yield() } }
    @MainActor static func main() async {
        let probe = PermissionProbe()
        let center = PermissionsCenter(readAutomation: { await probe.read($0, $1) },
                                       launchAutomationTarget: { await probe.launch($0) })
        var changes: [(PermissionsCenter.Kind, PermissionsCenter.State)] = []
        center.onStateChange = { changes.append(($0, $1)) }
        for _ in 0..<1000 { center.refreshAutomationPermissions() }
        await settle()
        precondition(probe.reads.count == 2 && probe.launches.isEmpty, "Passive refresh duplicated requests or opened apps")
        let oldMusic = probe.reads.firstIndex { $0.bundleID == "com.apple.Music" }!
        let oldSpotify = probe.reads.firstIndex { $0.bundleID == "com.spotify.client" }!
        for _ in 0..<100 { center.resolve(.music, reminders: RemindersService(), calendar: CalendarService()) }
        await settle()
        precondition(probe.launches == ["com.apple.Music"] && probe.reads.count == 3 && probe.reads[2].ask,
                     "Explicit request failed to launch target or duplicated consent queries")
        probe.complete(2, .granted)
        await settle()
        probe.complete(oldMusic, .askOnUse) // Slow passive completion must not overwrite user consent.
        probe.complete(oldSpotify, .granted)
        await settle()
        precondition(center.state(of: .music) == .granted && center.state(of: .spotify) == .granted)
        precondition(changes.count == 2, "Stale result published or grant callback duplicated")
        center.refreshAutomationPermissions()
        await settle()
        precondition(probe.reads.count == 5)
        probe.complete(3, .granted); probe.complete(4, .granted)
        await settle()
        precondition(changes.count == 2, "Unchanged status invalidated UI or reset media")
        center.refreshAutomationPermissions()
        await settle()
        center.stop()
        probe.complete(5, .notGranted); probe.complete(6, .notGranted)
        await settle()
        precondition(center.state(of: .music) == .granted && center.state(of: .spotify) == .granted)
        center.refreshAutomationPermissions()
        center.resolve(.music, reminders: RemindersService(), calendar: CalendarService())
        await settle()
        precondition(probe.reads.count == 7 && probe.launches.count == 1, "Shutdown allowed new work")

        let missing = PermissionProbe(); missing.launchSucceeds = false
        let unavailable = PermissionsCenter(readAutomation: { await missing.read($0, $1) },
                                            launchAutomationTarget: { await missing.launch($0) })
        unavailable.resolve(.music, reminders: RemindersService(), calendar: CalendarService())
        await settle()
        precondition(unavailable.state(of: .music) == .unsupported && missing.reads.isEmpty,
                     "Missing target silently remained in ask-on-use loop")
        unavailable.stop()
        let retry = AutomationReadProbe([-600, -609, 0])
        let ready = await PermissionsCenter.automationState(ask: true, readResult: { await retry.read() }, wait: { await retry.wait($0) })
        precondition(ready == .granted && retry.readCount == 3 && retry.waitCount == 2)
        let passive = AutomationReadProbe([-600, 0])
        let passiveState = await PermissionsCenter.automationState(ask: false, readResult: { await passive.read() }, wait: { await passive.wait($0) })
        precondition(passiveState == .askOnUse && passive.readCount == 1 && passive.waitCount == 0)
        let stuck = AutomationReadProbe([-600, -600, -600, -600, 0])
        let stuckState = await PermissionsCenter.automationState(ask: true, readResult: { await stuck.read() }, wait: { await stuck.wait($0) })
        precondition(stuckState == .unavailable && stuck.readCount == 4 && stuck.waitCount == 3)
        let denied = AutomationReadProbe([-1743, 0])
        let deniedState = await PermissionsCenter.automationState(ask: true, readResult: { await denied.read() }, wait: { await denied.wait($0) })
        precondition(deniedState == .notGranted && denied.readCount == 1 && denied.waitCount == 0)
        print("PASS Permissions: cold launch retries are bounded; passive/denied requests never retry")
        print("PASS Permissions: 1000 passive refreshes / 2 queries; explicit request launches once; stale results ignored; unchanged states do not publish; shutdown cancels and rejects work; launch failure reported")
    }
}

@MainActor final class AutomationReadProbe {
    var results: [OSStatus]
    var readCount = 0
    var waitCount = 0
    init(_ results: [OSStatus]) { self.results = results }
    func read() -> OSStatus { readCount += 1; return results.removeFirst() }
    func wait(_ duration: Duration) { waitCount += 1 }
}
