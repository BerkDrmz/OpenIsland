import AppKit
import EventKit

@MainActor enum AppHandoff {
    static let calendarBundleID = "com.apple.iCal"
    static func open(_ url: URL?, fallbackBundleID: String? = nil) {}
    static func openApplication(bundleID: String) {}
}

@main struct CalendarCheck {
    @MainActor static func main() {
        let provider = EventStoreProvider()
        var reads = 0
        var status = EKAuthorizationStatus.notDetermined
        var now = Date()
        let service = CalendarService(provider: provider, readAuthorization: {
            reads += 1
            return status
        }, currentDate: { now })
        service.start()
        let initialReads = reads
        for _ in 0..<1000 { service.start(); service.showDay(offset: 1); service.reload() }
        precondition(reads == initialReads, "Repeated starts or UI appearances queried permission")
        precondition(!provider.isCreated, "Day selection queried EventKit without permission")
        status = .denied
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        precondition(service.authorization == .denied)
        status = .restricted
        NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        precondition(service.authorization == .restricted)
        now = now.addingTimeInterval(2 * 86400)
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        precondition(service.today == Calendar.current.startOfDay(for: now), "Calendar kept yesterday after midnight")
        status = .notDetermined
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        precondition(service.authorization == .notDetermined)
        service.stop()
        let stoppedReads = reads
        for _ in 0..<1000 {
            service.includesAllDayEvents.toggle()
            service.showDay(offset: 0)
            NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        }
        precondition(reads == stoppedReads && !provider.isCreated, "Stopped calendar retained observers or queried store")
        service.start()
        precondition(reads == stoppedReads + 1)
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        precondition(reads == stoppedReads + 2, "Restart duplicated observer")
        service.stop()
        print("PASS Calendar: 1000 starts/day selections without unauthorized store creation; permission/day/wake refresh; 1000 stopped events inert; restart has one observer per event")
    }
}
