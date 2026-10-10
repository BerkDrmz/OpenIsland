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
/// Olay güdümlü: `EKEventStoreChanged` bildirimi geldiğinde ve görünüm açıldığında yeniden okunur.
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
    @ObservationIgnored private var authorizationObservers: [(NotificationCenter, NSObjectProtocol)] = []

    func beginViewing() {
        visibleClients += 1
        if visibleClients == 1 { reload() }
    }

    func endViewing() {
        visibleClients = max(visibleClients - 1, 0)
        if visibleClients == 0 { stop() }
    }

    func stop() {
        reloadGeneration &+= 1
        if let fetchToken { provider.store.cancelFetchRequest(fetchToken) }
        fetchToken = nil
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
                    if self.visibleClients > 0 { self.reload() }
                }
            }
            authorizationObservers.append((center, token))
        }
    }

    /// Application shutdown, distinct from closing a visible widget.
    func shutdown() {
        visibleClients = 0
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
        provider.store.requestFullAccessToReminders { [weak self] _, _ in
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
        reloadGeneration &+= 1
        let generation = reloadGeneration
        if let fetchToken { provider.store.cancelFetchRequest(fetchToken) }
        fetchToken = nil
        if authorizationNeedsRefresh { refreshAuthorization() }
        guard hasAccess else {
            if !items.isEmpty { items = [] }
            return
        }
        let store = provider.store
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfToday, calendars: nil)
        let now = Date()
        fetchToken = store.fetchReminders(matching: predicate) { [weak self] reminders in
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
                    guard let self, self.visibleClients > 0, self.reloadGeneration == generation else { return }
                    self.fetchToken = nil
                    if self.items != mapped { self.items = mapped }
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
