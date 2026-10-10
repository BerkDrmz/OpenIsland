import AppKit
import AVFoundation

enum MotionStyle { case expressive, natural, reduced }

@MainActor enum PermissionsCenter {
    enum Pane {
        case camera
        var url: URL { URL(string: "about:blank")! }
    }
}

private final class FakeSession: CameraSessionBackend, @unchecked Sendable {
    var session: AVCaptureSession { fatalError("Tests must not create a live camera preview") }
    var onFailure: (@Sendable () -> Void)?
    let gate = DispatchSemaphore(value: 0)
    private var resets = 0
    var resetCount: Int { lock.withLock { resets } }
    private let lock = NSLock()
    private var active = 0
    private var starts = 0
    private var stops = 0
    private var configurations = 0
    private var running = false
    private var selections: [String?] = []
    var configuredSelections: [String?] { lock.withLock { selections } }
    var blockFirstConfiguration = false
    var startSucceeds = true
    var snapshot: (Int, Int, Int, Bool) { lock.withLock { (configurations, starts, stops, running) } }
    func configure(cameraID: String?) -> Bool {
        let block = lock.withLock {
            precondition(active == 0, "Configuration overlapped another session mutation")
            active += 1
            configurations += 1
            selections.append(cameraID)
            return blockFirstConfiguration && configurations == 1
        }
        if block { precondition(gate.wait(timeout: .now() + 5) == .success) }
        lock.withLock { active -= 1 }
        return true
    }
    func start() -> Bool {
        lock.withLock {
            precondition(active == 0, "Start overlapped configuration")
            starts += 1
            running = startSucceeds
            return running
        }
    }
    func stop() {
        lock.withLock {
            precondition(active == 0, "Stop overlapped configuration")
            stops += 1
            running = false
        }
    }
    func reset() {
        lock.withLock {
            precondition(active == 0, "Reset overlapped configuration")
            resets += 1
            running = false
        }
    }
}

@main struct CameraCheck {
    @MainActor static func main() async throws {
        let defaults = UserDefaults.standard
        let oldSelection = defaults.object(forKey: "mirrorCameraID")
        defer { defaults.set(oldSelection, forKey: "mirrorCameraID") }
        var factories = 0
        let pending = CameraMirror(makeSession: { factories += 1; return FakeSession() },
                                   readAuthorization: { .notDetermined }, requestAuthorization: { _ in })
        pending.start()
        pending.select(.init(id: "test-camera", name: "Test"))
        pending.stop()
        precondition(factories == 0 && pending.state == .idle, "Permissionless selection created a session")

        let fake = FakeSession()
        fake.blockFirstConfiguration = true
        let mirror = CameraMirror(makeSession: { fake }, readAuthorization: { .authorized })
        mirror.start()
        try await waitUntil { fake.snapshot.0 == 1 }
        mirror.stop()
        precondition(mirror.state == .idle)
        fake.gate.signal()
        try await waitUntil { fake.snapshot.2 == 1 }
        precondition(fake.snapshot.1 == 0 && !fake.snapshot.3, "Closed panel started stale camera work")
        mirror.start()
        try await waitUntil { mirror.state == .running }
        for _ in 0..<200 { mirror.stop(); mirror.start() }
        mirror.stop()
        try await waitUntil { fake.snapshot.2 >= 202 }
        precondition(!fake.snapshot.3 && mirror.state == .idle, "Rapid reopen left capture running")

        let switching = FakeSession()
        switching.blockFirstConfiguration = true
        let changingMirror = CameraMirror(makeSession: { switching }, readAuthorization: { .authorized })
        changingMirror.start()
        try await waitUntil { switching.snapshot.0 == 1 }
        for index in 0..<100 { changingMirror.select(.init(id: "camera-\(index)", name: "Test")) }
        switching.gate.signal()
        try await waitUntil { changingMirror.state == .running }
        precondition(switching.configuredSelections.last! == "camera-99" && switching.snapshot.1 == 1,
                     "Queued camera selections started stale capture sessions")
        changingMirror.stop()
        try await waitUntil { switching.snapshot.2 == 1 }

        fake.startSucceeds = false
        mirror.start()
        try await waitUntil { mirror.state == .unavailable }
        precondition(!fake.snapshot.3, "Failed start was published as running")

        // Cihazda görülen kopma: oturum başladıktan hemen sonra çalışma hatası (-11800, bayat CMIO girişi).
        let flaky = FakeSession()
        let recovering = CameraMirror(makeSession: { flaky }, readAuthorization: { .authorized })
        recovering.start()
        try await waitUntil { recovering.state == .running }
        let configurationsBefore = flaky.snapshot.0
        flaky.onFailure?()
        try await waitUntil { flaky.resetCount == 1 && recovering.state == .running && flaky.snapshot.0 > configurationsBefore }
        precondition(flaky.snapshot.3, "Recovered session is not running")

        for _ in 0..<CameraMirror.maximumRecoveries + 3 {
            flaky.onFailure?()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await waitUntil { recovering.state == .unavailable }
        precondition(!flaky.snapshot.3, "Repeated failure kept a broken session running")
        precondition(flaky.resetCount <= CameraMirror.maximumRecoveries + 1, "Failure recovery looped")

        recovering.start() // "Yeniden dene": yeni bir hak
        try await waitUntil { recovering.state == .running }
        recovering.stop()
        let resetsWhenClosed = flaky.resetCount
        flaky.onFailure?()
        try await Task.sleep(for: .milliseconds(50))
        precondition(recovering.state == .idle && flaky.resetCount == resetsWhenClosed, "Closed panel reacted to a stale failure")
        print("PASS Camera: permissionless selection is inert; close during blocked configuration never starts capture; 200 rapid cycles serialize and stop; 100 queued camera selections use only the latest; failed start reports unavailable; runtime failure reconnects once and recovers; repeated failure stops at unavailable without looping; retry restarts; closed panel ignores failures")
    }

    @MainActor private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        precondition(condition(), "Capture queue did not settle")
    }
}
