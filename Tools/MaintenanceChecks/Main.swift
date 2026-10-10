import AppKit
import Darwin
import IslandCore

private actor UpdateCheckProbe {
    private(set) var calls = 0
    let availableID: String, failingID: String
    init(availableID: String, failingID: String) { self.availableID = availableID; self.failingID = failingID }
    func check(_ app: ManagedApplication) async throws -> MaintenanceUpdate {
        calls += 1
        try await Task.sleep(for: .milliseconds(40))
        if app.bundleID == failingID { throw MaintenanceError.invalidFeed }
        if app.bundleID == availableID { return .init(status: .available, message: "Yeni sürüm: 1.3", destination: URL(string: "https://example.com/fixture.dmg")) }
        if app.bundleID == "io.openisland.updates.current" { return .init(status: .current, message: "Güncel", destination: nil) }
        return .init(status: .unsupported, message: "Desteklenmiyor", destination: nil)
    }
}

@main struct MaintenanceChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run() }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
            app.terminate(nil)
        }
        app.run()
    }

    @MainActor static func run() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("OpenIslandMaintenanceFixture-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let canonical = realpath(temporary.path, nil)!
        let root = URL(fileURLWithPath: String(cString: canonical))
        free(canonical)
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), apps = root.appendingPathComponent("Applications")
        let library = home.appendingPathComponent("Library")
        let id = "io.openisland.fixture.\(UUID().uuidString)", otherID = id + "Other"
        func write(_ url: URL, _ content: Data = Data("fixture".utf8)) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url)
        }
        func bundle(_ id: String, _ name: String) throws -> URL {
            let url = apps.appendingPathComponent(name + ".app")
            let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name,
                                       "CFBundleShortVersionString": "1.2", "CFBundleVersion": "12"]
            try write(url.appendingPathComponent("Contents/Info.plist"), PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
            return url
        }
        let appURL = try bundle(id, "Fixture"), otherURL = try bundle(otherID, "FixtureOther")
        _ = try bundle("io.github.openisland.OpenIsland", "OpenIsland")
        let cache = library.appendingPathComponent("Caches/\(id)")
        try write(cache.appendingPathComponent("blob"), Data(repeating: 1, count: 128))
        try write(library.appendingPathComponent("Caches/\(otherID)/blob"))
        let personal = library.appendingPathComponent("Application Support/\(id)/document")
        try write(personal)
        let shelf = library.appendingPathComponent("Caches/io.github.openisland/Shelf/keep")
        try write(shelf)
        try write(library.appendingPathComponent("Preferences/\(id).plist"))
        try write(library.appendingPathComponent("Preferences/ByHost/\(id).12345678-1234-1234-1234-123456789ABC.plist"))
        try write(library.appendingPathComponent("Saved Application State/\(id).savedState/windows"))
        let outside = root.appendingPathComponent("outside/untouchable")
        try write(outside, Data(repeating: 3, count: 8192))
        try fm.createSymbolicLink(at: cache.appendingPathComponent("external"), withDestinationURL: outside.deletingLastPathComponent())
        try fm.createSymbolicLink(at: apps.appendingPathComponent("Alias.app"), withDestinationURL: otherURL)
        try fm.createSymbolicLink(at: library.appendingPathComponent("Logs"), withDestinationURL: outside.deletingLastPathComponent())
        let worker = MaintenanceWorker(home: home, appRoots: [apps])
        let catalog = try await worker.applications()
        precondition(catalog.count == 3, "App alias must not enter the catalog")
        let app = catalog.first { $0.bundleID == id }!
        let files = try await worker.remnants(for: app)
        let cacheFile = files.first { $0.url.path == cache.path }!
        precondition(cacheFile.bytes == 128, "Symlink target must not be traversed or counted")
        precondition(files.contains { $0.containsPersonalData })
        precondition(files.filter { $0.kind == .preferences }.count == 2 && files.contains { $0.kind == .savedState })
        precondition(!files.contains { $0.url.path.contains(otherID) || $0.url.path.contains("Logs/") })
        let protected = catalog.first { $0.bundleID == "io.github.openisland.OpenIsland" }!
        let canRemoveSelf = await worker.removable(protected)
        precondition(canRemoveSelf == false)
        do { _ = try await worker.remnants(for: protected); preconditionFailure("OpenIsland removal allowed") }
        catch MaintenanceError.protectedApplication { }
        print("PASS: exact app identity, unrelated data preserved, protected self, aliases/ancestor symlinks excluded; personal data identified")

        // Substitute a same-path node after the scan: the old snapshot must not be reusable.
        let old = cache.appendingPathExtension("old")
        try fm.moveItem(at: cache, to: old)
        try write(cache.appendingPathComponent("replacement"))
        do { try await worker.trash(cacheFile, app: app); preconditionFailure("Replaced node was removed") }
        catch MaintenanceError.changed { }
        precondition(fm.fileExists(atPath: cache.appendingPathComponent("replacement").path))
        print("PASS: replaced file identity rejected before trash")

        // Only our unique disposable fixture is actually moved; no user application is touched.
        let uniqueName = "OpenIslandTrashFixture-\(UUID().uuidString)"
        let trashFile = library.appendingPathComponent("Caches/\(uniqueName)")
        try write(trashFile)
        let caches = try await worker.caches()
        precondition(!caches.contains { $0.url.lastPathComponent == "io.github.openisland" }, "Shelf's only-copy files must not be offered as disposable caches")
        let snapshot = caches.first { $0.url.path == trashFile.path }!
        let destination = try await worker.trash(snapshot, app: nil)
        precondition(!fm.fileExists(atPath: trashFile.path))
        if let destination {
            precondition(destination.lastPathComponent.hasPrefix(uniqueName))
            let restored = try Data(contentsOf: destination)
            precondition(restored == Data("fixture".utf8))
            try fm.removeItem(at: destination)
        }
        precondition(fm.fileExists(atPath: personal.path) && fm.fileExists(atPath: appURL.path) && fm.fileExists(atPath: outside.path) && fm.fileExists(atPath: shelf.path))
        print("PASS: fixture trash operation works; personal documents, other app and symlink target untouched")
        let cancelled = Task { try await worker.applications() }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled inventory completed") }
        catch is CancellationError { }
        print("PASS: cancelled scans stop")

        // Exercise controller workflows against disposable data and a fake catalog, never an installer.
        _ = try bundle("io.openisland.updates.current", "Current")
        if let runningID = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).first,
           MaintenanceRules.validComponent(runningID), runningID != "io.github.openisland.OpenIsland" {
            try write(library.appendingPathComponent("Caches/\(runningID)/active"))
        }
        let probe = UpdateCheckProbe(availableID: id, failingID: otherID)
        var opened: [URL] = []
        let batch = MaintenanceController(worker: worker, updateChecker: { try await probe.check($0) },
                                          updateOpener: { opened.append($0); return true })
        func waitForCompletion(_ controller: MaintenanceController) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while controller.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            precondition(!controller.busy, "Workflow failed to finish")
        }
        func pressSheetButton(_ title: String) {
            let window = NSApp.windows.first { $0.identifier?.rawValue == "OpenIslandMaintenance" && $0.attachedSheet != nil }!
            func find(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == title { return button }
                for child in view.subviews { if let button = find(child) { return button } }
                return nil
            }
            find(window.attachedSheet!.contentView!)!.performClick(nil)
        }
        batch.open()
        try await waitForCompletion(batch)
        let initialQueries = await probe.calls
        precondition(initialQueries == 0, "Opening other tools must not query update sources")
        batch.select(.cleaner); batch.scan()
        try await waitForCompletion(batch)
        batch.selectAllCaches()
        precondition(batch.selectedFiles == Set(batch.files.filter { !batch.blocked($0) }.map(\.id)))
        precondition(!batch.files.contains { batch.blocked($0) && batch.selectedFiles.contains($0.id) })
        precondition(!batch.files.contains { $0.url.lastPathComponent == "io.github.openisland" })
        print("PASS: cache Select All selects every eligible item; excludes running apps and Shelf's only-copy files")

        batch.select(.updater) // This action alone must start the full scan.
        try await waitForCompletion(batch)
        let firstQueries = await probe.calls
        precondition(firstQueries == 4 && batch.updatesChecked == 4 && batch.updatesScanned)
        precondition(batch.availableUpdateApplications.count == 1 && batch.visibleApplications.count == 1)
        precondition(batch.updates.values.contains { $0.status == .failed } && batch.updates.values.contains { $0.status == .current })
        precondition(opened.isEmpty && batch.selectedUpdates.isEmpty, "A scan must never start a download or approve an app")
        for _ in 0..<10 { batch.select(.cleaner); batch.select(.updater) }
        let repeatedQueries = await probe.calls
        precondition(repeatedQueries == firstQueries && !batch.hasActiveTask)
        batch.selectedUpdates = [app.id, catalog.first { $0.bundleID == otherID }!.id]
        batch.confirmSelectedUpdates()
        try await Task.sleep(for: .milliseconds(200))
        precondition(opened.isEmpty, "Confirmation dialog opened a destination before approval")
        pressSheetButton("Vazgeç")
        try await Task.sleep(for: .milliseconds(300))
        precondition(opened.isEmpty)
        batch.confirmSelectedUpdates()
        try await Task.sleep(for: .milliseconds(200))
        pressSheetButton("Onayla ve Aç")
        try await Task.sleep(for: .milliseconds(300))
        precondition(opened == [URL(string: "https://example.com/fixture.dmg")!], "Only selected available updates may open; failed/current apps must be excluded")
        print("PASS: automatic full scan, mixed results, 10 re-entries reuse results; no download before approval; cancel opens nothing; approval opens only the selected available update")
        batch.checkAllUpdates(force: true)
        try await waitForCompletion(batch)
        let refreshedQueries = await probe.calls
        precondition(refreshedQueries == firstQueries * 2)
        batch.checkAllUpdates(force: true)
        try await Task.sleep(for: .milliseconds(5))
        batch.select(.cleaner)
        try await Task.sleep(for: .milliseconds(100))
        precondition(!batch.busy && !batch.hasActiveTask && !batch.isScanningUpdates)
        let cancelledQueries = await probe.calls
        precondition(cancelledQueries <= refreshedQueries + 1, "Leaving the section let the remaining requests run")
        batch.select(.updater)
        batch.shutdown()
        try await Task.sleep(for: .milliseconds(100))
        precondition(batch.observerCount == 0 && !batch.hasActiveTask && !batch.isPresented)
        print("PASS: explicit refresh rechecks; leaving the section or closing cancels the batch and releases observers")

        let catalogWorker = MaintenanceWorker(sourceLoader: { url in
            try Task.checkCancellation()
            if url.host == "itunes.apple.com" {
                return Data("""
                {"results":[{"bundleId":"net.whatsapp.WhatsApp","version":"26.39.75","kind":"software",
                "trackId":310633997,"supportedDevices":["MacDesktop-MacDesktop"]}]}
                """.utf8)
            }
            if url.lastPathComponent == "spotify.json" {
                return Data("""
                {"token":"spotify","version":"1.3.4.258","homepage":"https://www.spotify.com/download/",
                "artifacts":[{"uninstall":[{"quit":"com.spotify.client"}]}]}
                """.utf8)
            }
            if url.lastPathComponent == "editor.json" {
                return Data("""
                {"token":"editor","version":"99.0","homepage":"https://example.com/download",
                "artifacts":[{"uninstall":[{"quit":"com.fixture.Namesake"}]}]}
                """.utf8)
            }
            throw MaintenanceError.sourceNotFound
        })
        func catalogApp(_ id: String, _ filename: String, _ version: String, store: Bool = false) -> ManagedApplication {
            .init(url: URL(fileURLWithPath: "/Applications/\(filename).app"), bundleID: id, name: filename,
                  version: version, build: "1", bundleName: filename, appcast: nil, isStore: store)
        }
        let spotifyUpdate = try await catalogWorker.checkUpdate(catalogApp("com.spotify.client", "Spotify", "1.3.3.264"))
        precondition(spotifyUpdate.status == .available && spotifyUpdate.destination?.host == "www.spotify.com")
        let spotifyCurrent = try await catalogWorker.checkUpdate(catalogApp("com.spotify.client", "Spotify", "1.3.4.258"))
        precondition(spotifyCurrent.status == .current && spotifyCurrent.destination == nil)
        let unifiedUpdate = try await catalogWorker.checkUpdate(catalogApp("net.whatsapp.WhatsApp", "WhatsApp", "26.38.74", store: true))
        precondition(unifiedUpdate.status == .available && unifiedUpdate.destination?.scheme == "macappstore")
        let namesake = try await catalogWorker.checkUpdate(catalogApp("com.fixture.Editor", "Editor", "1.0"))
        precondition(namesake.status == .unsupported && namesake.destination == nil)
        let missing = try await catalogWorker.checkUpdate(catalogApp("com.fixture.Unknown", "Unknown", "1.0"))
        precondition(missing.status == .unsupported)
        let cancelledCatalog = Task { try await catalogWorker.checkUpdate(catalogApp("com.spotify.client", "Spotify", "1.0")) }
        cancelledCatalog.cancel()
        do { _ = try await cancelledCatalog.value; preconditionFailure("Cancelled catalog ran") }
        catch is CancellationError { }
        print("PASS: Spotify full/current levels, unified Mac Store updates, namesake rejection, missing source and cancellation")

        if ProcessInfo.processInfo.environment["OPENISLAND_UPDATE_CHECK"] == "1" {
            let actualWorker = MaintenanceWorker()
            let installed = try await actualWorker.applications()
            for id in ["org.wireshark.Wireshark", "com.apple.dt.Xcode"] {
                if let app = installed.first(where: { $0.bundleID == id }) {
                    let result = try await actualWorker.checkUpdate(app)
                    print("LIVE UPDATE: \(app.name): \(result.message)")
                }
            }
        }

        let tools = MaintenanceController(worker: worker, updateChecker: { try await probe.check($0) }, updateOpener: { _ in true })
        for _ in 0..<100 {
            tools.open()
            precondition(tools.observerCount == 2 && tools.isPresented)
            tools.open()
            precondition(tools.observerCount == 2, "Repeated open registered extra observers")
            tools.shutdown()
            precondition(tools.observerCount == 0 && !tools.hasActiveTask && !tools.isPresented)
        }
        print("PASS: 100 open/close cycles; no accumulated observers/tasks/windows")
        if ProcessInfo.processInfo.environment["OPENISLAND_VISUAL_CHECK"] == "1" {
            tools.open()
            try await Task.sleep(for: .seconds(2))
            for section in MaintenanceController.Section.allCases {
                tools.select(section)
                if section != .updater {
                    tools.choose(app)
                    tools.scan()
                    let deadline = ContinuousClock.now + .seconds(5)
                    while tools.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                    precondition(!tools.busy && !tools.files.isEmpty)
                    if section == .uninstaller {
                        precondition(!tools.files.contains { $0.containsPersonalData && tools.selectedFiles.contains($0.id) })
                    } else { precondition(tools.selectedFiles.isEmpty, "Cache cleanup must require an explicit selection") }
                } else { try await waitForCompletion(tools) }
                try await Task.sleep(for: .milliseconds(200))
                let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "OpenIslandMaintenance" })!
                precondition(abs(window.contentView!.bounds.height - 590) < 2, "Switching tools changed the window height")
                if let view = window.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/openisland-maintenance-\(section.id).png"))
                }
            }
            let start = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
            try await Task.sleep(for: .seconds(8))
            let elapsed = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - start) / 1e9
            print(String(format: "STATIC OPEN: %.4f CPU seconds / 8s = %.4f%% of one core", elapsed, elapsed / 8 * 100))
            tools.shutdown()
        }
        try await Task.sleep(for: .seconds(1)) // Let window teardown and cancelled queue entries settle.
        let start = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        try await Task.sleep(for: .seconds(8))
        let elapsed = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - start) / 1e9
        print(String(format: "CLOSED IDLE: %.4f CPU seconds / 8s = %.4f%% of one core", elapsed, elapsed / 8 * 100))
    }
}
