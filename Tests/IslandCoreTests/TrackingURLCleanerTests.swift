import Foundation
import Testing
@testable import IslandCore

@Suite("İsteğe bağlı, çevrimdışı bağlantı temizleme")
struct TrackingURLCleanerTests {
    @Test func removesOnlyExplicitTrackingNames() {
        #expect(TrackingURLCleaner.clean("https://example.com/p?utm_source=mail&fbclid=123&id=42&ref=checkout&si=share&not_utm_source=keep&utm_custom=keep") ==
                "https://example.com/p?id=42&ref=checkout&si=share&not_utm_source=keep&utm_custom=keep")
        #expect(TrackingURLCleaner.clean("https://example.com/?UTM_MEDIUM=x&%66bclid=y&gclid=z") == "https://example.com/")
    }

    @Test func preservesEncodingDuplicatesFlagsFragmentAndHost() {
        #expect(TrackingURLCleaner.clean("https://EXAMPLE.com/p%2f?q=a%2fb+c&%75tm_source=x&flag&empty=&x=1&x=2#f%2f") ==
                "https://EXAMPLE.com/p%2f?q=a%2fb+c&flag&empty=&x=1&x=2#f%2f")
        #expect(TrackingURLCleaner.clean("https://example.com/?utm_source=x&next=https%3A%2F%2Fother.test%2F%3Futm_source%3Dkeep") ==
                "https://example.com/?next=https%3A%2F%2Fother.test%2F%3Futm_source%3Dkeep")
        #expect(TrackingURLCleaner.clean(" https://example.com/?utm_source=x#utm_source=keep\n") == "https://example.com/#utm_source=keep")
    }

    @Test func leavesSignedCredentialsAndNonLinksUntouched() {
        for name in ["sig", "Signature", "X-Amz-Signature", "X-Goog-Credential", "oauth_signature", "%73ig"] {
            #expect(TrackingURLCleaner.clean("https://example.com/?utm_source=x&\(name)=signed") == nil)
        }
        for value in ["hello", "file:///tmp/a?utm_source=x", "javascript:alert(1)",
                      "https:///no-host?utm_source=x", "https://u:p@example.com/?utm_source=x",
                      "https://example.com/a b?utm_source=x", "https://example.com/?x=%ZZ&utm_source=y",
                      "https://example.com/?id=42", "https://example.com/#utm_source=x"] {
            #expect(TrackingURLCleaner.clean(value) == nil)
        }
    }

    @Test func repeatedCleanupIsANoOpAndOversizedInputIsRejected() {
        let original = "https://example.com/?utm_campaign=one&utm_campaign=two&x=%2b"
        let clean = TrackingURLCleaner.clean(original)
        #expect(clean == "https://example.com/?x=%2b")
        #expect(TrackingURLCleaner.clean(clean!) == nil)
        #expect(TrackingURLCleaner.clean("https://example.com/?utm_source=" + String(repeating: "x", count: 65_536)) == nil)
    }
}
