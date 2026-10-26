import AppKit
import QuartzCore

/// Native layer lifetime checks, NOT a frame-rate, energy or visual-parity test.
/// Test-only sleeps do not participate in the application implementation.
@main @MainActor final class NativeCapsuleLifecycleCheck: NSObject, NSApplicationDelegate {
    static var retained: NativeCapsuleLifecycleCheck?
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = NativeCapsuleLifecycleCheck()
        retained = delegate
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await run() }
    }

    func run() async {
        var checks = 0
        var failures: [String] = []
        var phases: [[String: Any]] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        guard !locked else {
            let result: [String: Any] = ["status": "NOT_TESTED", "sessionLocked": true,
                "reason": "Core Animation retirement requires an active rendering session. A locked session cannot validate visible animation completion."]
            let path = CommandLine.arguments.dropFirst().first!
            try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            print("NOT_TESTED: session locked; no owned window or animation created")
            exit(3)
        }
        let window = NSPanel(contentRect: CGRect(x: 40, y: 70, width: 470, height: 38),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 470, height: 38))
        view.wantsLayer = true
        window.contentView = view
        let layer = CALayer()
        layer.backgroundColor = NSColor.white.cgColor
        view.layer!.addSublayer(layer)
        // A normal, nonactivating owned window; never above the security screen.
        window.orderFrontRegardless()
        let foreign = CABasicAnimation(keyPath: "opacity")
        foreign.fromValue = 1; foreign.toValue = 1; foreign.duration = 100
        layer.add(foreign, forKey: "fixture.foreign")
        for (name, spec) in [("natural", DeneyMotion.naturalResize), ("expressive", DeneyMotion.livelyResize), ("reduced", DeneyMotion.reduced)] {
            var driver: NativeCapsuleMotion? = NativeCapsuleMotion(layer: layer)
            weak var retired = driver
            driver!.move(to: CGRect(x: 0, y: 4, width: 14, height: 24), spec: nil)
            var maxCount = 0
            var longest = 0.0
            for selection in 0..<100 {
                let x = [350.0, 73, 201, 410, 65, 7][selection % 6]
                driver!.move(to: CGRect(x: x - 7, y: 4, width: 14, height: 24), spec: spec)
                let keys = (layer.animationKeys() ?? []).filter { $0.hasPrefix(NativeCapsuleMotion.keyPrefix) }
                maxCount = max(maxCount, keys.count)
                check(!keys.isEmpty, "\(name): missing native response at selection \(selection)")
                check(layer.position.x == x, "\(name): last target lost")
                for key in keys {
                    guard let spring = layer.animation(forKey: key) as? CASpringAnimation else {
                        check(false, "\(name): response is not CASpringAnimation"); continue
                    }
                    longest = max(longest, spring.duration)
                    check(spring.isAdditive && spring.isRemovedOnCompletion, "\(name): response lifecycle flags")
                }
                // Repeated layout must not cancel/restart an in-flight response.
                driver!.move(to: CGRect(x: x - 7, y: 4, width: 14, height: 24), spec: spec)
                check(keys == (layer.animationKeys() ?? []).filter { $0.hasPrefix(NativeCapsuleMotion.keyPrefix) },
                      "\(name): identical layout restarted animations")
                try? await Task.sleep(for: .milliseconds(50))
            }
            check(maxCount <= Int(ceil(longest / 0.05)) + 2, "\(name): native responses accumulate beyond lifetime bound")
            try? await Task.sleep(for: .seconds(longest + 0.15))
            check((layer.animationKeys() ?? []).allSatisfy { !$0.hasPrefix(NativeCapsuleMotion.keyPrefix) },
                  "\(name): native responses did not retire")
            check(layer.animation(forKey: "fixture.foreign") != nil, "\(name): removed an unrelated animation")
            driver = nil
            check(retired == nil, "\(name): motion owner retained after release")
            phases.append(["style": name, "selections": 100, "maxActiveAnimations": maxCount, "longestResponseSeconds": longest])
        }
        window.close()
        let result: [String: Any] = ["checks": checks, "failures": failures, "phases": phases,
                                     "sessionLocked": locked, "status": failures.isEmpty ? "PASS" : "FAIL",
                                     "scope": "Native animation removal, bounded lifetime and owner release only. NOT visible frames, CPU or battery proof."]
        let path = CommandLine.arguments.dropFirst().first!
        try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        print("Lifecycle contracts \(checks), failures \(failures.count)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
