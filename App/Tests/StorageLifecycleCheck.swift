import AppKit
import IslandCore

// Controlled blocking I/O simulates a Foundation metadata call which cannot be
// interrupted inside the call. Cancellation must reach the worker before its
// next volume, and retired workers must never publish into a reopened panel.
private final class ReadGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var began = false, cancelled = false, finished = false
    var state: (began: Bool, cancelled: Bool, finished: Bool) {
        lock.withLock { (began, cancelled, finished) }
    }
    func read() -> [StorageVolume] {
        lock.withLock { began = true }
        _ = release.wait(timeout: .now() + 5)
        lock.withLock { cancelled = Task.isCancelled; finished = true }
        return [StorageVolume(id: "fixture", name: "fixture", total: 100, available: 50, isInternal: true)]
    }
}
private actor CancellationStart {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
@main struct StorageLifecycleCheck {
    static func require(_ condition: Bool, _ message: String = "check failed") {
        if !condition { print("FAIL: \(message)"); exit(1) }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        for mode in ["close", "replace", "reopen"] {
            let gate = ReadGate()
            let monitor = SystemMonitor(readPublic: { .init(ticks: nil, gpu: nil, memory: nil, pressure: .normal) },
                                        readStorage: { gate.read() })
            monitor.privateEnabled = false
            monitor.panelDidAppear()
            monitor.refreshStorage(after: .zero)
            for _ in 0..<100 where !gate.state.began { try await Task.sleep(for: .milliseconds(5)) }
            require(gate.state.began, "test read did not start")
            if mode == "replace" { monitor.refreshStorage(after: .seconds(10)) }
            else {
                monitor.panelDidDisappear()
                if mode == "reopen" { monitor.panelDidAppear() }
            }
            gate.release.signal()
            for _ in 0..<100 where !gate.state.finished { try await Task.sleep(for: .milliseconds(5)) }
            require(gate.state.finished && gate.state.cancelled, "detached worker did not receive \(mode) cancellation")
            try await Task.sleep(for: .milliseconds(10))
            require(monitor.storageReadCount == 0 && monitor.storage.isEmpty, "retired read published after \(mode)")
            monitor.stop()
            require(monitor.storageObserverCount == 0 && !monitor.isRunning)
            print("PASS: \(mode) propagates cancellation; stale metadata discarded; observers released")
        }
        let start = CancellationStart()
        let read = Task.detached {
            await start.wait()
            return StorageVolume.read()
        }
        for _ in 0..<100 {
            if await start.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let entered = await start.entered
        require(entered, "cancelled-read fixture did not enter")
        read.cancel()
        await start.release()
        let cancelledVolumes = await read.value
        require(cancelledVolumes.isEmpty, "already-cancelled volume enumeration must return immediately")
        print("PASS: already-cancelled real storage reader returns without enumeration")
    }
}
