import AppKit
import IslandCore

/// Isolated, visible AppKit lifecycle/animation checks. Does not send global
/// input, ask for permissions, capture a camera or mutate the user's stores.
@main @MainActor final class MotionLifecycleCheck: NSObject, NSApplicationDelegate {
    static var retained: MotionLifecycleCheck?
    static func main() {
        let e = ProcessInfo.processInfo.environment
        guard e["OPENISLAND_DIAGNOSTICS"] != nil,
              e["OPENISLAND_TEST_DEFAULTS"]?.hasPrefix("io.github.openisland.motion.") == true,
              let support = e["OPENISLAND_TEST_SUPPORT"], support.hasPrefix("/"), support != "/",
              !support.contains("/Library/Application Support/"),
              Bundle.main.bundleIdentifier?.hasPrefix("io.github.openisland.validation.") == true else { exit(78) }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else { exit(3) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let d = MotionLifecycleCheck(); retained = d; app.delegate = d; app.run()
    }
    var failures: [String] = [], checks = 0
    func check(_ ok: Bool, _ message: String) { checks += 1; if !ok { failures.append(message); print("FAIL: \(message)") } }
    func applicationDidFinishLaunching(_ note: Notification) { Task { await run() } }
    func run() async {
        let env = AppEnvironment(); env.system.privateEnabled = false
        let metrics = NotchMetrics(notchSize: CGSize(width: 192, height: 33.5), style: .notch)
        let model = IslandViewModel(metrics: metrics, configuration: .init(), hapticPerformer: { _ in })
        model.hapticsEnabled = false; model.motionStyle = .expressive
        let window = NSPanel(contentRect: CGRect(x: 50, y: 80, width: 800, height: 360), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true; window.backgroundColor = .clear
        let canvas = IslandCanvasView(model: model, environment: env); window.contentView = canvas
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1300))
        model.send(.tapped)
        try? await Task.sleep(for: .milliseconds(1000))
        func expanded(in view: NSView) -> ExpandedContentView? {
            if let v = view as? ExpandedContentView { return v }
            return view.subviews.lazy.compactMap { expanded(in: $0) }.first
        }
        let original = expanded(in: canvas)
        check(original != nil && original?.isDormant == false, "expanded content missing or dormant after opening")
        for cycle in 0..<3 {
            model.send(.escapePressed)
            try? await Task.sleep(for: .milliseconds(1200))
            check(!model.presentation.isExpanded, "escape did not collapse cycle \(cycle)")
            check(canvas.spareExpanded === original, "expanded cache identity lost cycle \(cycle)")
            check(original?.window === window, "expanded cache detached from window cycle \(cycle)")
            check(original?.isHidden == true && original?.isDormant == true, "parked cache is visible or active cycle \(cycle)")
            model.send(.tapped)
            try? await Task.sleep(for: .milliseconds(600))
            check(expanded(in: canvas) === original && original?.isHidden == false && original?.isDormant == false, "reopen lost original content or visibility cycle \(cycle)")
        }
        // Two genuinely different tabs with the same body geometry must still
        // animate selection feedback; equality of the surface is not a no-op.
        let wideMetrics = NotchMetrics(notchSize: CGSize(width: 320, height: 33.5), style: .notch)
        let headerModel = IslandViewModel(metrics: wideMetrics, configuration: .init(), hapticPerformer: { _ in })
        headerModel.hapticsEnabled = false; headerModel.send(.tapped)
        let header = HeaderView(model: headerModel, environment: env)
        canvas.addSubview(header); header.frame = CGRect(x: 0, y: 0, width: 800, height: 33.5)
        var pair: (ExpandedTab, ExpandedTab)?
        for a in ExpandedTab.allCases { for b in ExpandedTab.allCases where a != b {
            if IslandLayoutEngine.layout(for: .expanded(a), metrics: wideMetrics) == IslandLayoutEngine.layout(for: .expanded(b), metrics: wideMetrics) { pair = (a, b) }
        } }
        if let (a, b) = pair {
            headerModel.send(.selectTab(a)); header.refresh(); header.layoutRow(tab: a, frameWidth: 800)
            try? await Task.sleep(for: .milliseconds(800))
            headerModel.send(.selectTab(b)); header.refresh(); header.layoutRow(tab: b, frameWidth: 800)
            let capsule = header.layer?.sublayers?.first
            check(capsule?.animationKeys()?.contains(where: { $0.hasPrefix(NativeCapsuleMotion.keyPrefix) }) == true,
                  "equal-size tab selection teleported instead of animating: \(a) -> \(b)")
        } else { check(false, "no equal-size tab pair available for regression test") }
        header.removeFromSuperview(); headerModel.cancelPendingEffects(); model.cancelPendingEffects(); window.close(); env.shutdown()
        let result: [String: Any] = ["checks": checks, "failures": failures, "status": failures.isEmpty ? "PASS" : "FAIL", "scope": "Actual visible canvas lifecycle and native animation presence; not CPU/GPU or VoiceOver proof."]
        let path = CommandLine.arguments[1]
        try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        print("\(checks) checks, \(failures.count) failures")
        exit(failures.isEmpty ? 0 : 1)
    }
}
