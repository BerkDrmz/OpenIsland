import Foundation

/// Kırılgan bir arka ucun (AppleScript, private framework, alt süreç) sağlık durumu.
///
/// Arka uç tekrar tekrar başarısız olursa uygulama aynı çağrıyı sürekli denemez: sınırlı ve üstel
/// geri çekilme uygulanır, kalıcı hatada arka uç "desteklenmiyor" olur. Hiçbir zamanlayıcı kurulmaz;
/// yalnızca bir sonraki doğal olayda (ör. yeni parça bildirimi) `allows(at:)` sorulur.
public struct BackendHealth: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case healthy
        case temporarilyUnavailable(until: Date)
        case unsupported
    }

    public private(set) var state: State = .healthy
    public private(set) var consecutiveFailures = 0

    /// İlk geri çekilme ve üst sınır.
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(baseDelay: TimeInterval = 30, maxDelay: TimeInterval = 30 * 60) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public func allows(at date: Date = Date()) -> Bool {
        switch state {
        case .healthy: true
        case .temporarilyUnavailable(let until): date >= until
        case .unsupported: false
        }
    }

    public mutating func recordSuccess() {
        state = .healthy
        consecutiveFailures = 0
    }

    /// - Parameters:
    ///   - permanent: Sürüm/sembol düzeyinde kalıcı hata (ör. arka uç bu macOS'ta yok).
    ///   - minimumDelay: Örn. izin reddinde kullanıcıya zaman tanımak için daha uzun bekleme.
    public mutating func recordFailure(permanent: Bool = false, minimumDelay: TimeInterval = 0, at date: Date = Date()) {
        consecutiveFailures += 1
        guard !permanent else {
            state = .unsupported
            return
        }
        let exponential = baseDelay * pow(2, Double(consecutiveFailures - 1))
        state = .temporarilyUnavailable(until: date.addingTimeInterval(min(max(exponential, minimumDelay), maxDelay)))
    }

    /// Uyanma veya kullanıcı eylemi (ör. izin verildi) sonrası yeni bir hak.
    public mutating func reset() {
        if state != .unsupported { recordSuccess() }
    }
}
