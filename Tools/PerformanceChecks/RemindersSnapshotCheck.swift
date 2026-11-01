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
// The service starts and cancels fetches on its own serial queue, so the fixture guards its bookkeeping.
final class EKEventStore: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [LegacyFetch] = []
    private var cancelled = 0
    fileprivate var requests: [LegacyFetch] { lock.withLock { started } }
    var cancellations: Int { lock.withLock { cancelled } }
    func predicateForIncompleteReminders(withDueDateStarting: Date?, ending: Date?, calendars: [EKCalendar]?) -> NSPredicate { NSPredicate(value: true) }
    func fetchReminders(matching: NSPredicate, completion: @escaping ([EKReminder]?) -> Void) -> Any {
        precondition(!Thread.isMainThread, "fetchReminders ran on the main thread")
        return lock.withLock { started.append(LegacyFetch(completion)); return started.count }
    }
    func cancelFetchRequest(_ token: Any) { lock.withLock { cancelled += 1 } }
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
        let store = provider.store
        let service = RemindersService(provider: provider, readAuthorization: { .fullAccess })
        service.beginViewing()
        let first = EKReminder(eventStore: store)
        await deliver(await started(store, 1), [first])
        await settle()
        precondition(service.items.map(\.id) == [first.calendarItemIdentifier])
        service.endViewing()
        let warmed = store.requests.count
        for _ in 0..<1000 {
            service.beginViewing(); precondition(service.items.map(\.id) == [first.calendarItemIdentifier]); service.endViewing()
        }
        await settle()
        precondition(store.requests.count == warmed, "Unchanged appearances fetched again")
        // All old invalidation events still force fresh data; hidden events do not query.
        for (center, name) in [(NotificationCenter.default, Notification.Name.EKEventStoreChanged),
                               (NotificationCenter.default, Notification.Name.NSCalendarDayChanged),
                               (NotificationCenter.default, Notification.Name.NSSystemTimeZoneDidChange),
                               (NotificationCenter.default, Notification.Name.NSSystemClockDidChange),
                               (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
                               (NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification)] {
            let before = store.requests.count
            center.post(name: name, object: nil)
            await settle()
            precondition(store.requests.count == before, "Hidden event fetched")
            service.beginViewing()
            let fresh = await started(store, before + 1)
            precondition(store.requests.count == before + 1, "Invalidation missed on reopen")
            await deliver(fresh, [first]); await settle(); service.endViewing()
        }
        // Visible invalidation and explicit reload are never suppressed by the snapshot.
        service.beginViewing(); await settle(); let before = store.requests.count
        NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        let stale = await started(store, before + 1)
        service.reload(); let current = await started(store, before + 2)
        let second = EKReminder(eventStore: store)
        await deliver(current, [second]); await settle(); await deliver(stale, [first]); await settle()
        precondition(service.items.map(\.id) == [second.calendarItemIdentifier], "Stale completion overwrote snapshot")
        service.endViewing(); let known = store.requests.count
        service.beginViewing(); service.endViewing(); await settle(); precondition(store.requests.count == known)
        // A cancelled or nil fetch is NOT a current snapshot; retry immediately on demand.
        service.beginViewing(); service.reload(); let cancelled = await started(store, known + 1)
        service.endViewing(); service.beginViewing(); let retry = await started(store, known + 2)
        precondition(store.requests.count == known + 2)
        await deliver(cancelled, [first]); await settle()
        precondition(service.items.map(\.id) == [second.calendarItemIdentifier])
        await deliver(retry, nil); await settle(); service.endViewing()
        let failed = store.requests.count
        service.beginViewing(); await deliver(await started(store, failed + 1), []); await settle(); service.endViewing()
        let empty = store.requests.count
        service.beginViewing(); await settle(); precondition(store.requests.count == empty, "Valid empty snapshot refetched")
        // A local completion during an outstanding fetch cannot resurrect a row.
        let third = EKReminder(eventStore: store)
        service.reload(); await deliver(await started(store, empty + 1), [third]); await settle()
        store.lookedUp = third
        service.reload(); let beforeWrite = await started(store, empty + 2)
        service.complete(service.items[0])
        precondition(service.items.isEmpty, "Local completion did not update UI immediately")
        let afterWrite = await started(store, empty + 3)
        precondition(beforeWrite !== afterWrite, "Local completion did not invalidate old fetch")
        await deliver(afterWrite, []); await settle(); await deliver(beforeWrite, [third]); await settle()
        precondition(service.items.isEmpty, "Pre-write completion resurrected the completed item")
        let beforeAdd = store.requests.count
        service.add(title: "Owned reminder fixture")
        await deliver(await started(store, beforeAdd + 1), [third]); await settle()
        precondition(store.requests.count == beforeAdd + 1, "Local add did not refresh")
        service.endViewing(); service.shutdown()
        print("PASS: 1000 unchanged appearances reuse 1 immutable snapshot; 6 invalidation paths, visible/hidden events, explicit refresh, stale/cancelled/nil/empty fetches started off main, local add/complete and pre-write race; no polling/timer")
    }
    private static func deliver(_ request: LegacyFetch, _ rows: [EKReminder]?) async {
        await withCheckedContinuation { continuation in request.deliver(rows) { continuation.resume() } }
    }
    /// Waits until the service has started the `count`th fetch off main and returns it.
    @MainActor private static func started(_ store: EKEventStore, _ count: Int) async -> LegacyFetch {
        for _ in 0..<500 where store.requests.count < count { try? await Task.sleep(for: .milliseconds(2)) }
        await settle()
        precondition(store.requests.count >= count, "Fetch \(count) never started")
        return store.requests[count - 1]
    }
    private static func settle() async { try? await Task.sleep(for: .milliseconds(12)) }
}
