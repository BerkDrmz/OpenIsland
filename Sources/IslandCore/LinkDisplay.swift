import Foundation

/// Pano satırında bağlantının görünen biçimi: "https://" ve "www." atılır, sondaki tek "/" kaldırılır; böylece dar satırda
/// alan adı ve yol görünür. Yalnız gösterim içindir; kopyalanan ve erişilebilirlikte okunan metin özgün bağlantıdır.
public enum LinkDisplay {
    /// Tek parça HTTP(S) bağlantısı için kısa biçim; bağlantı değilse nil.
    public static func compact(_ text: String) -> String? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.utf8.count <= 4096, !input.contains(where: \.isWhitespace) else { return nil }
        var rest: Substring
        if let range = input.range(of: "https://", options: [.anchored, .caseInsensitive]) {
            rest = input[range.upperBound...]
        } else if let range = input.range(of: "http://", options: [.anchored, .caseInsensitive]) {
            rest = input[range.upperBound...]
        } else { return nil }
        // Kullanıcı adı/parola içeren bağlantılar olduğu gibi kalır (kısaltma bunu gizlememeli).
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.isEmpty, !authority.contains("@") else { return nil }
        if let range = rest.range(of: "www.", options: [.anchored, .caseInsensitive]), rest[range.upperBound...].contains(".") {
            rest = rest[range.upperBound...]
        }
        if rest.hasSuffix("/") { rest = rest.dropLast() }
        return rest.isEmpty ? nil : String(rest)
    }
}
