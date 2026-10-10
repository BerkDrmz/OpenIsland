import AppKit

/// NSAppleScript'i ayrı bir seri kuyrukta çalıştırır; ana iş parçacığı Apple Event
/// zaman aşımlarında (hedef uygulama meşgulken) donmaz.
final class ScriptRunner: @unchecked Sendable {
    static let shared = ScriptRunner()
    private let queue = DispatchQueue(label: "openisland.applescript", qos: .userInitiated)
    private var cache: [String: NSAppleScript] = [:] // yalnızca `queue` üzerinde erişilir
    private var cacheOrder: [String] = []
    private let cacheLimit = 32

    /// Sonuç ve (varsa) Apple Event hata kodu (ör. -1743 izin yok, -600 uygulama çalışmıyor).
    struct Outcome<T: Sendable>: Sendable {
        let value: T?
        let errorCode: Int?
    }

    func execute<T: Sendable>(_ source: String, cacheResult: Bool = true, transform: @escaping @Sendable (NSAppleEventDescriptor) -> T?) async -> Outcome<T> {
        await withCheckedContinuation { continuation in
            queue.async {
                autoreleasepool {
                    // Süre sürüklemesindeki her sayı ayrı script üretir; bunlar önbelleğe alınmaz.
                    // Diğer sorgular da uzun oturumlarda sınırsız derlenmiş script biriktiremez.
                    let script = (cacheResult ? self.cache[source] : nil) ?? {
                        let boundedSource = "with timeout of 5 seconds\n\(source)\nend timeout"
                        guard let compiled = NSAppleScript(source: boundedSource) else { return nil as NSAppleScript? }
                        if cacheResult {
                            if self.cacheOrder.count >= self.cacheLimit {
                                self.cache.removeValue(forKey: self.cacheOrder.removeFirst())
                            }
                            self.cache[source] = compiled
                            self.cacheOrder.append(source)
                        }
                        return compiled
                    }()
                    var error: NSDictionary?
                    let descriptor = script?.executeAndReturnError(&error)
                    let code = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
                    continuation.resume(returning: Outcome(value: descriptor.flatMap(transform), errorCode: code))
                }
            }
        }
    }

    func run<T: Sendable>(_ source: String, transform: @escaping @Sendable (NSAppleEventDescriptor) -> T?) async -> T? {
        await execute(source, transform: transform).value
    }
}

