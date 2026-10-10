import AppKit
import IslandCore
import ServiceManagement

enum AppPaths { static let isRunningAsBundle = false }
enum LifecycleLog { static func note(_ message: String) {} }

@main struct PreferencesCheck {
    @MainActor static func main() {
        let suite = "OpenIsland.PreferencesCheck.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var login: SMAppService.Status = .enabled
        var registrations = 0
        var failRegistration = false
        let preferences = Preferences(defaults: defaults, loginStatus: { login }, setLoginRegistration: { enabled in
            registrations += 1
            if failRegistration { throw NSError(domain: "test", code: 1) }
            login = enabled ? .enabled : .notRegistered
        })
        var calls = 0
        preferences.onChange = { calls += 1 }
        preferences.hoverPreset = .off
        preferences.hoverPreset = .quick
        precondition(calls == 2 && preferences.islandConfiguration.expandsOnHover && preferences.hoverDelay == 0.06,
                     "A hover preset must apply one complete configuration")
        preferences.hoverPreset = .quick
        precondition(calls == 2, "Unchanged keys must not reapply preferences")
        let keys: [WritableKeyPath<Preferences, Bool>] = [\.hapticsEnabled, \.energySaving, \.albumColoredPulse,
            \.batteryNotices, \.networkNotices, \.displayNotices, \.audioDeviceNotices, \.trackChangeNotices,
            \.meetingReminders, \.globalHotKey, \.unlockNotices, \.clipboardHistoryEnabled, \.gesturesEnabled,
            \.transferActivity, \.focusModule, \.notesModule, \.mirrorModule]
        var ref = preferences
        for key in keys {
            let prior = calls
            ref[keyPath: key].toggle()
            precondition(calls == prior + 1)
        }
        preferences.expandedSurfaceSize = .standard
        preferences.motionStyle = .natural
        preferences.displayTarget = .allDisplays
        preferences.fullscreenBehavior = .alwaysShow
        let restored = Preferences(defaults: defaults)
        for key in keys { precondition(restored[keyPath: key] == preferences[keyPath: key]) }
        precondition(restored.expandedSurfaceSize == .standard && restored.motionStyle == .natural && restored.displayTarget == .allDisplays && restored.fullscreenBehavior == .alwaysShow)
        for _ in 0..<100 { preferences.refreshLaunchAtLogin(); preferences.launchAtLogin = true }
        precondition(registrations == 0, "Displaying an enabled login setting must not register again")
        preferences.launchAtLogin = false
        precondition(!preferences.launchAtLogin && registrations == 1)
        failRegistration = true
        preferences.launchAtLogin = true
        precondition(!preferences.launchAtLogin && preferences.launchAtLoginError != nil,
                     "A failed registration must preserve the actual switch state and expose an error")
        login = .requiresApproval
        preferences.refreshLaunchAtLogin()
        precondition(preferences.launchAtLogin && preferences.launchAtLoginStatus == .requiresApproval)
        login = .notRegistered
        preferences.refreshLaunchAtLogin()
        precondition(!preferences.launchAtLogin)
        print("PASS Preferences: all persisted controls survive reload; hover publishes once; unchanged keys do no work; login status refresh, approval and failures reflect reality")
    }
}
