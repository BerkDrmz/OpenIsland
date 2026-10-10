import Foundation
import Testing
@testable import IslandCore

@Suite("Odak oturumu geri yükleme")
struct FocusSessionRestoreTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let duration: TimeInterval = 25 * 60

    @Test func runningSessionContinuesToSameEnd() {
        let end = now.addingTimeInterval(600)
        #expect(FocusSessionRestore.resolve(state: "running", end: end, remaining: nil, phaseDuration: duration, now: now)
                == .running(end: end))
    }

    @Test func sessionThatEndedWhileClosedAdvances() {
        #expect(FocusSessionRestore.resolve(state: "running", end: now.addingTimeInterval(-1), remaining: nil,
                                            phaseDuration: duration, now: now) == .finishedWhileClosed)
    }

    @Test func clockMovedBackDoesNotExtendBeyondPhase() {
        let restored = FocusSessionRestore.resolve(state: "running", end: now.addingTimeInterval(duration * 3), remaining: nil,
                                                   phaseDuration: duration, now: now)
        #expect(restored == .running(end: now.addingTimeInterval(duration)))
    }

    /// QA OI-02: duraklatılmış 2:28:18, yeniden açılışta 2:29:00'a (tam süreye) dönüyordu.
    @Test func pausedSessionKeepsRemainingTime() {
        let remaining: TimeInterval = 2 * 3600 + 28 * 60 + 18
        #expect(FocusSessionRestore.resolve(state: "paused", end: nil, remaining: remaining, phaseDuration: 149 * 60, now: now)
                == .paused(remaining: remaining))
        #expect(FocusSessionRestore.resolve(state: "paused", end: nil, remaining: duration * 2, phaseDuration: duration, now: now)
                == .paused(remaining: duration), "Süre kısaltıldıysa kalan süre yeni süreyi aşmaz")
    }

    @Test func missingOrInvalidStateIsIdle() {
        #expect(FocusSessionRestore.resolve(state: nil, end: nil, remaining: nil, phaseDuration: duration, now: now) == .idle)
        #expect(FocusSessionRestore.resolve(state: "paused", end: nil, remaining: .nan, phaseDuration: duration, now: now) == .idle)
        #expect(FocusSessionRestore.resolve(state: "paused", end: nil, remaining: 0, phaseDuration: duration, now: now) == .idle)
        #expect(FocusSessionRestore.resolve(state: "running", end: nil, remaining: nil, phaseDuration: duration, now: now) == .idle)
    }
}
