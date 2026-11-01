import AppKit

/// Apple pano gizliliği. macOS 27.2'de geliştirici önizleme anahtarı kaldırıldı ve davranış varsayılan oldu: kullanıcı
/// "Her zaman izin ver" demedikçe başka uygulamanın kopyaladığı içeriği okumak sistem uyarısı açar ve okuma yanıt gelene
/// dek bekler. `changeCount` ve `types` uyarı açmaz. 27.2 öncesinde "Sor" durumu uygulanmaz, okuma sessizdir.
/// `accessBehavior` yalnız ana iş parçacığında okunur (başka iş parçacığında süreç sonlanır).
@MainActor
enum PasteAccess {
    enum Behavior: Sendable { case allowed, ask, denied }

    static func behavior(of pasteboard: NSPasteboard) -> Behavior {
        if let testOverride { return testOverride }
        guard #available(macOS 15.4, *) else { return .allowed }
        switch pasteboard.accessBehavior {
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        default: return isEnforced ? .ask : .allowed
        }
    }

    /// Okuma uyarı açmaz ve ana iş parçacığını bekletmez.
    static func canReadSilently(_ pasteboard: NSPasteboard = .general) -> Bool { behavior(of: pasteboard) == .allowed }

    private static let isEnforced = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0))

    /// Yalnız yalıtılmış geliştirici koşusu: 27.2 davranışını eski sistemde sınamak için (`ask` / `deny`).
    private static let testOverride: Behavior? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENISLAND_DIAGNOSTICS"] != nil, environment["OPENISLAND_TEST_ROOT"]?.hasPrefix("/") == true else { return nil }
        switch environment["OPENISLAND_TEST_PASTE_PRIVACY"] {
        case "ask": return .ask
        case "deny": return .denied
        default: return nil
        }
    }()
}
