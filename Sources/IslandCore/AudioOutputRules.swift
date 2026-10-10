/// Ses çıkış aygıtının bildirim için gereken özeti (Core Audio'dan okunur; burada yalnızca veri).
public struct AudioDeviceInfo: Sendable, Equatable {
    public var id: UInt32
    public var name: String
    public var kind: AudioOutputKind
    /// Bluetooth ile bağlanan kişisel aygıt (AirPods, Bluetooth kulaklık).
    public var isBluetooth: Bool
    public var isBluetoothLE: Bool

    public init(id: UInt32, name: String, kind: AudioOutputKind, isBluetooth: Bool, isBluetoothLE: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isBluetooth = isBluetooth
        self.isBluetoothLE = isBluetoothLE
    }
}

/// Ses aygıtı bildiriminin kuralı (saf, test edilir).
///
/// Yalnızca varsayılan çıkış değişimine bakmak yetmez: AirPods bağlandığında macOS çıkışı hemen değiştirmeyebilir
/// (veya hiç değiştirmez); bağlanma asıl olarak aygıt listesine yeni bir Bluetooth aygıtının eklenmesidir.
/// - Listeye Bluetooth aygıtı eklendi → "Bağlandı".
/// - Listeden Bluetooth aygıtı ya da o an çıkış olan harici aygıt çıktı → "Bağlantı kesildi".
/// - Varsayılan çıkış dahili olmayan bir aygıta geçti (HDMI, AirPlay, bağlı kulaklığa elle geçiş) → "Bağlandı".
/// Aynı bağlanma iki kez duyurulmaz (liste + varsayılan çıkış değişimi art arda gelir): kısa süre önce duyurulan
/// aygıt `recentlyAnnounced` içindedir. Ağda beliren AirPlay hoparlörleri, çıkış olarak seçilmedikçe duyurulmaz.
public enum AudioOutputRules {
    /// Bluetooth audio endpoints expose transport but not a public speaker/headphone category.
    /// Use explicit product-name hints for speakers; unknown devices retain the headphone icon.
    public static func bluetoothKind(named name: String) -> AudioOutputKind {
        // A user-editable name cannot establish a device model. CoreAudio has no reliable
        // AirPods product metadata; the Bluetooth monitor uses public device-class metadata.
        return .headphones
    }

    public static func notice(previous: [AudioDeviceInfo], current: [AudioDeviceInfo],
                              previousDefault: UInt32?, currentDefault: UInt32?,
                              recentlyAnnounced: Set<UInt32>) -> (device: AudioDeviceInfo, connected: Bool)? {
        let previousIDs = Set(previous.map(\.id))
        let currentIDs = Set(current.map(\.id))

        if let added = current.first(where: { $0.isBluetooth && !previousIDs.contains($0.id) && !recentlyAnnounced.contains($0.id) }) {
            return (added, true)
        }
        // Kaybolan Bluetooth aygıtı ya da o an çıkış olan harici aygıt (HDMI çıkarıldı, AirPlay koptu).
        if let removed = previous.first(where: { device in
            !currentIDs.contains(device.id)
                && (device.isBluetooth || (device.id == previousDefault && device.kind != .builtIn))
        }) {
            return (removed, false)
        }
        if let currentDefault, currentDefault != previousDefault,
           let device = current.first(where: { $0.id == currentDefault }),
           !device.isBluetooth, device.kind != .builtIn, !recentlyAnnounced.contains(device.id) {
            return (device, true)
        }
        return nil
    }
}
