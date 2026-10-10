/// Çıkış aygıtının anlık ses durumu.
public struct VolumeReading: Sendable, Equatable {
    /// 0...1.
    public var level: Double
    /// Sessize alınmış ya da seviye 0.
    public var muted: Bool

    public init(level: Double, muted: Bool) {
        self.level = level
        self.muted = muted || level <= 0
    }
}

/// Core Audio'dan gelen bir ses değişiminin adada HUD olarak gösterilip gösterilmeyeceği (saf, test edilir).
///
/// Ölçüm (AirPods Pro, Kişiselleştirilmiş Ses açık): kulaklık sesi kendiliğinden %1–2'lik adımlarla, ~0,6–1,5 sn'de
/// bir ayarlanıyor. Her değişimde HUD açılınca ada durmadan büyüyüp çentiğe geri dönüyordu. Kullanıcı eylemi ise
/// belirgin bir adımdır: ses tuşu 1/16 (Bluetooth'ta 8/127 ≈ 0,063), sessize alma bir durum değişimidir.
/// Karşılaştırma bir önceki **okumayla** yapılır (son gösterilenle değil): otomatik kaymalar birikerek eşiği aşmaz.
/// Erişilebilirlik izni varsa tuşlar bu kurala takılmadan event tap üzerinden gösterilir (Option+Shift ile 1/64 dahil).
public enum VolumeChangeRules {
    /// Ses tuşunun en küçük adımının (1/16) belirgin biçimde altında, otomatik ayarın (≤ 0,02) belirgin biçimde üstünde.
    public static let minimumVisibleStep = 0.04

    public static func isUserVisible(from previous: VolumeReading?, to current: VolumeReading) -> Bool {
        guard let previous else { return false } // aygıta bağlandıktan sonraki ilk okuma bir eylem değildir
        if previous.muted != current.muted { return true }
        if current.muted { return false } // sessizken seviyenin kayması görünmez
        let delta = abs(current.level - previous.level)
        if delta >= minimumVisibleStep { return true }
        // Tuş en üstte kısa bir adım atabilir (0,98 → 1): uca varış da gösterilir.
        return current.level >= 0.999 && delta > 0.001
    }
}
