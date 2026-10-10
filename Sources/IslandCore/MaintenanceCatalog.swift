import Foundation

/// Read-only release discovery. Catalog uninstall instructions are never executed.
public enum MaintenanceCatalog {
    public struct Release: Sendable, Equatable {
        public let version: String
        public let destination: URL
    }

    public static func token(bundleID: String, filename: String) -> String? {
        guard MaintenanceRules.validComponent(bundleID), bundleID.contains("."),
              !["io.github.openisland", "io.github.openisland.OpenIsland"].contains(bundleID),
              !bundleID.hasPrefix("com.apple.") else { return nil }
        let known = [
            "com.google.Chrome": "google-chrome", "com.spotify.client": "spotify",
            "com.hnc.Discord": "discord", "com.anthropic.claudefordesktop": "claude",
            "com.microsoft.VSCode": "visual-studio-code", "com.google.antigravity": "antigravity",
            "com.openai.chat": "chatgpt", "com.openai.codex": "codex-app",
            "com.brave.Browser": "brave-browser", "com.microsoft.edgemac": "microsoft-edge",
            "org.mozilla.firefox": "firefox", "net.whatsapp.WhatsApp": "whatsapp",
        ]
        if let token = known[bundleID] { return token }
        // A filename only proposes a small catalog lookup. The response must independently
        // identify the installed bundle, so a namesake or a beta cannot match the stable app.
        let name = filename.lowercased()
        guard name.count <= 100, name.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789 -").contains($0)
        }) else { return nil }
        let token = name.split(whereSeparator: { $0 == " " || $0 == "-" }).joined(separator: "-")
        return token.isEmpty ? nil : token
    }

    public static func caskRelease(from data: Data, token: String, bundleID: String,
                                   osVersion: String, architecture: String) -> Release? {
        guard data.count <= 2_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["token"] as? String == token,
              root["disabled"] as? Bool != true, root["deprecated"] as? Bool != true,
              identifies(root, bundleID: bundleID),
              let homepage = (root["homepage"] as? String).flatMap(URL.init(string:)),
              homepage.scheme == "https", homepage.host != nil else { return nil }
        let dependencies = root["depends_on"] as? [String: Any] ?? [:]
        if let macOS = dependencies["macos"] as? [String: [String]] {
            // Unknown constraints are not assumed compatible.
            for (relation, versions) in macOS where !versions.isEmpty {
                guard versions.contains(where: { version in
                    guard let comparison = ReleaseVersion.compare(osVersion, version) else { return false }
                    switch relation {
                    case ">=": return comparison != .orderedAscending
                    case "<=": return comparison != .orderedDescending
                    case ">": return comparison == .orderedDescending
                    case "<": return comparison == .orderedAscending
                    case "==": return comparison == .orderedSame || osVersion.hasPrefix(version + ".")
                    default: return false
                    }
                }) else { return nil }
            }
        }
        if let requirements = dependencies["arch"] as? [[String: Any]], !requirements.isEmpty {
            guard requirements.contains(where: { $0["type"] as? String == architecture }) else { return nil }
        }
        var version = root["version"] as? String
        let major = osVersion.split(separator: ".").first.flatMap { Int($0) }
        let systemName = [27: "golden_gate", 26: "tahoe", 15: "sequoia", 14: "sonoma",
                          13: "ventura", 12: "monterey", 11: "big_sur"][major ?? 0]
        if let systemName, let variations = root["variations"] as? [String: [String: Any]] {
            let variant = variations[architecture + "_" + systemName] ?? variations[systemName]
            if let variant, variant.keys.contains("version") { version = variant["version"] as? String }
        }
        // Homebrew's comma suffix is a build/hash, not part of the public release version.
        guard let version = version?.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init),
              ReleaseVersion.compare(version, "0") != nil else { return nil }
        return Release(version: version, destination: homepage)
    }

    private static func identifies(_ root: [String: Any], bundleID: String) -> Bool {
        for artifact in root["artifacts"] as? [[String: Any]] ?? [] {
            for command in artifact["uninstall"] as? [[String: Any]] ?? [] {
                if strings(command["quit"]).contains(bundleID) { return true }
            }
            for command in artifact["zap"] as? [[String: Any]] ?? [] {
                if strings(command["trash"]).contains("~/Library/Preferences/" + bundleID + ".plist") { return true }
            }
        }
        return false
    }
    private static func strings(_ value: Any?) -> [String] {
        if let value = value as? String { return [value] }
        return value as? [String] ?? []
    }

    public static func storeRelease(from data: Data, bundleID: String) -> Release? {
        struct Catalog: Decodable { let results: [Application] }
        struct Application: Decodable {
            let bundleId: String, version: String, kind: String
            let trackId: Int?
            let supportedDevices: [String]?
        }
        guard data.count <= 2_000_000,
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              let app = catalog.results.first(where: {
                  $0.bundleId == bundleID && ($0.kind == "mac-software" ||
                    ($0.kind == "software" && ($0.supportedDevices?.contains("MacDesktop-MacDesktop") == true)))
              }), ReleaseVersion.compare(app.version, "0") != nil else { return nil }
        let destination = app.trackId.flatMap { URL(string: "macappstore://itunes.apple.com/app/id\($0)?mt=12") }
            ?? URL(string: "macappstore://showUpdatesPage")!
        return Release(version: app.version, destination: destination)
    }
}
