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

/// Conservative comparison for release versions. Unknown formats are not reported as updates.
public enum ReleaseVersion {
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        func components(_ string: String) -> [Int]? {
            let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 8 else { return nil }
            var numbers: [Int] = []
            for part in parts {
                guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
                numbers.append(n)
            }
            return numbers
        }
        guard let a = components(lhs), let b = components(rhs) else { return nil }
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0, bv = i < b.count ? b[i] : 0
            if av != bv { return av < bv ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

public struct AppcastRelease: Sendable, Equatable {
    public let version: String
    public let build: String
    public let minimumOS: String?
    public let maximumOS: String?
    public let hardware: String?
    public let url: URL
}

/// The installer remains the app's own signed updater. This parser only discovers releases.
public final class MaintenanceAppcast: NSObject, XMLParserDelegate {
    private var items: [AppcastRelease] = []
    private var item = false, version = "", build = "", minimumOS: String?, maximumOS: String?, hardware: String?, link: URL?, channel = ""
    private var text = ""

    public static func releases(from data: Data) -> [AppcastRelease] {
        guard data.count <= 2_000_000 else { return [] }
        let delegate = MaintenanceAppcast(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        return parser.parse() ? delegate.items : []
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if name == "item" { item = true; version = ""; build = ""; minimumOS = nil; maximumOS = nil; hardware = nil; link = nil; channel = "" }
        if item, name == "enclosure", attributes["sparkle:deltaFrom"] == nil,
           attributes["sparkle:os"] == nil || attributes["sparkle:os"] == "macos" {
            version = attributes["sparkle:shortVersionString"] ?? version
            build = attributes["sparkle:version"] ?? build
            link = attributes["url"].flatMap(URL.init(string:))
        }
    }
    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard item else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "sparkle:shortVersionString" { version = value }
        if name == "sparkle:version" { build = value }
        if name == "sparkle:minimumSystemVersion" { minimumOS = value }
        if name == "sparkle:maximumSystemVersion" { maximumOS = value }
        if name == "sparkle:hardwareRequirements" { hardware = value }
        if name == "sparkle:channel" { channel = value }
        if name == "item" {
            if let link, link.scheme == "https", channel.isEmpty,
               ReleaseVersion.compare(version.isEmpty ? build : version, "0") != nil {
                items.append(.init(version: version.isEmpty ? build : version, build: build, minimumOS: minimumOS, maximumOS: maximumOS, hardware: hardware, url: link))
            }
            item = false
        }
    }
}
