import Foundation
import Testing
@testable import IslandCore

@Suite("Bakım araçları güvenlik kuralları")
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
}
