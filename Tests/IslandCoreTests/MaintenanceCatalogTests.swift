import Foundation
import Testing
@testable import IslandCore

@Suite("Ek güncelleme kataloğu doğrulaması")
struct MaintenanceCatalogTests {
    private let catalog = """
    {"token":"editor","version":"2.4,abc123","homepage":"https://example.com/download",
     "disabled":false,"deprecated":false,"depends_on":{"macos":{">=":["13"]}},
     "artifacts":[{"uninstall":[{"quit":["com.fixture.Editor","com.fixture.Editor.helper"]}]}],
     "variations":{"arm64_sonoma":{"version":"2.3,def"},"sonoma":{"version":"2.2"}}}
    """
    private func release(_ json: String, id: String = "com.fixture.Editor", os: String = "27.0", arch: String = "arm64") -> MaintenanceCatalog.Release? {
        MaintenanceCatalog.caskRelease(from: Data(json.utf8), token: "editor", bundleID: id, osVersion: os, architecture: arch)
    }

    @Test func knownTokensRespectExactIdentityAndUnknownNamesAreOnlyCandidates() {
        #expect(MaintenanceCatalog.token(bundleID: "com.google.Chrome", filename: "Renamed") == "google-chrome")
        #expect(MaintenanceCatalog.token(bundleID: "com.google.Chrome.beta", filename: "Google Chrome Beta") == "google-chrome-beta")
        #expect(MaintenanceCatalog.token(bundleID: "com.openai.codex", filename: "ChatGPT") == "codex-app")
        #expect(MaintenanceCatalog.token(bundleID: "com.fixture.Editor", filename: "An Editor") == "an-editor")
        #expect(MaintenanceCatalog.token(bundleID: "com.fixture.Editor", filename: "../Escape") == nil)
        #expect(MaintenanceCatalog.token(bundleID: "io.github.openisland.OpenIsland", filename: "OpenIsland") == nil)
        #expect(MaintenanceCatalog.token(bundleID: "com.apple.finder", filename: "Finder") == nil)
    }

    @Test func catalogRequiresExactBundleIdentityNotNamesOrLoosePrefixes() {
        #expect(release(catalog)?.version == "2.4")
        #expect(release(catalog)?.destination.absoluteString == "https://example.com/download")
        #expect(release(catalog, id: "com.fixture.EditorPro") == nil)
        #expect(release(catalog.replacingOccurrences(of: "\"quit\":[\"com.fixture.Editor\",\"com.fixture.Editor.helper\"]", with: "\"quit\":\"com.fixture.Editor.helper\"")) == nil)
        let preference = catalog.replacingOccurrences(of: "\"uninstall\":[{\"quit\":[\"com.fixture.Editor\",\"com.fixture.Editor.helper\"]}]", with: "\"zap\":[{\"trash\":\"~/Library/Preferences/com.fixture.Editor.plist\"}]")
        #expect(release(preference) != nil)
        #expect(release(preference, id: "com.fixture.EditorPro") == nil)
        #expect(release(catalog.replacingOccurrences(of: "\"token\":\"editor\"", with: "\"token\":\"editor-beta\"")) == nil)
    }

    @Test func versionCompatibilityAndUnmaintainedCatalogEntriesAreConservative() {
        #expect(release(catalog, os: "14.5")?.version == "2.3")
        #expect(release(catalog, os: "14.5", arch: "x86_64")?.version == "2.2")
        #expect(release(catalog, os: "12.7") == nil)
        #expect(release(catalog.replacingOccurrences(of: "\"deprecated\":false", with: "\"deprecated\":true")) == nil)
        #expect(release(catalog.replacingOccurrences(of: "\"disabled\":false", with: "\"disabled\":true")) == nil)
        #expect(release(catalog.replacingOccurrences(of: "2.4,abc123", with: "latest")) == nil)
        #expect(release(catalog.replacingOccurrences(of: "2.4,abc123", with: "2.4-beta,abc123")) == nil)
        #expect(release(catalog.replacingOccurrences(of: "https://example.com", with: "http://example.com")) == nil)
        let armOnly = catalog.replacingOccurrences(of: "\"macos\":", with: "\"arch\":[{\"type\":\"arm64\"}],\"macos\":")
        #expect(release(armOnly) != nil)
        #expect(release(armOnly, arch: "x86_64") == nil)
        #expect(release("<broken>") == nil)
    }

    @Test func macStoreAlsoRecognizesUnifiedMacProductsButRejectsIOSOnlyAndNamesakes() {
        let unified = """
        {"results":[{"bundleId":"net.whatsapp.WhatsApp","version":"26.39.75","kind":"software",
        "trackId":310633997,"supportedDevices":["MacDesktop-MacDesktop","iPhone17-iPhone17"]}]}
        """
        #expect(MaintenanceCatalog.storeRelease(from: Data(unified.utf8), bundleID: "net.whatsapp.WhatsApp")?.version == "26.39.75")
        #expect(MaintenanceCatalog.storeRelease(from: Data(unified.utf8), bundleID: "net.whatsapp.Other") == nil)
        #expect(MaintenanceCatalog.storeRelease(from: Data(unified.replacingOccurrences(of: "MacDesktop-MacDesktop", with: "iPad13-iPad13").utf8), bundleID: "net.whatsapp.WhatsApp") == nil)
        let mac = """
        {"results":[{"bundleId":"com.fixture.Editor","version":"2.0","kind":"mac-software","trackId":123}]}
        """
        #expect(MaintenanceCatalog.storeRelease(from: Data(mac.utf8), bundleID: "com.fixture.Editor")?.destination.absoluteString.contains("id123") == true)
    }
}
