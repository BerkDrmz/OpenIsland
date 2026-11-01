import AppKit
import EventKit

struct ReminderItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let due: Date?
    let isOverdue: Bool
    let listColor: NSColor?
}

/// Apple Anımsatıcılar (EventKit). Ayrı bir yapılacaklar veritabanı yoktur; macOS'un kendi listeleri
/// kullanılır ve iCloud eşitlemesi kendiliğinden çalışır.
///
/// Olay güdümlü: `EKEventStoreChanged` veriyi geçersiz kılar; görünürken yeniden okunur.
/// Değişiklik yoksa tekrar açılışlar yalnız yayımlanmış değerleri kullanır; EventKit nesneleri saklanmaz.
/// İzin yoksa hiçbir EventKit çağrısı yapılmaz; görünüm "Erişim ver" durumuna düşer.
@MainActor
@Observable
final class RemindersService {
    /// Bugün sona eren veya gecikmiş, tamamlanmamış anımsatıcılar.
    private(set) var items: [ReminderItem] = []
    private(set) var authorization: EKAuthorizationStatus
    private(set) var lastError: String?

    @ObservationIgnored private let provider: EventStoreProvider
    @ObservationIgnored private var visibleClients = 0
    @ObservationIgnored private var fetchToken: Any?
    @ObservationIgnored private var reloadGeneration: UInt64 = 0
    @ObservationIgnored private let readAuthorization: () -> EKAuthorizationStatus
    @ObservationIgnored private var authorizationNeedsRefresh = false
    // Only immutable published values are reused, never EventKit objects.
    // Existing store/permission/day/clock/wake events invalidate this snapshot.
    @ObservationIgnored private var hasCurrentSnapshot = false
    @ObservationIgnored private var authorizationObservers: [(NotificationCenter, NSObjectProtocol)] = []

    /// `fetchReminders` izin denetimini Takvim servisine senkron XPC ile yapar; ana iş parçacığında çağrılınca açılış
    /// animasyonu servisin cevabını bekliyordu (yoğun yükte belirgin takılma). Sorgu başlatma ve iptal bu seri kuyrukta
    /// sırayla yapılır; sonuç ve yayın ana iş parçacığındadır.
    private static let queue = DispatchQueue(label: "OpenIsland.reminders.fetch", qos: .userInitiated)
    private struct StoreRef: @unchecked Sendable { let store: EKEventStore; let token: Any? }

    func beginViewing() {
        visibleClients += 1
        if visibleClients == 1, !hasCurrentSnapshot || authorizationNeedsRefresh { reload() }
    }

    func endViewing() {
        visibleClients = max(visibleClients - 1, 0)
        if visibleClients == 0 { stop() }
    }

    func stop() {
        reloadGeneration &+= 1
        cancelFetch()
    }

    private func cancelFetch() {
        guard let fetchToken else { return }
        self.fetchToken = nil
        let ref = StoreRef(store: provider.store, token: fetchToken)
        Self.queue.async { if let token = ref.token { ref.store.cancelFetchRequest(token) } }
    }

    init(provider: EventStoreProvider,
         readAuthorization: @escaping () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .reminder) }) {
        self.provider = provider
        self.readAuthorization = readAuthorization
        authorization = readAuthorization()
        // Keep only permission invalidation alive between appearances. These events do not fetch
        // reminders while hidden; repeated hovers reuse the known permission without synchronous XPC.
        let workspace = NSWorkspace.shared.notificationCenter
        for (center, name) in [(workspace, NSWorkspace.didActivateApplicationNotification),
                               (workspace, NSWorkspace.didWakeNotification),
                               (NotificationCenter.default, Notification.Name.EKEventStoreChanged),
                               (NotificationCenter.default, Notification.Name.NSCalendarDayChanged),
                               (NotificationCenter.default, Notification.Name.NSSystemTimeZoneDidChange),
                               (NotificationCenter.default, Notification.Name.NSSystemClockDidChange)] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.authorizationNeedsRefresh = true
                    self.hasCurrentSnapshot = false
                    if self.visibleClients > 0 { self.reload() }
                }
            }
            authorizationObservers.append((center, token))
        }
    }

    /// Application shutdown, distinct from closing a visible widget.
    func shutdown() {
        visibleClients = 0
        hasCurrentSnapshot = false
        stop()
        authorizationObservers.forEach { center, token in center.removeObserver(token) }
        authorizationObservers.removeAll()
    }

    private func refreshAuthorization() {
        let latest = readAuthorization()
        authorizationNeedsRefresh = false
        if authorization != latest { authorization = latest }
    }

    var hasAccess: Bool { authorization == .fullAccess }

    /// Karar verilmemişse izin sorulur; reddedilmişse Sistem Ayarları › Anımsatıcılar açılır.
    func requestAccess() {
        refreshAuthorization()
        guard authorization == .notDetermined else {
            AppHandoff.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"))
            return
        }
        provider.store.requestFullAccessToReminders { @Sendable [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.refreshAuthorization()
                    self?.reload()
                }
            }
        }
    }

    /// Görünüm açıldığında çağrılır: izin yoksa hiçbir şey yapılmaz.
    func reload() {
        guard visibleClients > 0 else { return }
        hasCurrentSnapshot = false
        reloadGeneration &+= 1
        let generation = reloadGeneration
        cancelFetch()
        if authorizationNeedsRefresh { refreshAuthorization() }
        guard hasAccess else {
            if !items.isEmpty { items = [] }
            return
        }
        let ref = StoreRef(store: provider.store, token: nil)
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))
        let now = Date()
        Self.queue.async { [weak self] in
            let predicate = ref.store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfToday, calendars: nil)
            let token = Self.fetch(ref.store, predicate, now: now, generation: generation, into: self)
            let started = StoreRef(store: ref.store, token: token)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Sonuç önce geldiyse veya iş bu arada geçersiz kaldıysa tanıtıcı saklanmaz; geçersiz iş iptal edilir.
                    guard let self, self.visibleClients > 0, self.reloadGeneration == generation else {
                        Self.queue.async { if let token = started.token { started.store.cancelFetchRequest(token) } }
                        return
                    }
                    if self.deliveredGeneration != generation { self.fetchToken = started.token }
                }
            }
        }
    }

    @ObservationIgnored private var deliveredGeneration: UInt64?

    private nonisolated static func fetch(_ store: EKEventStore, _ predicate: NSPredicate, now: Date, generation: UInt64,
                                          into service: RemindersService?) -> Any {
        // EventKit invokes this legacy completion on its own queue. Explicit
        // Sendable isolation keeps the mapping/sort closures from inheriting
        // this service's MainActor; only immutable values cross to the UI.
        return store.fetchReminders(matching: predicate) { @Sendable [weak service] reminders in
            let receivedSnapshot = reminders != nil
            let mapped = (reminders ?? [])
                .map { reminder -> ReminderItem in
                    let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                    return ReminderItem(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Adsız",
                                        due: due, isOverdue: due.map { $0 < Calendar.current.startOfDay(for: now) } ?? false,
                                        listColor: reminder.calendar.map { NSColor(cgColor: $0.cgColor) } ?? nil)
                }
                .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let service, service.visibleClients > 0, service.reloadGeneration == generation else { return }
                    service.fetchToken = nil
                    service.deliveredGeneration = generation
                    service.hasCurrentSnapshot = receivedSnapshot
                    if service.items != mapped { service.items = mapped }
                }
            }
        }
    }

    /// Anımsatıcıyı Reminders'ta açar. `x-apple-reminderkit` Reminders'ın kayıtlı şemasıdır (belgelenmemiş);
    /// kimlik eşleşmezse Reminders yine açılır. Bağlantı kurulamazsa uygulama doğrudan açılır.
    func open(_ item: ReminderItem) {
        let identifier = item.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let url = identifier.isEmpty ? nil : URL(string: "x-apple-reminderkit://REMCDReminder/\(identifier)")
        AppHandoff.open(url, fallbackBundleID: AppHandoff.remindersBundleID)
    }

    func openApp() {
        AppHandoff.openApplication(bundleID: AppHandoff.remindersBundleID)
    }

    func complete(_ item: ReminderItem) {
        guard hasAccess, let reminder = provider.store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        reminder.isCompleted = true
        do {
            try provider.store.save(reminder, commit: true)
            items.removeAll { $0.id == item.id }
            lastError = nil
            // A fetch started before this write must not resurrect the item or
            // turn its stale result into a reusable snapshot. User writes are
            // actual invalidations, unlike unchanged panel appearances.
            reload()
        } catch {
            lastError = "Kaydedilemedi"
        }
    }

    /// Varsayılan listeye bugün için yeni anımsatıcı.
    func add(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasAccess, !trimmed.isEmpty, let list = provider.store.defaultCalendarForNewReminders() else { return }
        let reminder = EKReminder(eventStore: provider.store)
        reminder.title = trimmed
        reminder.calendar = list
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        do {
            try provider.store.save(reminder, commit: true)
            lastError = nil
            reload()
        } catch {
            lastError = "Kaydedilemedi"
        }
    }

}
