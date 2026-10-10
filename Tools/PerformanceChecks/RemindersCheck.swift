import AppKit
import EventKit

// Navigation is outside this check; no permission prompt or external application is opened.
@MainActor enum AppHandoff {
    static let remindersBundleID = "com.apple.reminders"
    static func open(_ url: URL?, fallbackBundleID: String? = nil) {}
    static func openApplication(bundleID: String) {}
}

@main struct RemindersCheck {
    @MainActor static func main() {
        let provider = EventStoreProvider()
        var reads = 0
        var status = EKAuthorizationStatus.notDetermined
        let reminders = RemindersService(provider: provider, readAuthorization: {
            reads += 1
            return status
        })
        precondition(reads == 1)
        for _ in 0..<1000 { reminders.beginViewing(); reminders.endViewing() }
        precondition(reads == 1, "Repeated appearances queried the daemon")
        precondition(!provider.isCreated, "Permissionless appearances created EventKit store")

        let workspace = NSWorkspace.shared.notificationCenter
        for _ in 0..<100 {
            workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        }
        precondition(reads == 1, "Hidden widget queried permission")
        status = .denied
        reminders.beginViewing()
        precondition(reads == 2 && reminders.authorization == .denied)
        reminders.beginViewing()
        precondition(reads == 2, "Overlapping visible clients duplicated authorization query")
        status = .restricted
        NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        precondition(reads == 3 && reminders.authorization == .restricted)
        reminders.endViewing()
        status = .notDetermined
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        precondition(reads == 4 && reminders.authorization == .notDetermined)
        reminders.endViewing()
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        precondition(reads == 4)
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        precondition(reads == 4, "Hidden calendar changes queried permission")
        reminders.beginViewing()
        precondition(reads == 5)
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        precondition(reads == 6, "Visible clock change did not invalidate reminders")
        reminders.endViewing()
        reminders.shutdown()
        // Shutdown must remove every retained invalidation subscription.
        reminders.beginViewing()
        for _ in 0..<100 {
            workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
            NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        }
        precondition(reads == 6, "Authorization observer survived shutdown")
        reminders.endViewing()
        precondition(!provider.isCreated)
        print("PASS Reminders: 1000 appearances / 1 permission query; hidden events coalesced; visible permission changes and wake refreshed; shutdown removed observers")
    }
}
