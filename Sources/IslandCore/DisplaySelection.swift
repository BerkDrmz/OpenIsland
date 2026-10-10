/// Adanın gösterileceği ekranlar.
public enum DisplayTarget: String, Sendable, CaseIterable, Identifiable {
    /// Yalnızca MacBook'un kendi ekranı (çentikli olan, yoksa dahili ekran). Harici monitörde ada **hiç**
    /// görünmez; kapak kapalıyken (yalnızca harici monitör) ada yoktur. Ham değer eski ayarlarla uyum içindir.
    case primary
    /// Bağlı tüm ekranlar: çentikli ekranda notch, diğerlerinde yüzen kapsül. Kullanıcı bilerek seçer.
    case allDisplays

    public var id: String { rawValue }
}

/// Seçim için ekranın gereken özeti.
public struct DisplayCandidate: Sendable, Equatable {
    public var id: UInt32
    public var isBuiltIn: Bool
    public var hasNotch: Bool

    public init(id: UInt32, isBuiltIn: Bool, hasNotch: Bool) {
        self.id = id
        self.isBuiltIn = isBuiltIn
        self.hasNotch = hasNotch
    }
}

/// Hangi ekranlarda ada olacağı (saf, test edilir).
public enum DisplaySelection {
    public static func targets(_ target: DisplayTarget, among screens: [DisplayCandidate]) -> [UInt32] {
        switch target {
        case .allDisplays:
            return screens.map(\.id)
        case .primary:
            // Harici monitöre asla düşülmez (eskiden kapak kapalıyken ana ekrana, yani harici monitöre düşülüyordu).
            if let notched = screens.first(where: { $0.isBuiltIn && $0.hasNotch }) { return [notched.id] }
            if let builtIn = screens.first(where: \.isBuiltIn) { return [builtIn.id] }
            return []
        }
    }
}
