import Foundation
import IslandCore

/// Private çerçeve çağrıları için macOS güncellemesi koruması (kural: `PrivateAPIGuardRules`).
///
/// Bir özelliğin ilk private çağrısından önce `pending` olarak macOS yapı numarası saklanır; çağrı başarıyla
/// döndükten sonra silinir. Süreç o çağrıda çökerse bir sonraki açılışta `pending` hâlâ durur: o yapı için özellik
/// kapatılır (uygulama her açılışta çökmez) ve yeni bir macOS güncellemesi gelince yeniden denenir. Her özellik
/// (sıcaklık, parlaklık, klavye ışığı) ayrı korunur; yani bir özelliğin kırılması diğerlerini kapatmaz.
@MainActor
enum PrivateAPIGuard {
    private static let defaults = UserDefaults.standard
    nonisolated static let build: String = {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()
    /// Bu süreçte durumu çözülmüş özellikler (açılışta bir kez) ve ilk çağrısı başarıyla biten özellikler.
    private static var resolved: [String: Bool] = [:]
    private static var validated: Set<String> = []

    /// Özellik bu yapıda kullanılabilir mi? İlk çağrıdan önce `pending` yazılır; çağıran ilk başarılı okumadan sonra
    /// `succeeded(_:)` çağırmalıdır.
    static func begin(_ feature: String) -> Bool {
        if validated.contains(feature) { return true }
        if let allowed = resolved[feature], !allowed { return false }
        var state = PrivateAPIGuardRules.State(pendingBuild: defaults.string(forKey: key(feature, "pending")),
                                               blockedBuild: defaults.string(forKey: key(feature, "blocked")))
        if resolved[feature] == nil {
            state = PrivateAPIGuardRules.launch(state, currentBuild: build)
            save(feature, state)
            resolved[feature] = PrivateAPIGuardRules.isAllowed(state, currentBuild: build)
            if resolved[feature] == false {
                NSLog("[OpenIsland] \(feature): önceki açılışta bu macOS yapısında (\(build)) çöktü; kapalı.")
                return false
            }
        }
        state.pendingBuild = build
        save(feature, state)
        defaults.synchronize() // süreç hemen çökerse işaret diske ulaşmış olmalı
        return true
    }

    /// İlk çağrı çökmeden döndü: işaret silinir.
    static func succeeded(_ feature: String) {
        guard !validated.contains(feature) else { return }
        validated.insert(feature)
        defaults.removeObject(forKey: key(feature, "pending"))
    }

    /// Çağrı çökmedi ama sonuç geçersiz/başarısız: yeni bir yapıda yeniden denenir; bu yapıda tekrar denenmez.
    static func failed(_ feature: String) {
        resolved[feature] = false
        defaults.removeObject(forKey: key(feature, "pending"))
        defaults.set(build, forKey: key(feature, "blocked"))
    }

    private static func key(_ feature: String, _ name: String) -> String { "privateAPI.\(feature).\(name)" }

    private static func save(_ feature: String, _ state: PrivateAPIGuardRules.State) {
        func set(_ value: String?, _ name: String) {
            if let value { defaults.set(value, forKey: key(feature, name)) } else { defaults.removeObject(forKey: key(feature, name)) }
        }
        set(state.pendingBuild, "pending")
        set(state.blockedBuild, "blocked")
    }
}
