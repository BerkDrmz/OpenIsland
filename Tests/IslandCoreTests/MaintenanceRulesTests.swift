import Foundation
import Testing
@testable import IslandCore

@Suite("Bakım araçları güvenlik ve sürüm kuralları")
struct MaintenanceRulesTests {
    @Test func identityDoesNotUseLoosePrefixes() {
        let locations = MaintenanceRules.locations(bundleID: "com.example.Editor", names: ["Editor", "Editor", "../Escape", "", "Shared/Editor"])
        #expect(locations.contains { $0.relativePath == "Preferences/com.example.Editor.plist" && $0.verifiedIdentity })
        #expect(!locations.contains { $0.relativePath.contains("EditorPro") || $0.relativePath.contains("Escape") })
        #expect(locations.filter { $0.relativePath == "Caches/Editor" }.count == 1)
        #expect(!locations.first { $0.relativePath == "Application Support/Editor" }!.verifiedIdentity)
        #expect(!locations.contains { $0.relativePath.hasPrefix("Group Containers/") || $0.relativePath.hasPrefix("LaunchAgents/") })
        #expect(MaintenanceRules.locations(bundleID: "../evil", names: ["Editor"]).isEmpty)
    }
    @Test func byHostRequiresAnExactBundleAndUUID() {
        let uuid = "12345678-1234-1234-1234-123456789ABC"
        #expect(MaintenanceRules.isByHostPreference("com.example.Editor.\(uuid).plist", bundleID: "com.example.Editor"))
        #expect(!MaintenanceRules.isByHostPreference("com.example.EditorPro.\(uuid).plist", bundleID: "com.example.Editor"))
        #expect(!MaintenanceRules.isByHostPreference("com.example.Editor.plugin.plist", bundleID: "com.example.Editor"))
    }
    @Test func ancestryUsesPathComponents() {
        let root = URL(fileURLWithPath: "/Users/test/Library/Caches")
        #expect(MaintenanceRules.isDescendant(root.appendingPathComponent("App"), of: root))
        #expect(!MaintenanceRules.isDescendant(root, of: root))
        #expect(!MaintenanceRules.isDescendant(URL(fileURLWithPath: "/Users/test/Library/CachesOther/App"), of: root))
        #expect(!MaintenanceRules.isDescendant(root.appendingPathComponent("../Documents"), of: root))
    }
    @Test func numericVersionsAndUnrecognizedFormats() {
        #expect(ReleaseVersion.compare("1.10", "1.9") == .orderedDescending)
        #expect(ReleaseVersion.compare("1.0.0", "1") == .orderedSame)
        #expect(ReleaseVersion.compare("27.0", "27.1") == .orderedAscending)
        #expect(ReleaseVersion.compare("12345", "12344") == .orderedDescending)
        #expect(ReleaseVersion.compare("1.2-beta", "1.1") == nil)
        #expect(ReleaseVersion.compare("1..2", "1") == nil)
        #expect(ReleaseVersion.compare("9999999999999999999999999999", "1") == nil)
    }
    @Test func appcastOnlyUsesSecureStableFullReleases() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <item><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><enclosure url="https://example.com/app.dmg" sparkle:version="110" sparkle:shortVersionString="1.10"/></item>
          <item><enclosure url="https://example.com/delta" sparkle:version="120" sparkle:deltaFrom="110"/></item>
          <item><sparkle:channel>beta</sparkle:channel><enclosure url="https://example.com/beta" sparkle:version="130"/></item>
          <item><enclosure url="http://example.com/insecure" sparkle:version="140"/></item>
          <item><enclosure url="https://example.com/windows" sparkle:os="windows" sparkle:version="150"/></item>
        </channel></rss>
        """
        let releases = MaintenanceAppcast.releases(from: Data(xml.utf8))
        #expect(releases.count == 1)
        #expect(releases.first?.version == "1.10" && releases.first?.build == "110")
        #expect(releases.first?.minimumOS == "14.0")
        #expect(MaintenanceAppcast.releases(from: Data("<broken>".utf8)).isEmpty)
        #expect(MaintenanceAppcast.releases(from: Data(repeating: 65, count: 2_000_001)).isEmpty)
    }
}
