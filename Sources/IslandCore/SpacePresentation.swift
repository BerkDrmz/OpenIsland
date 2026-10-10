/// Adanın pencerelerini macOS Space geçişlerine karşı sabitleyen yöntem (uygulamadaki sağlayıcılar).
public enum SpaceProviderKind: String, Sendable, CaseIterable {
    /// Dock'un yönetmediği bir WindowServer Space'i (SkyLight, private).
    case privateSpace = "private"
    /// Yalnızca public AppKit: `canJoinAllSpaces + stationary + fullScreenAuxiliary` (+ `canJoinAllApplications`).
    case publicStationary = "public"
    /// Son çare: public yapılandırmayı yeniden uygular ve pencereyi öne alır. Amaç yalnızca görünürlük.
    case safeFallback = "fallback"
}

/// Pencerenin Space geçişlerindeki ölçülen davranışı.
public enum SpaceBehavior: Sendable, Equatable, Comparable {
    /// Ekranda ve macOS'un yönettiği hiçbir Space'in üyesi değil: geçiş animasyonuna katılmaz (kaymaz).
    case pinned
    /// Ekranda, ama üyeliği okunamadı: sabit olup olmadığı doğrulanamıyor.
    case unverified
    /// Ekranda, ama yönetilen Space'lerin üyesi: geçişte Space ile birlikte kayar.
    case slides
    /// Ekranda değil.
    case hidden
}

/// Sağlayıcı seçimi ve doğrulama kuralları (saf, test edilir).
///
/// **Ölçülen A/B** (cihazda, `SLSGetScreenRectForWindow` ile ~175 Hz; pencerenin animasyon sırasındaki gerçek
/// ekran konumu, ekran kaydı gerekmez). Tam ekrana giriş ve çıkış, 1906 örnek:
/// - public (`NSPanel`, `.borderless + .nonactivatingPanel`, `canJoinAllSpaces + stationary + fullScreenAuxiliary`,
///   seviye `.mainMenu + 3`): en büyük yatay kayma **1774 pt**, 207 hareketli örnek; masaüstü (1) ve tam ekran
///   (109) Space'lerinin üyesi;
/// - private Space: **0,0 pt**, 0 hareketli örnek; yönetilen hiçbir Space'in üyesi değil.
/// Üyelik ile kayma birebir örtüşüyor: yönetilen bir Space'in üyesi olan pencere o Space'in animasyonuyla kayar.
/// Bu yüzden çalışma zamanındaki doğrulama üyeliğe bakar (animasyonu örneklemek yoklama gerektirirdi).
public enum SpacePresentationPolicy {
    /// Ölçüme göre tercih sırası. Public yöntem kayıyor; ancak bütün senaryolarda 0 pt ölçülürse öne alınmalı.
    public static let measuredOrder: [SpaceProviderKind] = [.privateSpace, .publicStationary, .safeFallback]

    /// A/B testi için istenen sağlayıcı öne alınır; kalanlar ölçülen sırayla yedek olarak kalır.
    public static func order(preferred: SpaceProviderKind?) -> [SpaceProviderKind] {
        guard let preferred else { return measuredOrder }
        return [preferred] + measuredOrder.filter { $0 != preferred }
    }

    /// Doğrulama: pencere ekranda mı, yönetilen (kayan) Space'lerin üyesi mi. `managedSpaces`: adanın kendi
    /// Space'i hariç üyelikler; okunamıyorsa `nil`.
    public static func behavior(isOnScreen: Bool, managedSpaces: [UInt64]?) -> SpaceBehavior {
        guard isOnScreen else { return .hidden }
        guard let managedSpaces else { return .unverified }
        return managedSpaces.isEmpty ? .pinned : .slides
    }

    /// Sağlayıcı işini yaptı mı? Hayırsa zincirde bir sonrakine geçilir.
    /// - private: yalnızca kaymaması için vardır; kayıyor veya görünmüyorsa başarısızdır.
    /// - public ve güvenli yedek: görünür kalmaları yeterlidir (kayma bilinen, kabul edilen sınırdır).
    public static func accepts(_ behavior: SpaceBehavior, from provider: SpaceProviderKind) -> Bool {
        switch provider {
        case .privateSpace: behavior == .pinned || behavior == .unverified
        case .publicStationary, .safeFallback: behavior != .hidden
        }
    }

    /// Zincirdeki bir sonraki sağlayıcı (yoksa `nil`: son çare de başarısız).
    public static func next(after provider: SpaceProviderKind, in order: [SpaceProviderKind]) -> SpaceProviderKind? {
        guard let index = order.firstIndex(of: provider), index + 1 < order.count else { return nil }
        return order[index + 1]
    }

    /// Tüm pencerelerin (ekran başına panel + sensör) ortak durumu: en kötü pencere belirler; doğrulama
    /// bekleyen varsa sonuç henüz yoktur.
    public static func combine(_ members: [(provider: SpaceProviderKind, behavior: SpaceBehavior?)]) -> SpacePresentationStatus {
        guard !members.isEmpty, members.allSatisfy({ $0.behavior != nil }) else { return .pending }
        let worst = members.max { $0.behavior! < $1.behavior! }!
        return .settled(provider: worst.provider, behavior: worst.behavior!)
    }
}

public enum SpacePresentationStatus: Sendable, Equatable {
    case pending
    case settled(provider: SpaceProviderKind, behavior: SpaceBehavior)
}
