import Foundation

/// Exact identities only: e.g. com.example.Editor never owns com.example.EditorPro.
public enum MaintenanceRules {
    public enum Kind: String, Sendable, CaseIterable { case cache, preferences, logs, savedState, data }
    public struct Location: Sendable, Equatable {
        public let relativePath: String
        public let kind: Kind
        /// Name-based matches can be shared. They require explicit selection.
        public let verifiedIdentity: Bool
        public init(_ path: String, _ kind: Kind, verifiedIdentity: Bool = true) {
            relativePath = path; self.kind = kind; self.verifiedIdentity = verifiedIdentity
        }
    }

    public static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    public static func locations(bundleID: String, names: [String]) -> [Location] {
        guard validComponent(bundleID), bundleID.contains(".") else { return [] }
        var result: [Location] = [
            .init("Caches/\(bundleID)", .cache), .init("HTTPStorages/\(bundleID)", .cache),
            .init("WebKit/\(bundleID)", .cache), .init("Preferences/\(bundleID).plist", .preferences),
            .init("Logs/\(bundleID)", .logs), .init("Saved Application State/\(bundleID).savedState", .savedState),
            .init("Application Support/\(bundleID)", .data), .init("Containers/\(bundleID)", .data),
            .init("Application Scripts/\(bundleID)", .data),
        ]
        for name in Set(names).sorted() where validComponent(name) && name != bundleID {
            result += [.init("Caches/\(name)", .cache, verifiedIdentity: false),
                       .init("Logs/\(name)", .logs, verifiedIdentity: false),
                       .init("Application Support/\(name)", .data, verifiedIdentity: false)]
        }
        if bundleID == "com.google.Chrome" {
            result += [.init("Caches/Google/Chrome", .cache), .init("Application Support/Google/Chrome", .data)]
        }
        return result
    }

    public static func isByHostPreference(_ filename: String, bundleID: String) -> Bool {
        guard validComponent(bundleID), filename.hasPrefix(bundleID + "."), filename.hasSuffix(".plist") else { return false }
        let suffix = filename.dropFirst(bundleID.count + 1).dropLast(6)
        return UUID(uuidString: String(suffix)) != nil
    }

    public static func isDescendant(_ path: URL, of root: URL) -> Bool {
        let child = path.standardizedFileURL.pathComponents
        let parent = root.standardizedFileURL.pathComponents
        return child.count > parent.count && Array(child.prefix(parent.count)) == parent
    }
}
