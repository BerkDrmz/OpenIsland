import AppKit
import IslandCore

/// Adanın pencerelerini Dock'un yönetmediği bir WindowServer Space'ine alan sağlayıcı. **Uygulamada Space ile
/// ilgili private sembollerin tamamı bu dosyadadır**; bir macOS sürümü davranışı değiştirirse yalnızca bu dosya
/// güncellenir.
///
/// **Kök neden:** `canJoinAllSpaces` pencereyi Dock'un yönettiği her Space'e (masaüstleri ve tam ekran
/// uygulamalar) ayrı ayrı üye yapar. Space değişirken WindowServer bu Space'lerin katmanlarını kaydırır; ada da
/// içlerinde olduğu için kayar. Pencerenin çerçevesi hiç değişmez; `.stationary` yalnızca Mission Control içindir.
/// Bunu engelleyen public bir API yoktur (A/B ölçümü: `SpacePresentationPolicy`).
///
/// **Deneyle belirlenen en küçük çağrı kümesi:** `SpaceCreate` + `ShowSpaces` (olmadan pencere görünmüyor) +
/// `AddWindowsToSpaces` + yönetilen üyeliklerin `RemoveWindowsFromSpaces` ile kaldırılması. Ekleme tek başına yalnızca
/// pencere macOS'un Space'lerine yerleşmeden önce (açılışta, `orderFront` ile aynı turda) yalıtır; yerleşmiş pencere
/// (açılıştan 0,3 sn sonra, yedekten dönüşte, ekran değişiminde) eklendikten sonra da [442, 1] gibi yönetilen
/// Space'lerde kalıyordu. Pencere seviyesi sabit kalır; Space sırası ayrıca kurulur: varsayılan 0, tam ekran
/// animasyonundaki pencerenin 27 seviyesindeki adanın önüne geçmesini engellemiyordu.
/// Bu macOS’ta güvenlik ajanı/ekran kilidi Space seviyeleri 200/300; kaplama bunların altında kalır. AppKit'in `orderOut`/`orderFront`'u üyeliği bozmaz.
/// Space'ten çıkarılan pencere hemen tüm yönetilen Space'lere döner (public davranış).
///
/// **Güvenlik:** semboller `dlsym` ile çözülür (SLS, yoksa CGS öneki). Biri eksikse `isAvailable == false` olur ve
/// denetleyici public sağlayıcıya geçer. Çağrıların dönüş koduna güvenilmez (`ShowSpaces` başarıda da sıfır
/// dışı döndürüyor); sonucu denetleyici görünürlük ve üyelikle doğrular.
@MainActor
final class PrivateSpaceProvider: SpaceProvider, SpaceMembershipProbe {
    let kind = SpaceProviderKind.privateSpace
    var isAvailable: Bool { skyLight != nil }

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias WindowsFn = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias DestroyFn = @convention(c) (Int32, UInt64) -> Int32
    private typealias SpaceLevelFn = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias ReadSpaceLevelFn = @convention(c) (Int32, UInt64) -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private struct SkyLight {
        let connection: Int32
        let create: CreateFn
        let show: SpacesFn
        let hide: SpacesFn
        let add: WindowsFn
        let remove: WindowsFn
        let destroy: DestroyFn
        let setLevel: SpaceLevelFn
        let getLevel: ReadSpaceLevelFn
        /// Yalnızca doğrulama için; yoksa üyelik okunamaz (`.unverified`).
        let copySpaces: CopySpacesFn?
    }

    private let skyLight: SkyLight?
    /// Tembel oluşturulur; 0 = yok.
    private var space: UInt64 = 0
    /// Normal Space sırası 0; tam ekran animasyonu bu sıranın önüne geçebilir.
    /// Ayrı Space sırası pencere seviyesinden bağımsızdır; 2 canlı karşılaştırmada geçişin önünde kaldı.
    private static let overlaySpaceLevel: Int32 = 2

    init() {
        skyLight = Self.load()
    }

    func install(_ windows: [NSWindow]) {
        guard let skyLight, let space = ensureSpace(skyLight) else { return }
        let numbers = windows.map(\.windowNumber).filter { $0 > 0 }
        guard !numbers.isEmpty else { return }
        skyLight.add(skyLight.connection, numbers as CFArray, [space] as CFArray)
        // Sıra önemli: önce eklenir, sonra yönetilen üyelikler kaldırılır; pencere hiçbir an Space'siz (görünmez)
        // kalmaz. Yeni pencerede liste zaten boştur. Üyelik okunamazsa bu adım atlanır (doğrulama `unverified` der).
        for number in numbers {
            guard let managed = managedSpaces(of: number), !managed.isEmpty else { continue }
            skyLight.remove(skyLight.connection, [number] as CFArray, managed as CFArray)
        }
    }

    func uninstall(_ windows: [NSWindow]) {
        guard let skyLight, space != 0 else { return }
        let numbers = windows.map(\.windowNumber).filter { $0 > 0 }
        guard !numbers.isEmpty else { return }
        skyLight.remove(skyLight.connection, numbers as CFArray, [space] as CFArray)
    }

    /// Uygulama kapanırken. (Süreç ölürse WindowServer bağlantının Space'ini kendisi temizler.)
    func tearDown() {
        guard let skyLight, space != 0 else { return }
        _ = skyLight.hide(skyLight.connection, [space] as CFArray)
        _ = skyLight.destroy(skyLight.connection, space)
        space = 0
    }

    /// Bu sağlayıcı birincil olmasa da (A/B) doğrulama için kullanılır. Adanın kendi Space'i hariç tutulur:
    /// bir sürüm onu da döndürürse yanlış alarm olmaz.
    func managedSpaces(of windowNumber: Int) -> [UInt64]? {
        guard let skyLight, let copySpaces = skyLight.copySpaces, windowNumber > 0,
              let spaces = copySpaces(skyLight.connection, 0x7, [windowNumber] as CFArray)?.takeRetainedValue() as? [NSNumber]
        else { return nil }
        return spaces.map(\.uint64Value).filter { $0 != space }
    }

    private func ensureSpace(_ skyLight: SkyLight) -> UInt64? {
        if space != 0 {
            // Uyanmada Space kimliği kalabilir ama görünürlüğü kaybolabilir.
            // Mevcut Space'i de her yeniden kurulumda görünür yap.
            skyLight.setLevel(skyLight.connection, space, Self.overlaySpaceLevel)
            guard skyLight.getLevel(skyLight.connection, space) == Self.overlaySpaceLevel else { return nil }
            _ = skyLight.show(skyLight.connection, [space] as CFArray)
            return space
        }
        // Bayrak 1: masaüstü simgeleri bu Space'te çizilmez.
        let created = skyLight.create(skyLight.connection, 1, nil)
        guard created != 0 else { return nil }
        skyLight.setLevel(skyLight.connection, created, Self.overlaySpaceLevel)
        guard skyLight.getLevel(skyLight.connection, created) == Self.overlaySpaceLevel else {
            _ = skyLight.destroy(skyLight.connection, created)
            return nil
        }
        _ = skyLight.show(skyLight.connection, [created] as CFArray)
        space = created
        return created
    }

    private static func load() -> SkyLight? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, "SLS" + name) ?? dlsym(handle, "CGS" + name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let connection = symbol("MainConnectionID", as: ConnectionFn.self),
              let create = symbol("SpaceCreate", as: CreateFn.self),
              let show = symbol("ShowSpaces", as: SpacesFn.self),
              let hide = symbol("HideSpaces", as: SpacesFn.self),
              let add = symbol("AddWindowsToSpaces", as: WindowsFn.self),
              let remove = symbol("RemoveWindowsFromSpaces", as: WindowsFn.self),
              let destroy = symbol("SpaceDestroy", as: DestroyFn.self),
              let setLevel = symbol("SpaceSetAbsoluteLevel", as: SpaceLevelFn.self),
              let getLevel = symbol("SpaceGetAbsoluteLevel", as: ReadSpaceLevelFn.self)
        else { return nil }
        return SkyLight(connection: connection(), create: create, show: show, hide: hide, add: add, remove: remove,
                        destroy: destroy, setLevel: setLevel, getLevel: getLevel, copySpaces: symbol("CopySpacesForWindows", as: CopySpacesFn.self))
    }
}
