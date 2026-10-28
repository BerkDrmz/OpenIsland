import AppKit
import EventKit

// An SDK-style legacy completion: intentionally NOT @Sendable in its API.
// The real RemindersService source is compiled unchanged beside this fixture.
// Only the provider is replaced; no EventKit store, permission or user item is used.
final class EKCalendar: @unchecked Sendable { let cgColor = NSColor.green.cgColor }
final class EKReminder: @unchecked Sendable {
    let calendarItemIdentifier: String
    var title: String? = "Owned reminder fixture"
    var dueDateComponents: DateComponents? = DateComponents(year: 2026, month: 10, day: 1)
    var calendar: EKCalendar? = EKCalendar()
    var isCompleted = false
    init(eventStore: EKEventStore) { calendarItemIdentifier = UUID().uuidString }
}
final class LegacyFetch: @unchecked Sendable {
    let callback: ([EKReminder]?) -> Void
    init(_ callback: @escaping ([EKReminder]?) -> Void) { self.callback = callback }
    func deliver(_ rows: [EKReminder]?, completion: @escaping @Sendable () -> Void) {
        DispatchQueue.global().async {
            precondition(!Thread.isMainThread, "Fixture did not exercise background delivery")
            self.callback(rows)
            completion()
        }
    }
}
final class EKEventStore: @unchecked Sendable {
    fileprivate var requests: [LegacyFetch] = []
    private(set) var cancellations = 0
    func predicateForIncompleteReminders(withDueDateStarting: Date?, ending: Date?, calendars: [EKCalendar]?) -> NSPredicate { NSPredicate(value: true) }
    func fetchReminders(matching: NSPredicate, completion: @escaping ([EKReminder]?) -> Void) -> Any {
        requests.append(LegacyFetch(completion));return requests.count
    }
    func cancelFetchRequest(_ token: Any) { cancellations += 1 }
    static func authorizationStatus(for type: EKEntityType) -> EKAuthorizationStatus { .fullAccess }
    func requestFullAccessToReminders(completion: @escaping (Bool, Error?) -> Void) { completion(true, nil) }
    var lookedUp: EKReminder?
    func calendarItem(withIdentifier id: String) -> Any? { lookedUp?.calendarItemIdentifier == id ? lookedUp : nil }
    func defaultCalendarForNewReminders() -> EKCalendar? { EKCalendar() }
    func save(_ item: EKReminder, commit: Bool) throws {}
}
@MainActor final class EventStoreProvider { let store = EKEventStore() }
@MainActor enum AppHandoff {
    static let remindersBundleID = "com.apple.reminders"
    static func open(_ url: URL?, fallbackBundleID: String? = nil) {}
    static func openApplication(bundleID: String) {}
}
@MainActor final class NSWorkspace {
    static let shared = NSWorkspace()
    let notificationCenter = NotificationCenter()
    nonisolated static let didActivateApplicationNotification = Notification.Name("fixture.activate")
    nonisolated static let didWakeNotification = Notification.Name("fixture.wake")
}

@main struct RemindersSnapshotCheck {
    @MainActor static func main() async {
        let provider = EventStoreProvider()
        let service = RemindersService(provider: provider, readAuthorization: { .fullAccess })
        service.beginViewing()
        let first = EKReminder(eventStore: provider.store)
        await deliver(provider.store.requests.last!, [first])
        await settle()
        precondition(service.items.map(\.id) == [first.calendarItemIdentifier])
        service.endViewing()
        let warmed = provider.store.requests.count
        for _ in 0..<1000 {
            service.beginViewing(); precondition(service.items.map(\.id) == [first.calendarItemIdentifier]); service.endViewing()
        }
        precondition(provider.store.requests.count == warmed, "Unchanged appearances fetched again")
        // All old invalidation events still force fresh data; hidden events do not query.
        for (center, name) in [(NotificationCenter.default, Notification.Name.EKEventStoreChanged),
                               (NotificationCenter.default, Notification.Name.NSCalendarDayChanged),
                               (NotificationCenter.default, Notification.Name.NSSystemTimeZoneDidChange),
                               (NotificationCenter.default, Notification.Name.NSSystemClockDidChange),
                               (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
                               (NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification)] {
            let before = provider.store.requests.count
            center.post(name: name, object: nil)
            precondition(provider.store.requests.count == before, "Hidden event fetched")
            service.beginViewing()
            precondition(provider.store.requests.count == before + 1, "Invalidation missed on reopen")
            await deliver(provider.store.requests.last!, [first]); await settle(); service.endViewing()
        }
        // Visible invalidation and explicit reload are never suppressed by the snapshot.
        service.beginViewing(); let before = provider.store.requests.count
        NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        precondition(provider.store.requests.count == before + 1)
        let stale = provider.store.requests.last!
        service.reload(); let current = provider.store.requests.last!
        let second = EKReminder(eventStore: provider.store)
        await deliver(current, [second]); await settle(); await deliver(stale, [first]); await settle()
        precondition(service.items.map(\.id) == [second.calendarItemIdentifier], "Stale completion overwrote snapshot")
        service.endViewing(); let known = provider.store.requests.count
        service.beginViewing(); service.endViewing(); precondition(provider.store.requests.count == known)
        // A cancelled or nil fetch is NOT a current snapshot; retry immediately on demand.
        service.beginViewing(); service.reload(); let cancelled = provider.store.requests.last!
        service.endViewing(); service.beginViewing(); precondition(provider.store.requests.count == known + 2)
        let retry = provider.store.requests.last!
        await deliver(cancelled, [first]); await settle()
        precondition(service.items.map(\.id) == [second.calendarItemIdentifier])
        await deliver(retry, nil); await settle(); service.endViewing()
        let failed = provider.store.requests.count
        service.beginViewing(); precondition(provider.store.requests.count == failed + 1)
        await deliver(provider.store.requests.last!, []); await settle(); service.endViewing()
        let empty = provider.store.requests.count
        service.beginViewing(); precondition(provider.store.requests.count == empty, "Valid empty snapshot refetched")
        // A local completion during an outstanding fetch cannot resurrect a row.
        let third = EKReminder(eventStore: provider.store)
        service.reload(); await deliver(provider.store.requests.last!, [third]); await settle()
        provider.store.lookedUp = third
        service.reload(); let beforeWrite = provider.store.requests.last!
        service.complete(service.items[0])
        precondition(service.items.isEmpty, "Local completion did not update UI immediately")
        let afterWrite = provider.store.requests.last!
        precondition(beforeWrite !== afterWrite, "Local completion did not invalidate old fetch")
        await deliver(afterWrite, []); await settle(); await deliver(beforeWrite, [third]); await settle()
        precondition(service.items.isEmpty, "Pre-write completion resurrected the completed item")
        let beforeAdd = provider.store.requests.count
        service.add(title: "Owned reminder fixture")
        precondition(provider.store.requests.count == beforeAdd + 1, "Local add did not refresh")
        await deliver(provider.store.requests.last!, [third]); await settle()
        service.endViewing(); service.shutdown()
        print("PASS: 1000 unchanged appearances reuse 1 immutable snapshot; 6 invalidation paths, visible/hidden events, explicit refresh, stale/cancelled/nil/empty fetches, local add/complete and pre-write race; no polling/timer")
    }
    private static func deliver(_ request: LegacyFetch, _ rows: [EKReminder]?) async {
        await withCheckedContinuation { continuation in request.deliver(rows) { continuation.resume() } }
    }
    private static func settle() async { try? await Task.sleep(for: .milliseconds(12)) }
}
