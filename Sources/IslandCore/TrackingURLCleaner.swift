import Foundation

/// Explicit, offline cleanup. Does not expand redirects, fetch URLs, or run a monitor.
public enum TrackingURLCleaner {
    private static let trackingNames: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "utm_source_platform", "utm_creative_format", "utm_marketing_tactic",
        "fbclid", "gclid", "dclid", "msclkid", "ttclid", "twclid", "igshid",
        "mc_cid", "mc_eid",
    ]
    // A signature can cover the entire query, including a tracking parameter.
    // Leave known signed links untouched rather than silently breaking access.
    private static let signatureNames: Set<String> = [
        "sig", "signature", "oauth_signature", "x-amz-signature", "x-goog-signature",
        "x-amz-credential", "x-goog-credential", "policy",
    ]

    /// Returns a changed HTTP(S) link, or nil when unsupported/already clean.
    /// Encoded values, duplicate functional parameters, order and fragment survive.
    public static func clean(_ text: String) -> String? {
        guard text.utf8.count <= 65_536 else { return nil }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: input, encodingInvalidCharacters: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let items = components.percentEncodedQueryItems, !items.isEmpty else { return nil }
        let names = items.map { ($0.name.removingPercentEncoding ?? $0.name).lowercased() }
        guard !names.contains(where: signatureNames.contains) else { return nil }
        let kept = zip(items, names).compactMap { item, name in
            trackingNames.contains(name) ? nil : item
        }
        guard kept.count != items.count else { return nil }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.string
    }
}
