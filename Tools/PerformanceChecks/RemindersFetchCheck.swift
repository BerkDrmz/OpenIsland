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
private final class LegacyFetch: @unchecked Sendable {
    let callback: ([EKReminder]?) -> Void
    init(_ callback: @escaping ([EKReminder]?) -> Void) { self.callback = callback }
    func deliver(_ rows: [EKReminder], completion: @escaping @Sendable () -> Void) {
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
    func calendarItem(withIdentifier: String) -> Any? { nil }
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

@main struct RemindersFetchCheck {
    @MainActor static func main() async {
        let provider = EventStoreProvider()
        var service: RemindersService? = RemindersService(provider: provider, readAuthorization: { .fullAccess })
        weak let weakService = service
        service!.beginViewing()
        await waitFor { provider.store.requests.count == 1 }
        let first = EKReminder(eventStore: provider.store)
        await deliver(provider.store.requests[0], [first])
        for _ in 0..<100 where service!.items.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
        precondition(service!.items.map(\.id) == [first.calendarItemIdentifier], "Background fetch did not publish on MainActor")
        service!.reload()
        await waitFor { provider.store.requests.count == 2 }
        let retired = provider.store.requests.last!
        service!.reload()
        await waitFor { provider.store.requests.count == 3 }
        let current = provider.store.requests.last!
        let second = EKReminder(eventStore: provider.store)
        await deliver(current, [second])
        for _ in 0..<100 where service!.items.first?.id != second.calendarItemIdentifier { try? await Task.sleep(for: .milliseconds(2)) }
        await deliver(retired, [first])
        try? await Task.sleep(for: .milliseconds(10))
        precondition(service!.items.map(\.id) == [second.calendarItemIdentifier], "Retired completion overwrote current items")
        for _ in 0..<100 { service!.reload() }
        await waitFor { provider.store.requests.count == 103 }
        try? await Task.sleep(for: .milliseconds(20))
        let afterShutdown = provider.store.requests.last!
        service!.shutdown()
        await deliver(afterShutdown, [first])
        try? await Task.sleep(for: .milliseconds(10))
        precondition(service!.items.map(\.id) == [second.calendarItemIdentifier], "Shutdown completion published")
        service = nil
        precondition(weakService == nil, "Legacy callbacks retained the service after shutdown")
        await waitFor { provider.store.cancellations >= 100 }
        precondition(provider.store.cancellations >= 100, "Superseded fetches were not cancelled")
        print("PASS Reminders legacy callback: fetch started off main; real mapping/sort on background queue; current/stale/shutdown publication, 100 cancellations and weak-owner release")
    }
    @MainActor private static func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
    }
    private static func deliver(_ request: LegacyFetch, _ rows: [EKReminder]) async {
        await withCheckedContinuation { continuation in request.deliver(rows) { continuation.resume() } }
    }
}
