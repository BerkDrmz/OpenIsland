// Service spies for the actual NookPanelView source slice. No real reminders,
// media, camera, accessibility permissions, or user files are touched.
import AppKit
import IslandCore

@MainActor class FlippedView: NSView { override var isFlipped: Bool { true } }
@MainActor protocol IslandPanel: NSView { func didShow(); func didHide(); func prewarm() }
@MainActor final class SeparatorView: FlippedView {}
@MainActor final class IslandViewModel {}
@MainActor final class AppEnvironment {
    struct NookLayout { var showsReminders = true; var showsShortcuts = true }
    final class Preferences { var nookLayout = NookLayout() }
    final class Maintenance { func open() {} }
    let preferences = Preferences(), maintenance = Maintenance()
    let media = 0, calendar = 0, reminders = 0, launcher = 0
}
@MainActor enum Spacing { static let m: CGFloat = 12 }
@MainActor func pixelRect(_ r: CGRect) -> CGRect { r }
@MainActor enum FrameDriver { static let isLogging = false; static func note(_ s: String) {} }
@MainActor final class Observer {
    let apply: () -> Void
    init(track: @escaping () -> Void, apply: @escaping () -> Void) { self.apply = apply }
    func start() { apply() }; func stop() {}
}
@MainActor class SpyWidget: FlippedView {
    var starts = 0, stops = 0
    func didShow() { starts += 1 }; func didHide() { stops += 1 }; func prewarm() {}
}
@MainActor final class NookMediaWidgetView: SpyWidget {
    init(media: Int, model: IslandViewModel) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    var preferredWidth: CGFloat { 200 }
}
@MainActor final class NookCalendarView: SpyWidget {
    init(calendar: Int) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
}
@MainActor final class NookShortcutsView: SpyWidget {
    init(launcher: Int, openTools: @escaping () -> Void) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
}
@MainActor final class NookRemindersView: SpyWidget {
    static weak var lastCreated: NookRemindersView?
    private(set) var isViewing = false
    init(reminders: Int) { super.init(frame: .zero); Self.lastCreated = self }
    required init?(coder: NSCoder) { fatalError() }
    override func didShow() { guard !isViewing else { return }; isViewing = true; super.didShow() }
    override func didHide() { guard isViewing else { return }; isViewing = false; super.didHide() }
}
@main struct VisibilityContract {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let env = AppEnvironment()
        let panel = NookPanelView(environment: env, model: IslandViewModel())
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 220), styleMask: [], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = panel
        let reminders = NookRemindersView.lastCreated!
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        panel.layout()
        check(reminders.starts == 0, "dormant layout must not start reminders")
        panel.didShow(); panel.layout()
        check(reminders.isViewing, "visible panel starts reminders")
        panel.didHide()
        let starts = reminders.starts
        for _ in 0..<100 { panel.layout() }
        check(!reminders.isViewing && reminders.starts == starts, "100 hidden layouts must not restart reminders")
        panel.didShow(); panel.layout()
        check(reminders.isViewing, "reopen restores reminders")
        env.preferences.nookLayout.showsReminders = false; panel.layout()
        check(!reminders.isViewing, "hiding reminder widget stops it")
        env.preferences.nookLayout.showsReminders = true; panel.layout()
        check(reminders.isViewing, "showing widget while active restores it")
        panel.didHide(); w.close()
        if failures != 0 { exit(1) }
        print("PASS: dormant/visible/hidden/reopen/layout/widget transitions; 100 hidden layouts")
    }
}
