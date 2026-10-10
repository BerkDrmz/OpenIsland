import AppKit
import IslandCore

/// Adanın pencerelerini Space geçişlerine karşı sabitleyen bir yöntem. `SpacePresentationController` sağlayıcıları
/// ölçülen sırayla dener ve her birinin sonucunu gerçekten doğrular (yalnızca çağrının hata vermemesine güvenmez).
/// Yeni bir macOS sürümü bir yöntemi bozarsa yalnızca ilgili sağlayıcı güncellenir.
@MainActor
protocol SpaceProvider: AnyObject {
    var kind: SpaceProviderKind { get }
    /// Bu macOS'ta kullanılabilir mi (ör. gereken semboller var mı).
    var isAvailable: Bool { get }
    func install(_ windows: [NSWindow])
    /// Sonraki sağlayıcıya geçmeden önce bu sağlayıcının etkisini geri alır.
    func uninstall(_ windows: [NSWindow])
    func tearDown()
}

/// Pencerenin yönetilen (macOS'un kaydırdığı) Space üyeliklerini okuyabilen yardımcı.
@MainActor
protocol SpaceMembershipProbe: AnyObject {
    /// Adanın kendi Space'i hariç üyelikler; okunamıyorsa `nil`.
    func managedSpaces(of windowNumber: Int) -> [UInt64]?
}

/// Yalnızca public AppKit. Ölçüldüğü gibi pencere macOS'un yönettiği her Space'in üyesi olur ve geçiş
/// animasyonuyla kayar (tam ekrana giriş/çıkışta 1774 pt); ama her Space'te ve tam ekranda görünür kalır.
/// Diğer pencere ayarları (`.borderless + .nonactivatingPanel`, seviye `.mainMenu + 3`, `hidesOnDeactivate = false`,
/// `isMovable = false`) panel sınıflarındadır ve bütün sağlayıcılarda aynıdır.
@MainActor
final class PublicStationaryProvider: SpaceProvider {
    /// Ada pencerelerinin temel davranışı: bütün sağlayıcılar bunun üzerine kurulur (panel bunu ilk kurulumda uygular).
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .canJoinAllApplications, .stationary, .fullScreenAuxiliary, .ignoresCycle,
    ]

    let kind = SpaceProviderKind.publicStationary
    let isAvailable = true

    func install(_ windows: [NSWindow]) {
        for window in windows {
            if window.collectionBehavior != Self.collectionBehavior { window.collectionBehavior = Self.collectionBehavior }
        }
    }

    func uninstall(_ windows: [NSWindow]) {}
    func tearDown() {}
}

/// Son çare: amaç yalnızca görünürlük. Public yapılandırmayı yeniden uygular ve pencereyi öne alır
/// (başka bir yöntem pencereyi ekrandan düşürdüyse). Kayma kabul edilir; kaybolma kabul edilmez.
@MainActor
final class SafeFallbackProvider: SpaceProvider {
    let kind = SpaceProviderKind.safeFallback
    let isAvailable = true

    func install(_ windows: [NSWindow]) {
        for window in windows {
            window.collectionBehavior = PublicStationaryProvider.collectionBehavior
            if window.alphaValue < 1 { window.alphaValue = 1 }
            window.orderFrontRegardless()
        }
    }

    func uninstall(_ windows: [NSWindow]) {}
    func tearDown() {}
}
