/// Güç kaynağının anlık durumu (IOKit `IOPowerSources` sözlüğünden).
public struct PowerSnapshot: Sendable, Equatable {
    public var level: Double
    public var isOnAC: Bool
    public var isCharging: Bool
    public var isCharged: Bool

    public init(level: Double, isOnAC: Bool, isCharging: Bool, isCharged: Bool) {
        self.level = level
        self.isOnAC = isOnAC
        self.isCharging = isCharging
        self.isCharged = isCharged
    }
}

extension PowerEvent.Kind {
    /// Hangi değişim kullanıcıya gösterilmeye değer? Olaylar yalnızca **geçişlerde** üretilir:
    /// adaptör bağlandı/kesildi, pilde %20 ve %10 eşiklerinin aşağı doğru geçilmesi, %100'e ulaşma.
    /// Yüzdenin her değişiminde veya eşiğin altında kalmaya devam ederken tekrar bildirim yoktur.
    public static func transition(from old: PowerSnapshot, to new: PowerSnapshot) -> PowerEvent.Kind? {
        if new.isOnAC != old.isOnAC { return new.isOnAC ? .pluggedIn : .unplugged }
        if new.isOnAC {
            let reachedFull = (new.isCharged && !old.isCharged) || (old.level < 1 && new.level >= 1)
            if reachedFull { return .full }
            if old.isCharging != new.isCharging { return new.isCharging ? .chargingStarted : .chargingStopped }
            return nil
        }
        if old.level > 0.10, new.level <= 0.10 { return .critical }
        if old.level > 0.20, new.level <= 0.20 { return .low }
        return nil
    }
}
