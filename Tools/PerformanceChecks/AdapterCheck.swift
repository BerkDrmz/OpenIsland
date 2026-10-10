import Foundation

@main struct AdapterCheck {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openisland-adapter-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-adapter.pl")
        let count = root.appendingPathComponent("starts")
        // The framework argument becomes a private marker path in this minimal test publisher.
        try "open my $f, '>>', $ARGV[0] or die; print $f \"start\\n\"; close $f; exit 0;".write(to: script, atomically: true, encoding: .utf8)
        let adapter = MediaRemoteAdapterSource(paths: .init(script: script, framework: count))
        adapter.start()
        try await Task.sleep(for: .milliseconds(400)) // process exits and schedules 2-second recovery
        adapter.stop()
        try await Task.sleep(for: .seconds(2.3))
        let starts = try String(contentsOf: count, encoding: .utf8).split(separator: "\n")
        precondition(starts.count == 1, "A stopped adapter restarted in the background")
        adapter.start()
        try await Task.sleep(for: .milliseconds(300))
        adapter.stop()
        let final = try String(contentsOf: count, encoding: .utf8).split(separator: "\n")
        precondition(final.count == 2, "Explicit restart failed")
        print("PASS: real adapter process exit → pending restart → stop cancels recovery; explicit restart still works")
    }
}
