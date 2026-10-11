import Foundation

/// Yalnızca açılış, kullanıcı yenilemesi veya mount/unmount olayında okunur; dizin taraması yok.
struct StorageVolume: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let total: Int64
    let available: Int64
    let isInternal: Bool
    var used: Int64 { total - available }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func read() -> [Self] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeIsLocalKey, .volumeIsInternalKey]
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        let candidates = [root] + mounted.filter { $0.path != "/" && !$0.path.hasPrefix("/System/Volumes/") }
        return candidates.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsLocal == true,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let stdAvail = values.volumeAvailableCapacity.map(Int64.init) ?? 0
            let impAvail = values.volumeAvailableCapacityForImportantUsage ?? 0
            let available = min(max(stdAvail, impAvail), Int64(total))
            guard available >= 0 else { return nil }
            return Self(id: url.path, name: values.volumeName ?? url.lastPathComponent,
                        total: Int64(total), available: available,
                        isInternal: values.volumeIsInternal ?? (url.path == "/"))
        }.sorted { lhs, rhs in
            if lhs.id == "/" { return rhs.id != "/" }
            if rhs.id == "/" { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
