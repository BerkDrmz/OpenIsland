import Foundation

/// CPU zaman sayaçları (`host_statistics` HOST_CPU_LOAD_INFO). Kullanım, iki okuma arasındaki farktan hesaplanır.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }

    /// 0...1 kullanım; fark yoksa (aynı okuma) ya da sayaç geriye gittiyse `nil`.
    public static func usage(from previous: CPUTicks, to current: CPUTicks) -> Double? {
        guard current.user >= previous.user, current.system >= previous.system,
              current.idle >= previous.idle, current.nice >= previous.nice else { return nil }
        let busy = (current.user - previous.user) + (current.system - previous.system) + (current.nice - previous.nice)
        let total = busy + (current.idle - previous.idle)
        guard total > 0 else { return nil }
        return min(max(Double(busy) / Double(total), 0), 1)
    }
}

/// Bellek özeti (Etkinlik Monitörü ile aynı tanım): kullanılan = uygulama belleği + kablolu + sıkıştırılmış.
public struct MemoryBreakdown: Sendable, Equatable {
    public var totalBytes: UInt64
    public var usedBytes: UInt64
    public var compressedBytes: UInt64
    /// Önbellekteki dosyalar (dosya destekli + boşaltılabilir sayfalar).
    public var cachedBytes: UInt64
    public var swapUsedBytes: UInt64

    public init(totalBytes: UInt64, usedBytes: UInt64, compressedBytes: UInt64, cachedBytes: UInt64, swapUsedBytes: UInt64) {
        self.totalBytes = totalBytes; self.usedBytes = usedBytes; self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes; self.swapUsedBytes = swapUsedBytes
    }

    public var usedFraction: Double {
        totalBytes > 0 ? min(Double(usedBytes) / Double(totalBytes), 1) : 0
    }
}

public enum MemoryRules {
    /// Sayfa sayıları `vm_statistics64`'ten gelir. `internal` ≥ `purgeable` değilse sıfıra kenetlenir.
    public static func breakdown(pageSize: UInt64, total: UInt64, internalPages: UInt64, purgeablePages: UInt64,
                                 wiredPages: UInt64, compressorPages: UInt64, externalPages: UInt64,
                                 swapUsed: UInt64) -> MemoryBreakdown {
        let app = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        let used = min((app + wiredPages + compressorPages) * pageSize, total)
        return MemoryBreakdown(totalBytes: total, usedBytes: used, compressedBytes: compressorPages * pageSize,
                               cachedBytes: (externalPages + purgeablePages) * pageSize, swapUsedBytes: swapUsed)
    }

    public enum Pressure: Sendable, Equatable {
        case normal, warning, critical
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 uyarı, 4 kritik; bilinmeyen değer normal sayılır.
    public static func pressure(level: Int) -> Pressure {
        switch level {
        case 2: .warning
        case 4: .critical
        default: .normal
        }
    }
}

/// Apple Silicon sıcaklık sensörlerinin özeti. Sensör adları sürümler arasında değişebilir; eşleşme yoksa `nil`
/// döner ve arayüz o değeri göstermez.
public enum TemperatureRules {
    /// Geçerli sayılan aralık: kalibrasyon sensörleri (−22 °C) ve okunamayan değerler dışarıda kalır.
    public static let validRange = 10.0...120.0

    public struct Summary: Sendable, Equatable {
        public var cpu: Double?
        public var gpu: Double?
        public init(cpu: Double?, gpu: Double?) { self.cpu = cpu; self.gpu = gpu }
    }

    /// Her grubun son okumadaki en yüksek geçerli sensör değeri; ortalama, geçmiş tepe veya
    /// enterpolasyon değil. CPU için "PMU tdie*", GPU için "PMU2 tdie*" kullanılır.
    /// Bu eşleştirme belgelenmemiştir; çekirdek sayısını veya kalibrasyonu doğrulamaz.
    /// Eşleşen geçerli okuma yoksa `nil` döner.
    public static func summarize(_ readings: [(name: String, celsius: Double)]) -> Summary {
        func highest(prefix: String) -> Double? {
            readings.lazy.filter { $0.name.hasPrefix(prefix) && validRange.contains($0.celsius) }
                .map(\.celsius).max()
        }
        return Summary(cpu: highest(prefix: "PMU tdie"), gpu: highest(prefix: "PMU2 tdie"))
    }
}

/// macOS güncellemesi sonrası private API korumasının kararı (saf, testli).
///
/// Private çağrılar bir sürümde süreci çökertirse (nadir ama mümkün), sonraki açılışta aynı çağrıyı aynı yapıda
/// tekrar etmemek gerekir; yoksa uygulama her açılışta çöker. Çağrı denemesinden önce `pending` olarak yapı
/// numarası saklanır, deneme başarılı olunca silinir. Açılışta `pending` hâlâ duruyorsa deneme çökmüştür ve o yapı
/// için özellik kapatılır; yapı numarası değişince (yeni güncelleme) yeniden denenir.
public enum PrivateAPIGuardRules {
    public struct State: Equatable, Sendable {
        public var pendingBuild: String?
        public var blockedBuild: String?
        public init(pendingBuild: String?, blockedBuild: String?) { self.pendingBuild = pendingBuild; self.blockedBuild = blockedBuild }
    }

    /// Açılışta durumu çöken denemeye göre günceller.
    public static func launch(_ state: State, currentBuild: String) -> State {
        var next = state
        if let pending = state.pendingBuild {
            next.blockedBuild = pending
            next.pendingBuild = nil
        }
        // Bloklanan yapıdan farklı bir sürümdeysek engel kalkar.
        if let blocked = next.blockedBuild, blocked != currentBuild { next.blockedBuild = nil }
        return next
    }

    public static func isAllowed(_ state: State, currentBuild: String) -> Bool {
        state.blockedBuild != currentBuild
    }
}
