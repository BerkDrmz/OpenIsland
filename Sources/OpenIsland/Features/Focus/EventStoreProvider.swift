import EventKit

/// Takvim ve Anımsatıcılar'ın paylaştığı tek `EKEventStore`.
///
/// **Tembel**: store yalnızca izin verildikten sonra ve ilk gerçek kullanımda oluşturulur. İzin yoksa
/// veya özellik hiç kullanılmıyorsa EventKit daemon'una bağlantı kurulmaz (soğuk açılış maliyeti yok).
@MainActor
final class EventStoreProvider {
    private var cached: EKEventStore?

    var store: EKEventStore {
        if let cached { return cached }
        let store = EKEventStore()
        cached = store
        return store
    }

    var isCreated: Bool { cached != nil }
}
