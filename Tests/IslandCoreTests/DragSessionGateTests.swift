import Testing
@testable import IslandCore

@Suite struct DragSessionGateTests {
    @Test func stalePasteboardDoesNotArm() {
        var gate = DragSessionGate(changeCount: 10)
        gate.mouseDown()
        var inspections = 0
        func inspect() -> Bool? { inspections += 1; return true }
        let armed = gate.activate(changeCount: 10, support: inspect())
        #expect(!armed)
        #expect(inspections == 0)
        #expect(!gate.isActive)
    }
    @Test func oneActivationPerGesture() {
        var gate = DragSessionGate(changeCount: 10)
        var inspections = 0
        func inspect() -> Bool? { inspections += 1; return true }
        let armed = gate.activate(changeCount: 11, support: inspect())
        #expect(armed)
        for _ in 0..<100 {
            let repeated = gate.activate(changeCount: 12, support: inspect())
            #expect(!repeated)
        }
        #expect(inspections == 1)
        gate.end(changeCount: 12)
        gate.mouseDown()
        let stale = gate.activate(changeCount: 12, support: true)
        let fresh = gate.activate(changeCount: 13, support: true)
        #expect(!stale && fresh)
    }
    @Test func emptyBoardMayBePopulatedWithSameCount() {
        var gate = DragSessionGate(changeCount: 1)
        gate.mouseDown()
        let pending = gate.activate(changeCount: 2, support: nil)
        let populated = gate.activate(changeCount: 2, support: true)
        #expect(!pending && populated)
    }
    @Test func earlyPasteboardClearBeforeMouseDown() {
        var gate = DragSessionGate(changeCount: 18)
        // Real event ordering: CG mouseDown/count18 -> NS mouseDown/count19
        // empty -> mouseDragged/count19 populated. Do not overwrite count18.
        gate.mouseDown()
        let ready = gate.activate(changeCount: 19, support: true)
        #expect(ready)
        gate.end(changeCount: 19)
        gate.mouseDown()
        let oldPayload = gate.activate(changeCount: 19, support: true)
        #expect(!oldPayload)
    }
    @Test func unsupportedChangeDoesNotBlockLaterSupportedChange() {
        var gate = DragSessionGate(changeCount: 1)
        let unsupported = gate.activate(changeCount: 2, support: false)
        let same = gate.activate(changeCount: 2, support: true)
        let supported = gate.activate(changeCount: 3, support: true)
        #expect(!unsupported && !same && supported)
        gate.end(changeCount: 3)
        gate.end(changeCount: 3)
        #expect(!gate.isActive)
    }
}
