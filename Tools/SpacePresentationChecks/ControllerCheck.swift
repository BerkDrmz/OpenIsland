import AppKit
import IslandCore

@MainActor final class TestWindow: NSWindow {
    let testNumber: Int
    var testVisible = true
    override var windowNumber: Int { testNumber }
    override var isVisible: Bool { testVisible }
    init(_ number: Int) {
        testNumber = number
        super.init(contentRect: CGRect(x: 20, y: 30, width: 80, height: 60), styleMask: .borderless, backing: .buffered, defer: true)
        isReleasedWhenClosed = false
    }
}
@MainActor final class Backend: SpaceMembershipProbe {
    var visible: [Int: Bool] = [:]
    var memberships: [Int: [UInt64]] = [:]
    var repairsMembership = false
    func managedSpaces(of windowNumber: Int) -> [UInt64]? { memberships[windowNumber] ?? [] }
}
@MainActor final class FakeProvider: SpaceProvider {
    let kind: SpaceProviderKind
    let backend: Backend
    var isAvailable = true
    var installs: [Int: Int] = [:]
    var uninstalls = 0
    var stopped = false
    init(_ kind: SpaceProviderKind, backend: Backend) { self.kind = kind; self.backend = backend }
    func install(_ windows: [NSWindow]) {
        for window in windows {
            installs[window.windowNumber, default: 0] += 1
            if kind == .privateSpace, backend.repairsMembership { backend.memberships[window.windowNumber] = [] }
        }
    }
    func uninstall(_ windows: [NSWindow]) { uninstalls += windows.count }
    func tearDown() { stopped = true }
}
@MainActor struct Fixture {
    let backend = Backend()
    let primary: FakeProvider
    let publicProvider: FakeProvider
    let fallback: FakeProvider
    let controller: SpacePresentationController
    init() {
        primary = FakeProvider(.privateSpace, backend: backend)
        publicProvider = FakeProvider(.publicStationary, backend: backend)
        fallback = FakeProvider(.safeFallback, backend: backend)
        let b = backend
        controller = SpacePresentationController(providers: [.privateSpace: primary, .publicStationary: publicProvider, .safeFallback: fallback],
            probe: b, isOnScreen: { b.visible[$0] ?? true }, repairDelays: [.milliseconds(10), .milliseconds(20)],
            retryDelays: [.milliseconds(10), .milliseconds(20), .milliseconds(30)])
    }
    func signalSpace() { NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil) }
}
@main struct ControllerCheck {
    @MainActor static func pause(_ milliseconds: Int = 5) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
    @MainActor static func check(_ ok: @autoclosure () -> Bool, _ message: String) {
        if !ok() { fatalError(message) }
        print("PASS: \(message)")
    }
    @MainActor static func main() async {
        _ = NSApplication.shared
        let transient = Fixture(), first = TestWindow(911001)
        transient.controller.attach([first]); await pause()
        let frame = first.frame
        transient.backend.visible[first.windowNumber] = false
        transient.signalSpace(); await pause(2)
        check(transient.primary.uninstalls == 0 && transient.controller.activeProviders == [.privateSpace], "transient offscreen keeps private ownership")
        transient.backend.visible[first.windowNumber] = true
        await pause(40)
        check(transient.controller.status == .settled(provider: .privateSpace, behavior: .pinned) && first.frame == frame, "settling restores pinned without frame writes")
        transient.controller.tearDown()

        let membership = Fixture(), second = TestWindow(911002)
        membership.controller.attach([second]); await pause()
        membership.backend.memberships[second.windowNumber] = [1, 442]
        membership.backend.repairsMembership = true
        membership.signalSpace(); await pause(40)
        check(membership.primary.uninstalls == 0 && membership.controller.status == .settled(provider: .privateSpace, behavior: .pinned), "managed membership repaired in place before fallback")
        membership.controller.tearDown()

        let siblings = Fixture(), healthy = TestWindow(911003), broken = TestWindow(911004)
        siblings.backend.visible[broken.windowNumber] = false
        siblings.controller.attach([healthy, broken]); await pause(250)
        for _ in 0..<8 { siblings.signalSpace(); await pause(5) }
        let total = siblings.primary.installs[broken.windowNumber, default: 0]
        await pause(100)
        check(total == 12 && siblings.primary.installs[broken.windowNumber] == total, "one broken sensor has exactly 4 attempts with 2 repairs each; healthy sibling cannot reset budget")
        check(siblings.controller.activeProviders.contains(.safeFallback), "persistent failure reaches visible fallback and stops retrying")
        siblings.backend.visible[broken.windowNumber] = true
        siblings.controller.attach([healthy, broken]); await pause(40)
        check(siblings.controller.activeProviders == [.privateSpace], "screen reattach recovers all members and resets only the new recovery budget")
        let beforeWake = siblings.primary.installs[healthy.windowNumber, default: 0]
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await pause(40)
        check(siblings.primary.installs[healthy.windowNumber, default: 0] > beforeWake
              && siblings.controller.activeProviders == [.privateSpace], "wake reinstalls even already-primary members")
        siblings.controller.tearDown()

        let removed = Fixture(), third = TestWindow(911005)
        removed.backend.visible[third.windowNumber] = false
        removed.controller.attach([third]); await pause(2)
        removed.controller.detach([third])
        let detachedCount = removed.primary.installs[third.windowNumber]
        await pause(100)
        check(removed.primary.installs[third.windowNumber] == detachedCount && removed.controller.activeProviders.isEmpty, "removed display cancels pending repairs and stale verification")
        removed.controller.tearDown()

        let shutdown = Fixture(), fourth = TestWindow(911006)
        shutdown.backend.visible[fourth.windowNumber] = false
        shutdown.controller.attach([fourth]); await pause(2)
        shutdown.controller.tearDown()
        let beforeShutdown = shutdown.primary.installs[fourth.windowNumber]
        await pause(100)
        check(shutdown.primary.installs[fourth.windowNumber] == beforeShutdown && shutdown.controller.status == .pending, "shutdown cancels pending repair and cannot reinstall closed windows")
        print("All actual-controller lifecycle checks passed.")
    }
}
