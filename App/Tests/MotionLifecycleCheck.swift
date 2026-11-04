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
    /// Koşul gerçekleşene kadar bekler (en çok `ms`). "X ms bekle, sonra bak" kontrolleri yükte rastgele düşüyordu;
    /// belirli bir anı sınayan kontroller (hareket ortasında katman ekleme, eski completion'ın park etmemesi) sabit kalır.
    func waitUntil(_ ms: Int, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while !condition() {
            if Date() >= end { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
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
        let offloadEnabled = ProcessInfo.processInfo.environment["OPENISLAND_APPKIT_CLIENT_TICKS"] != "1"
        _ = await waitUntil(400) { canvas.compositorOnlyMotion == offloadEnabled }
        check(canvas.compositorOnlyMotion == offloadEnabled,
              "empty-media notch opening did not select the expected frame owner")
        _ = await waitUntil(2500) { !canvas.compositorOnlyMotion }
        check(!canvas.compositorOnlyMotion, "surface completion did not release frame ownership")
        func expanded(in view: NSView) -> ExpandedContentView? {
            if let v = view as? ExpandedContentView { return v }
            return view.subviews.lazy.compactMap { expanded(in: $0) }.first
        }
        let original = expanded(in: canvas)
        check(original != nil && original?.isDormant == false, "expanded content missing or dormant after opening")
        for cycle in 0..<3 {
            model.send(.escapePressed)
            _ = await waitUntil(800) { original?.isHidden == true }
            check(original?.isHidden == true && original?.isDormant == false,
                  "outgoing host remained focusable after its fade, or suspended before the outline settled")
            _ = await waitUntil(2500) { !model.presentation.isExpanded && original?.isDormant == true }
            check(!model.presentation.isExpanded, "escape did not collapse cycle \(cycle)")
            check(canvas.spareExpanded === original, "expanded cache identity lost cycle \(cycle)")
            check(original?.window === window, "expanded cache detached from window cycle \(cycle)")
            // Boştaki ön çizim (kurulmamış paneller) uyuyan içeriği bir-iki kare görünür yapar; bu kasıtlıdır ve denetim
            // anına denk gelince test rastgele düşüyordu. Park durumu ön çizim bitince denetlenir (en çok 1 sn).
            for _ in 0..<40 where canvas.isWarmingSpare { try? await Task.sleep(for: .milliseconds(25)) }
            check(!canvas.isWarmingSpare, "spare warmup did not finish cycle \(cycle)")
            check(original?.isHidden == true && original?.isDormant == true, "parked cache is visible or active cycle \(cycle)")
            model.send(.tapped)
            _ = await waitUntil(1500) { expanded(in: canvas) === original && original?.isHidden == false && original?.isDormant == false }
            check(expanded(in: canvas) === original && original?.isHidden == false && original?.isDormant == false, "reopen lost original content or visibility cycle \(cycle)")
        }
        // Real fast-hover path: closing content is still attached when peek
        // starts the next surface spring. Its fade must reverse independently
        // instead of waiting for another surface transition that never occurs.
        var hoverConfiguration = model.machine.configuration
        hoverConfiguration.expandsOnHover = true
        hoverConfiguration.hoverExpandDelay = 0.06
        model.configure(hoverConfiguration)
        for delay in [20, 80, 120] {
            model.send(.pointerExited)
            model.send(.escapePressed)
            try? await Task.sleep(for: .milliseconds(delay))
            model.send(.pointerEntered)
            _ = await waitUntil(1200) {
                let view = expanded(in: canvas)
                return model.presentation.isExpanded && view?.isHidden == false
                    && (view?.layer?.presentation()?.opacity ?? view?.layer?.opacity ?? 0) > 0.7
            }
            check(model.presentation.isExpanded, "fast-hover reentry did not expand after \(delay) ms")
            let shown = expanded(in: canvas)
            let opacity = shown?.layer?.presentation()?.opacity ?? shown?.layer?.opacity ?? 0
            check(shown?.isHidden == false && opacity > 0.7,
                  "fast-hover reentry kept outgoing/blank content after \(delay) ms (opacity \(opacity))")
        }
        // Mid-animation overlay insertion must immediately restore the client
        // path. No warm host is discarded and no stale completion may park it.
        model.send(.pointerExited); model.send(.escapePressed)
        _ = await waitUntil(2500) { !model.presentation.isExpanded && !canvas.compositorOnlyMotion && original?.isDormant == true }
        model.send(.tapped)
        try? await Task.sleep(for: .milliseconds(90))
        let overlay = FlippedView(frame: .zero)
        canvas.presentOverlay(overlay, onCollapse: {})
        check(!canvas.compositorOnlyMotion, "overlay insertion left a moving host without client frames")
        canvas.dismissOverlay()
        try? await Task.sleep(for: .milliseconds(1000))
        check(original?.isHidden == false && original?.isDormant == false,
              "retired compositor completion parked the reopened host")
        model.send(.escapePressed)
        _ = await waitUntil(2500) { !canvas.compositorOnlyMotion && original?.isDormant == true }
        check(!canvas.compositorOnlyMotion && original?.isDormant == true,
              "completion left outgoing host active")
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
