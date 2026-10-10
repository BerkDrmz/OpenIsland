import Testing
@testable import IslandCore

@Suite struct EventPerformanceTests {
    @Test func stableNetworkHasNoRepeatedNotice() {
        var state = NetworkTransitionState()
        #expect(state.update(isAvailable: true) == nil)
        for _ in 0..<1000 { #expect(state.update(isAvailable: true) == nil) }
        #expect(state.update(isAvailable: false) == false)
        #expect(state.update(isAvailable: false) == nil)
        #expect(state.update(isAvailable: true) == true)
        #expect(state.update(isAvailable: false) == false)
    }
    @Test func offlineStartupDoesNotPretendToBeAChange() {
        var state = NetworkTransitionState()
        #expect(state.update(isAvailable: false) == nil)
        #expect(state.update(isAvailable: true) == true)
    }
    private func display(_ id: UInt32, x: Double = 0, width: Double = 1920) -> ExternalDisplayConfiguration {
        .init(id: id, name: "Display \(id)", x: x, y: 0, width: width, height: 1080, scale: 1)
    }
    @Test func displaysBaselineDedupLayoutConnectDisconnect() {
        let a = display(1), b = display(2)
        var state = ExternalDisplayTransitions([a])
        for _ in 0..<1000 { #expect(state.update([a]).isEmpty) }
        #expect(state.update([b, a]).map(\.1) == [.connected])
        #expect(state.update([a, b]).isEmpty) // ordering isn't a new display configuration
        #expect(state.update([display(1, x: -1920), b]).map(\.1) == [.configuration])
        #expect(state.update([display(1, x: -1920, width: 1280), b]).map(\.1) == [.configuration])
        #expect(state.update([]).map(\.1) == [.disconnected, .disconnected])
        #expect(state.update([]).isEmpty)
        #expect(state.update([a]).map(\.1) == [.connected])
    }
    @Test func nearCompleteIsNotSuccessful() {
        #expect(TransferOutcome.terminal(fraction: 0.99, isFinished: false, isCancelled: false) == .interrupted)
        #expect(TransferOutcome.terminal(fraction: 1, isFinished: true, isCancelled: true) == .cancelled)
        #expect(TransferOutcome.terminal(fraction: 1, isFinished: false, isCancelled: false) == .completed)
    }
    @Test func chargingChangesWithoutAdapterChangeAreReportedOnce() {
        let stopped = PowerSnapshot(level: 0.8, isOnAC: true, isCharging: false, isCharged: false)
        var charging = stopped; charging.isCharging = true
        #expect(PowerEvent.Kind.transition(from: stopped, to: charging) == .chargingStarted)
        #expect(PowerEvent.Kind.transition(from: charging, to: charging) == nil)
        #expect(PowerEvent.Kind.transition(from: charging, to: stopped) == .chargingStopped)
        var full = stopped; full.level = 1; full.isCharged = true
        #expect(PowerEvent.Kind.transition(from: charging, to: full) == .full)
    }
    @Test func lowBatteryCanRearmAfterLeavingThreshold() {
        let normal = PowerSnapshot(level: 0.21, isOnAC: false, isCharging: false, isCharged: false)
        var low = normal; low.level = 0.2
        #expect(PowerEvent.Kind.transition(from: normal, to: low) == .low)
        #expect(PowerEvent.Kind.transition(from: low, to: low) == nil)
        #expect(PowerEvent.Kind.transition(from: low, to: normal) == nil)
        #expect(PowerEvent.Kind.transition(from: normal, to: low) == .low)
    }
    @Test func rapidHoverInvalidatesScheduledSleeps() {
        var machine = IslandMachine()
        for _ in 0..<1000 {
            let effects = machine.send(.pointerEntered)
            guard case let .schedule(timer, token, _) = effects.first else { Issue.record("Missing hover deadline"); return }
            #expect(machine.isTimerCurrent(timer, token: token))
            machine.send(.pointerExited)
            #expect(!machine.isTimerCurrent(timer, token: token))
            machine.send(.timerFired(timer, token: token))
            #expect(!machine.isExpanded)
        }
    }
}
