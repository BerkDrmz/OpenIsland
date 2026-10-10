/// Sistemin ısı durumu. `ProcessInfo.ThermalState` ile aynı sıradadır; IslandCore Foundation türüne bağlanmaz.
public enum ThermalLevel: Int, Sendable, Comparable {
    case nominal, fair, serious, critical

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Pil tasarrufu kuralı (saf, testli). Müzik nabzı render sunucusunda çizim işi oluşturur;
/// WindowServer'ın toplam yükünden uygulamaya özel GPU yüzdesi çıkarılamaz. Tasarrufta nabız
/// sakin forma sabitlenir ve hareket kısalır; kayıtlı Hareket ayarı değişmez.
public enum EnergyRules {
    /// Kullanıcı Düşük Güç Modu'nu açtığında veya Mac ısındığında (ciddi/kritik) tasarruf yapılır. Yalnızca
    /// prizden çekmek tasarrufu başlatmaz: pilde de ada her zamanki gibi davranır.
    public static func savesEnergy(isEnabled: Bool, lowPowerMode: Bool, thermal: ThermalLevel) -> Bool {
        isEnabled && (lowPowerMode || thermal >= .serious)
    }
}
