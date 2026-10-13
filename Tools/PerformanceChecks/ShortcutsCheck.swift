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
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--shutdown-fixture" {
            let path = CommandLine.arguments[2]
            let request = ShortcutsListRequest(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; echo $$ > \"$1\"; exec sleep 30", "fixture", path], timeout: 60)
            _ = Task.detached { request.run() }
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: path) {
                    request.cancel(immediately: true)
                    exit(0) // Deliberately do not await a future escalation closure.
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            request.cancel(immediately: true)
            exit(2)
        }
        let pidFile = AppPaths.support.appendingPathComponent("shutdown-fixture.pid")
        let host = Process()
        host.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        host.arguments = ["--shutdown-fixture", pidFile.path]
        try! host.run()
        host.waitUntilExit()
        precondition(host.terminationStatus == 0)
        let fixturePID = Int32(try! String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        for _ in 0..<100 {
            if kill(fixturePID, 0) != 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if kill(fixturePID, 0) == 0 {
            kill(fixturePID, SIGKILL)
            preconditionFailure("Listing survived immediate host shutdown")
        }
        print("PASS Shortcuts shutdown: TERM-ignoring owned listing does not survive host exit")
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
        let runningCancel = ShortcutsListRequest(executable: URL(fileURLWithPath: "/bin/sh"),
                                                arguments: ["-c", "trap '' TERM; exec sleep 4"], timeout: 30)
        let runningTask = Task.detached { runningCancel.run() }
        try? await Task.sleep(for: .milliseconds(100))
        let cancellationStarted = Date()
        runningCancel.cancel()
        if case .failure(.cancelled) = await runningTask.value {} else { preconditionFailure("Running cancellation lost") }
        precondition(Date().timeIntervalSince(cancellationStarted) < 1, "Cancellation waited for deadline")
        let eofStarted = Date()
        if case .failure(.timedOut) = await runCLI("/bin/sh", ["-c", "sleep 1 & exit 0"], timeout: 0.05) {} else {
            preconditionFailure("Inherited stdout EOF was not bounded")
        }
        precondition(Date().timeIntervalSince(eofStarted) < 0.8)
        try? await Task.sleep(for: .seconds(1)) // The check's short-lived descendant has now finished.
        let closedOutput = Date()
        if case .failure(.timedOut) = await runCLI("/bin/sh", ["-c", "exec 1>&-; trap '' TERM; exec sleep 2"], timeout: 0.03) {} else {
            preconditionFailure("Early stdout closure bypassed process deadline")
        }
        precondition(Date().timeIntervalSince(closedOutput) < 1)
        let busyOutput = Date()
        if case .failure(.timedOut) = await runCLI("/bin/sh", ["-c", "while :; do printf 'line\\n'; done"], timeout: 0.03) {} else {
            preconditionFailure("Continuous output starved deadline")
        }
        precondition(Date().timeIntervalSince(busyOutput) < 1)
        print("PASS Shortcuts process: cancellation, inherited/closed stdout, continuous-output deadline bounded")
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
