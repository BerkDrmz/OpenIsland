import Foundation
import IslandCore

/// Private çerçeve çağrıları için macOS güncellemesi koruması (kural: `PrivateAPIGuardRules`).
///
/// Bir özelliğin ilk private çağrısından önce `pending` olarak macOS yapı numarası saklanır; çağrı başarıyla
/// döndükten sonra silinir. Süreç o çağrıda çökerse bir sonraki açılışta `pending` hâlâ durur: o yapı için özellik
/// kapatılır (uygulama her açılışta çökmez) ve yeni bir macOS güncellemesi gelince yeniden denenir. Her özellik
/// (sıcaklık, parlaklık, klavye ışığı) ayrı korunur; yani bir özelliğin kırılması diğerlerini kapatmaz.
/// Yalnız çökme kalıcı engeldir: çökmeden dönen geçersiz sonuç (`failed`) özelliği bu süreç için kapatır, geçici
/// olarak okunamayan değer (`unavailable`, ör. uyanırken dahili ekran etkin değil) hiçbir şeyi kapatmaz.
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
        migrateIfNeeded()
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

    /// Çağrı çökmedi ama sonuç geçersiz (sembol yok, aralık dışı değer): bu süreçte tekrar denenmez. Kalıcı engel
    /// yazılmaz; yazılınca tek bir geçici hata, özelliği o macOS yapısı boyunca kapatıyordu.
    static func failed(_ feature: String) {
        resolved[feature] = false
        defaults.removeObject(forKey: key(feature, "pending"))
    }

    /// Çağrı çökmedi ama değer şu an yok (aygıt etkin değil, okuma reddedildi): sonra yeniden denenebilir.
    static func unavailable(_ feature: String) {
        defaults.removeObject(forKey: key(feature, "pending"))
    }

    /// Sürüm 1, geçersiz sonucu da çökme gibi kalıcı engel olarak saklıyordu (`failed`); ikisi ayırt edilemediği için
    /// eski engeller bir kez silinir. Gerçekten çöken bir çağrı en çok bir kez daha çöker ve yeniden engellenir.
    private static var didMigrate = false
    private static func migrateIfNeeded() {
        guard !didMigrate else { return }
        didMigrate = true
        guard defaults.integer(forKey: "privateAPI.guardVersion") < 2 else { return }
        for feature in ["temperature", "brightness", "keyboard"] { defaults.removeObject(forKey: key(feature, "blocked")) }
        defaults.set(2, forKey: "privateAPI.guardVersion")
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
