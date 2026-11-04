import Foundation
import Testing
@testable import IslandCore

@Suite("Pano bağlantısının kısa gösterimi")
struct LinkDisplayTests {
    @Test func dropsSchemeWwwAndTrailingSlash() {
        #expect(LinkDisplay.compact("https://github.com/BerkDrmz/OpenIsland") == "github.com/BerkDrmz/OpenIsland")
        #expect(LinkDisplay.compact("  HTTP://www.Example.com/ \n") == "Example.com")
        #expect(LinkDisplay.compact("https://example.com/a?q=1#x") == "example.com/a?q=1#x")
        #expect(LinkDisplay.compact("https://www.com") == "www.com")
    }

    @Test func leavesNonLinksAndCredentialsAlone() {
        #expect(LinkDisplay.compact("Merhaba dünya") == nil)
        #expect(LinkDisplay.compact("#F5A623") == nil)
        #expect(LinkDisplay.compact("ftp://example.com") == nil)
        #expect(LinkDisplay.compact("bak: https://example.com") == nil)
        #expect(LinkDisplay.compact("https://user:pass@example.com/") == nil)
        #expect(LinkDisplay.compact("https://") == nil)
    }
}
