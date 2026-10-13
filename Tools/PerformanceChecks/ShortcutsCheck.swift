import AppKit

@MainActor enum AppPaths {
    static let support: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("openisland-shortcuts-\(UUID())")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
@MainActor final class IslandHold {
    func during<T>(_ action: () -> T) -> T { action() }
}

private actor FetchGate {
    private(set) var calls = 0
    private var pending: [Int: CheckedContinuation<ShortcutsListResult, Never>] = [:]
    func fetch() async -> ShortcutsListResult {
        calls += 1
        let id = calls
        return await withCheckedContinuation { pending[id] = $0 }
    }
    func finish(_ id: Int, _ result: ShortcutsListResult) {
        pending.removeValue(forKey: id)!.resume(returning: result)
    }
}

@main struct ShortcutsCheck {
    @MainActor static func wait(_ condition: () async -> Bool) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        preconditionFailure("Shortcuts test timed out")
    }
    @MainActor static func main() async {
        defer { try? FileManager.default.removeItem(at: AppPaths.support) }
        func runCLI(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) async -> ShortcutsListResult {
            let request = ShortcutsListRequest(executable: URL(fileURLWithPath: path), arguments: arguments, timeout: timeout)
            return await Task.detached { request.run() }.value
        }
        let successful = await runCLI("/usr/bin/printf", ["first\nsecond\n"])
        precondition((try? successful.get()) == ["first", "second"])
        let emptyCLI = await runCLI("/usr/bin/printf", [""])
        precondition((try? emptyCLI.get()) == [])
        if case .failure(.launch) = await runCLI("/does-not-exist", []) {} else { preconditionFailure("Missing executable was success") }
        if case .failure(.exit(1)) = await runCLI("/usr/bin/false", []) {} else { preconditionFailure("Failed exit was empty success") }
        if case .failure(.decoding) = await runCLI("/usr/bin/printf", ["\\377"]) {} else { preconditionFailure("Invalid UTF8 was empty success") }
        if case .failure(.timedOut) = await runCLI("/bin/sh", ["-c", "trap '' TERM; exec sleep 2"], timeout: 0.02) {} else { preconditionFailure("Stalled CLI was not bounded") }
        let cancelled = ShortcutsListRequest()
        cancelled.cancel()
        if case .failure(.cancelled) = cancelled.run() {} else { preconditionFailure("Cancelled request launched") }
        let gate = FetchGate()
        var clock = Date()
        let store = LauncherStore(fetchShortcuts: { await gate.fetch() }, now: { clock })
        let owner = Task { await store.refreshShortcutsIfNeeded() }
        await wait { await gate.calls == 1 }
        let joins = (0..<100).map { _ in Task { await store.refreshShortcutsIfNeeded() } }
        for _ in 0..<100 { await Task.yield() }
        let count1 = await gate.calls
        precondition(count1 == 1, "Tab changes duplicated the listing")
        await gate.finish(1, .success(["Original"]))
        await owner.value
        for task in joins { await task.value }
        precondition(store.availableShortcuts == ["Original"])
        clock += 301
        let failure = Task { await store.refreshShortcutsIfNeeded() }
        await wait { await gate.calls == 2 }
        await gate.finish(2, .failure(.exit(1)))
        await failure.value
        precondition(store.availableShortcuts == ["Original"], "Failure erased last successful list")
        await store.refreshShortcutsIfNeeded()
        let count2 = await gate.calls
        precondition(count2 == 2, "Failure caused subprocess thrashing")
        // Manual refresh bypasses the failure backoff. Successful empty is a real result.
        let empty = Task { await store.refreshShortcuts() }
        await wait { await gate.calls == 3 }
        await gate.finish(3, .success([]))
        await empty.value
        precondition(store.availableShortcuts.isEmpty)
        await store.refreshShortcutsIfNeeded()
        let count3 = await gate.calls
        precondition(count3 == 3, "Successful empty list was not cached")
        clock += 301
        let old = Task { await store.refreshShortcutsIfNeeded() }
        await wait { await gate.calls == 4 }
        store.shutdown()
        let new = Task { await store.refreshShortcuts() }
        await wait { await gate.calls == 5 }
        await gate.finish(5, .success(["New"]))
        await new.value
        await gate.finish(4, .success(["Stale"]))
        await old.value
        precondition(store.availableShortcuts == ["New"], "Obsolete completion overwrote current result")
        store.shutdown()
        print("PASS Shortcuts: 100 joins, failure preservation/backoff, manual retry, successful empty cache, stale completion rejection")
    }
}
