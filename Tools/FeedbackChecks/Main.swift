import AppKit
import IslandCore
import UniformTypeIdentifiers

// Only unrelated presentation services are stubbed; ShelfStore and file operations are real.
enum AppPaths { static var support: URL { FileManager.default.temporaryDirectory } }
@MainActor final class IslandHold { func begin() {} ; func end() {} }
@MainActor class NotchPanel: NSPanel {}
extension CGRect { func containsInclusive(_ point: CGPoint) -> Bool { contains(point) } }
@MainActor final class QuickLookController {
    static let shared = QuickLookController()
    func preview(_ urls: [URL], from panel: NotchPanel?) {}
}

@main struct FeedbackChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openisland-import-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = ShelfStore(storage: root.appendingPathComponent("cache"),
                               persistenceURL: root.appendingPathComponent("shelf.json"))
        let names = ["rapor.pdf", "foto.png", "foto.jpg", "foto.jpeg", "archive.zip", "disk.dmg",
                     "film.mov", "film.mp4", "image.psd", "report.docx", "sheet.xlsx", "code.swift",
                     "data.json", "backup.tar.gz", "project.backup.zip", "README", ".hidden",
                     ".config.json", "İğdır şüphe ÇÖĞÜ.pdf", "REPORT.PDF", String(repeating: "long", count: 50) + ".pdf"]
        let bytes = Data([0, 255, 37, 80, 68, 70, 13, 10])
        let sources = try names.map { name in
            let url = root.appendingPathComponent(name)
            try bytes.write(to: url)
            return url
        }
        let pasteboard = NSPasteboard(name: .init("OpenIsland-check-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects(sources.map { $0 as NSURL })
        precondition(shelf.ingest(pasteboard: pasteboard))
        precondition(Set(shelf.items.map(\.url)) == Set(sources))
        for item in shelf.items {
            precondition(shelf.dragPayload(startingAt: item) == [item.url])
            let actual = try Data(contentsOf: item.url)
            precondition(actual == bytes)
        }
        shelf.removeAll()
        for source in sources { let actual = try Data(contentsOf: source); precondition(actual == bytes) }
        print("PASS: 21 named files via actual NSPasteboard → ShelfStore → outgoing file URL; sources unchanged after removal")

        let providers = sources.map { NSItemProvider(object: $0 as NSURL) }
        precondition(shelf.ingest(providers))
        try await waitUntil { shelf.items.count == sources.count }
        precondition(Set(shelf.items.map(\.url)) == Set(sources))
        shelf.removeAll()
        print("PASS: multi-file NSItemProvider URL import preserves source paths")

        let representations = sources.map { source in
            let provider = NSItemProvider()
            provider.suggestedName = source.lastPathComponent
            provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all) { done in
                done(source, false, nil)
                return nil
            }
            return provider
        }
        precondition(shelf.ingest(representations + representations))
        try await waitUntil { shelf.items.count == sources.count * 2 }
        precondition(Set(shelf.items.map(\.url)).count == sources.count * 2)
        for item in shelf.items {
            precondition(names.contains(item.name))
            let actual = try Data(contentsOf: item.url)
            precondition(actual == bytes)
        }
        let restored = ShelfStore(storage: root.appendingPathComponent("cache"),
                                  persistenceURL: root.appendingPathComponent("shelf.json"))
        restored.restore()
        try await waitUntil { restored.items.count == shelf.items.count }
        // Bookmark resolution canonicalizes /var to /private/var on macOS.
        precondition(Set(restored.items.map { $0.url.resolvingSymlinksInPath() })
            == Set(shelf.items.map { $0.url.resolvingSymlinksInPath() }))
        precondition(restored.items.allSatisfy { !$0.isMissing })
        shelf.removeAll()
        for source in sources { let actual = try Data(contentsOf: source); precondition(actual == bytes) }
        print("PASS: 42 parallel file representations preserve exact filenames/bytes and bookmark restore; no same-name overwrite")

        // Exercise real ditto round trips and failure cleanup using only this check's files.
        let operations = root.appendingPathComponent("operations")
        try FileManager.default.createDirectory(at: operations, withIntermediateDirectories: true)
        let archive = try ShelfFileOperations.zip([sources[0]], into: operations)
        let extracted = try ShelfFileOperations.unzip(archive, into: operations)
        let extractedBytes = try Data(contentsOf: extracted)
        precondition(extractedBytes == bytes)
        let extractedAgain = try ShelfFileOperations.unzip(archive, into: operations)
        precondition(extractedAgain != extracted)
        let extractedAgainBytes = try Data(contentsOf: extractedAgain)
        precondition(extractedAgainBytes == bytes)
        let sourceFolder = root.appendingPathComponent("folder-fixture")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try bytes.write(to: sourceFolder.appendingPathComponent("inside.txt"))
        let folderArchive = try ShelfFileOperations.zip([sourceFolder], into: operations)
        let folderResult = try ShelfFileOperations.unzip(folderArchive, into: operations)
        let folderBytes = try Data(contentsOf: folderResult.appendingPathComponent("inside.txt"))
        precondition(folderBytes == bytes && folderResult.lastPathComponent == "folder-fixture")
        let multiArchive = try ShelfFileOperations.zip([sources[0], sources[1]], into: operations)
        let multiResult = try ShelfFileOperations.unzip(multiArchive, into: operations)
        for source in [sources[0], sources[1]] {
            let extractedBytes = try Data(contentsOf: multiResult.appendingPathComponent(source.lastPathComponent))
            precondition(extractedBytes == bytes)
        }
        let broken = operations.appendingPathComponent("broken.zip")
        try bytes.write(to: broken)
        do {
            _ = try ShelfFileOperations.unzip(broken, into: operations)
            preconditionFailure("Corrupt archive unexpectedly succeeded")
        } catch {}
        let operationFiles = try FileManager.default.contentsOfDirectory(atPath: operations.path)
        precondition(!operationFiles.contains { $0.hasPrefix(".openisland-açılıyor-") }, "Failed extraction left scratch files")
        do {
            _ = try ShelfFileOperations.zip([operations.appendingPathComponent("missing.txt")], into: operations)
            preconditionFailure("Missing source unexpectedly succeeded")
        } catch {}
        precondition(!FileManager.default.fileExists(atPath: operations.appendingPathComponent("missing.zip").path))
        // More than the pipe buffer: wait-before-read would deadlock this child.
        do {
            try ShelfFileOperations.run("/usr/bin/perl", ["-e", "print STDERR 'x' x 262144; exit 1"])
            preconditionFailure("Failing child unexpectedly succeeded")
        } catch let error as ShelfFileOperations.Failure {
            precondition(error.message.count == 65536)
        }
        print("PASS: zip/unzip preserve bytes and unique names; corrupt/missing inputs leave no scratch/partial output; 256 KiB stderr drains without deadlock and retains at most 64 KiB")

        let lifecycle = SystemLifecycleMonitor()
        var locks = 0, unlocks = 0
        lifecycle.onLock = { locks += 1 }
        lifecycle.onUnlock = { unlocks += 1 }
        lifecycle.start()
        lifecycle.start()
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        precondition(locks == 1 && unlocks == 1)
        lifecycle.stop()
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        precondition(locks == 1 && unlocks == 1)
        print("PASS: public session events deduplicated; repeated start and stop leave no active observers")
    }

    @MainActor private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        precondition(condition(), "Asynchronous import did not complete")
    }
}
