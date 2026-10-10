/// Ses gibi bir sistem seviyesine erişim (bugün yalnızca public Core Audio arka ucu kullanılır).
///
/// Çağrı başarısız olursa ya da beklenmeyen bir değer dönerse ayar yapılmaz; art arda hatada kontrol devre dışı
/// kalır (`ManagedLevelControl`).
public struct LevelControlBackend {
    public var read: () -> Float?
    public var write: (Float) -> Bool

    public init(read: @escaping () -> Float?, write: @escaping (Float) -> Bool) {
        self.read = read
        self.write = write
    }
}

public final class ManagedLevelControl {
    public enum Health: Equatable {
        case healthy
        /// Framework/sembol yok ya da imza doğrulanamadı.
        case unavailable
        /// Art arda başarısız çağrı sayısı.
        case failing(Int)
    }

    /// Bu kadar art arda başarısızlıktan sonra kontrol devre dışı kalır (yeniden deneme yok).
    public static let failureLimit = 3
    /// macOS'un Option+Shift ile kullandığı ince adım (1/64).
    public static let quantum: Float = 1 / 64

    public private(set) var health: Health
    private let backend: LevelControlBackend?

    public init(backend: LevelControlBackend?) {
        self.backend = backend
        health = backend == nil ? .unavailable : .healthy
    }

    /// Tuş olayı tüketilmeden **önce** sorulur.
    public var canHandle: Bool {
        switch health {
        case .healthy: true
        case .unavailable: false
        case .failing(let count): count < Self.failureLimit
        }
    }

    /// Geçerli seviye (0...1). Beklenmeyen değerler (NaN, aralık dışı) güvenilmez sayılır.
    public var level: Float? {
        guard let value = backend?.read(), value.isFinite, value >= -0.001, value <= 1.001 else { return nil }
        return min(max(value, 0), 1)
    }

    /// Seviyeyi değiştirir. `nil` dönerse işlem yapılamadı ve olay sisteme bırakılmalıdır.
    @discardableResult
    public func adjust(by delta: Float) -> Float? {
        guard canHandle, let current = level else {
            recordFailure()
            return nil
        }
        return set(current + delta)
    }

    @discardableResult
    public func set(_ value: Float) -> Float? {
        guard canHandle, let backend else { return nil }
        let target = (min(max(value, 0), 1) / Self.quantum).rounded() * Self.quantum
        guard backend.write(target) else {
            recordFailure()
            return nil
        }
        health = .healthy
        return target
    }

    /// Uyanma veya aygıt değişiminde yeniden denemeye izin verir (sınırlı: tek bir yeni hak).
    public func reset() {
        if case .failing = health { health = .healthy }
    }

    private func recordFailure() {
        switch health {
        case .healthy: health = .failing(1)
        case .failing(let count): health = .failing(count + 1)
        case .unavailable: break
        }
    }
}
