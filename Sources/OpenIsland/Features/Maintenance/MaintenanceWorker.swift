import Foundation
import IslandCore
import Darwin

struct ManagedApplication: Identifiable, Sendable, Equatable {
    var id: String { url.path }
    let url: URL
    let bundleID: String
    let name: String
    let version: String
    let bundleName: String
}

struct MaintenanceFile: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let kind: MaintenanceRules.Kind?
    let bytes: Int64
    let fullyMeasured: Bool
    let verifiedIdentity: Bool
    let isApplication: Bool
    let device: Int32
    let inode: UInt64
    var containsPersonalData: Bool { kind == .data }
}

/// All enumeration and size measurement are user-initiated, serial, cancellable and off the UI thread.
actor MaintenanceWorker {
    let home: URL
    let appRoots: [URL]
    let protectedBundleID: String
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         appRoots: [URL]? = nil, protectedBundleID: String = Bundle.main.bundleIdentifier ?? "io.github.openisland.OpenIsland") {
        self.home = home
        self.appRoots = appRoots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        self.protectedBundleID = protectedBundleID
    }

    func applications() throws -> [ManagedApplication] {
        try Task.checkCancellation()
        let fm = FileManager.default
        var found: [ManagedApplication] = []
        for root in appRoots {
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = iterator.nextObject() as? URL {
                try Task.checkCancellation()
                if iterator.level > 3 { iterator.skipDescendants(); continue }
                guard url.pathExtension == "app" else { continue }
                iterator.skipDescendants()
                guard safeAncestors(url, root: root), let app = application(at: url) else { continue }
                found.append(app)
            }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func remnants(for app: ManagedApplication) throws -> [MaintenanceFile] {
        guard removable(app) else { throw MaintenanceError.protectedApplication }
        let library = home.appendingPathComponent("Library")
        var result: [MaintenanceFile] = []
        // Measure the app once, not on every row redraw.
        if let file = try snapshot(app.url, kind: nil, verified: true, application: true) { result.append(file) }
        for location in MaintenanceRules.locations(bundleID: app.bundleID, names: [app.name, app.bundleName, app.url.deletingPathExtension().lastPathComponent]) {
            let url = library.appendingPathComponent(location.relativePath)
            guard safeAncestors(url, root: library) else { continue }
            if let file = try snapshot(url, kind: location.kind, verified: location.verifiedIdentity) { result.append(file) }
        }
        let byHost = library.appendingPathComponent("Preferences/ByHost")
        if let entries = try? FileManager.default.contentsOfDirectory(at: byHost, includingPropertiesForKeys: nil) {
            for url in entries where MaintenanceRules.isByHostPreference(url.lastPathComponent, bundleID: app.bundleID) {
                try Task.checkCancellation()
                guard safeAncestors(url, root: library) else { continue }
                if let file = try snapshot(url, kind: .preferences, verified: true) { result.append(file) }
            }
        }
        return result
    }

    func caches() throws -> [MaintenanceFile] {
        try Task.checkCancellation()
        let root = home.appendingPathComponent("Library/Caches")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            throw MaintenanceError.unreadable
        }
        var result: [MaintenanceFile] = []
        for url in entries {
            try Task.checkCancellation()
            guard !isProtectedCache(url.lastPathComponent), safeAncestors(url, root: root) else { continue }
            if let file = try snapshot(url, kind: .cache, verified: false) { result.append(file) }
        }
        return result.sorted { $0.bytes > $1.bytes }
    }

    func removable(_ app: ManagedApplication) -> Bool {
        let protected = [protectedBundleID, "io.github.openisland.OpenIsland", "io.github.openisland", "com.apple.Safari", "com.apple.finder", "com.apple.systempreferences", "com.apple.dock", "com.apple.loginwindow"]
        return !protected.contains(app.bundleID) && appRoots.contains { safeAncestors(app.url, root: $0) }
            && app.url.pathExtension == "app" && FileManager.default.isWritableFile(atPath: app.url.deletingLastPathComponent().path)
    }

    /// Recheck identity and containment immediately before each move. No shell, permanent deletion,
    /// symlink following, system roots, shared group containers or privileged helper removal.
    @discardableResult
    func trash(_ file: MaintenanceFile, app: ManagedApplication?) throws -> URL? {
        try Task.checkCancellation()
        let library = home.appendingPathComponent("Library")
        if let app {
            guard removable(app), application(at: app.url)?.bundleID == app.bundleID else { throw MaintenanceError.changed }
            if file.isApplication {
                guard file.url.path == app.url.path else { throw MaintenanceError.changed }
            } else {
                let allowed = MaintenanceRules.locations(bundleID: app.bundleID, names: [app.name, app.bundleName, app.url.deletingPathExtension().lastPathComponent])
                    .contains { library.appendingPathComponent($0.relativePath).path == file.url.path }
                let byHost = library.appendingPathComponent("Preferences/ByHost")
                guard allowed || (file.url.deletingLastPathComponent().path == byHost.path && MaintenanceRules.isByHostPreference(file.url.lastPathComponent, bundleID: app.bundleID)),
                      safeAncestors(file.url, root: library) else { throw MaintenanceError.changed }
            }
        } else {
            let root = library.appendingPathComponent("Caches")
            guard file.url.deletingLastPathComponent().path == root.path, !isProtectedCache(file.url.lastPathComponent),
                  safeAncestors(file.url, root: root) else { throw MaintenanceError.changed }
        }
        let current = try identity(file.url)
        guard current.st_dev == file.device, current.st_ino == file.inode else { throw MaintenanceError.changed }
        var destination: NSURL?
        try FileManager.default.trashItem(at: file.url, resultingItemURL: &destination)
        return destination as URL?
    }

    private func application(at url: URL) -> ManagedApplication? {
        // Read metadata without loading executable code or opening a package's child apps.
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String, MaintenanceRules.validComponent(bundleID) else { return nil }
        let filename = url.deletingPathExtension().lastPathComponent
        let bundleName = info["CFBundleName"] as? String ?? filename
        return .init(url: url, bundleID: bundleID, name: info["CFBundleDisplayName"] as? String ?? bundleName,
                     version: info["CFBundleShortVersionString"] as? String ?? "—",
                     bundleName: bundleName)
    }

    private func identity(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) != S_IFLNK else { throw MaintenanceError.changed }
        return value
    }

    private func isProtectedCache(_ name: String) -> Bool {
        // Shelf file promises live here; unlike expendable caches, these can be the only copy.
        name == protectedBundleID || name == "io.github.openisland" || name == "io.github.openisland.OpenIsland"
    }

    private func safeAncestors(_ url: URL, root: URL) -> Bool {
        guard MaintenanceRules.isDescendant(url, of: root) else { return false }
        // Reject symlink ancestors too, including a redirected ~/Library/Caches root.
        // Foundation standardization rewrites /private/var to /var on macOS. Inspect the
        // supplied filesystem nodes, otherwise that rewrite introduces a symlink of its own.
        var node = url
        while node.path != "/" {
            var info = stat()
            if lstat(node.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { return false }
            node.deleteLastPathComponent()
        }
        return true
    }

    private func snapshot(_ url: URL, kind: MaintenanceRules.Kind?, verified: Bool, application: Bool = false) throws -> MaintenanceFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let node = try identity(url)
        var size: Int64 = 0, complete = true
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        func count(_ values: URLResourceValues?) {
            guard let values else { complete = false; return }
            if values.isSymbolicLink == true { return }
            if values.isRegularFile == true { size += Int64(values.fileSize ?? 0) }
        }
        count(try? url.resourceValues(forKeys: keys))
        if (node.st_mode & S_IFMT) == S_IFDIR {
            guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in complete = false; return true }) else {
                return .init(url: url, kind: kind, bytes: size, fullyMeasured: false, verifiedIdentity: verified,
                             isApplication: application, device: node.st_dev, inode: node.st_ino)
            }
            while let child = iterator.nextObject() as? URL {
                try Task.checkCancellation()
                let values = try? child.resourceValues(forKeys: keys)
                if values?.isSymbolicLink == true { iterator.skipDescendants(); continue }
                count(values)
            }
        }
        return .init(url: url, kind: kind, bytes: size, fullyMeasured: complete, verifiedIdentity: verified,
                     isApplication: application, device: node.st_dev, inode: node.st_ino)
    }
}

enum MaintenanceError: LocalizedError {
    case protectedApplication, unreadable, changed
    var errorDescription: String? {
        switch self {
        case .protectedApplication: "Bu uygulama korunuyor veya klasöre yazma izni yok."
        case .unreadable: "Klasör okunamadı. İzinleri ve dosyanın hâlâ mevcut olduğunu denetle."
        case .changed: "Dosya veya uygulama taramadan sonra değişti. Yeniden tara."
        }
    }
}
