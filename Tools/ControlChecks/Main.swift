import AppKit
import CoreAudio
import Darwin
import SwiftUI

enum MotionStyle { case expressive, natural, reduced }

@main struct ControlChecks {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            await runChecks()
            application.terminate(nil)
        }
        // Global NSEvent monitors need AppKit's event pump; dispatchMain alone is insufficient.
        application.run()
    }

    @MainActor static func runChecks() async {
        checkGainBuffers()
        if #available(macOS 14.2, *) {
            for browser in ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "com.apple.Safari"] {
                precondition(DirectApplicationVolume.kind(for: browser) == nil, "Browser must use full-application Core Audio routing")
            }
            print("PASS: supported browsers use full-application routing")
        }
        let mixer = AudioMixerController()
        mixer.showPanel()
        let baseline = mixer.listenerCount
        precondition(baseline > 0, "Hardware listeners did not register")
        precondition(mixer.activeRouteCount == 0, "Opening the panel must not capture audio")
        let devices = mixer.devices.count
        let apps = mixer.applications.count
        for _ in 0..<100 { mixer.showPanel(); mixer.hidePanel(); precondition(mixer.listenerCount == baseline) }
        // Exercise the notification path without putting the user's Mac to sleep.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(150))
        precondition(mixer.listenerCount == baseline, "Wake duplicated mixer listeners")
        precondition(mixer.activeRouteCount == 0, "Wake must not capture unadjusted audio")
        mixer.hidePanel()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(150))
        precondition(mixer.listenerCount == 0, "Panel closure leaked listeners")
        precondition(mixer.activeRouteCount == 0)
        mixer.showPanel()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        mixer.hidePanel()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        mixer.showPanel()
        precondition(mixer.listenerCount == baseline, "Closing during sleep must not disable the next panel session")
        mixer.hidePanel()
        precondition(mixer.listenerCount == 0)
        let quits = QuitOnCloseService()
        quits.configure(enabled: false)
        precondition(!quits.isMonitoring)
        quits.configure(enabled: true)
        let trusted = AXIsProcessTrusted()
        if trusted, CommandLine.arguments.count > 1 {
            await checkCloseBehavior(service: quits, appURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        quits.stop()
        precondition(!quits.isMonitoring)
        var initial = rusage()
        getrusage(RUSAGE_SELF, &initial)
        try? await Task.sleep(for: .seconds(8))
        var final = rusage()
        getrusage(RUSAGE_SELF, &final)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        let cpuTime = seconds(final.ru_utime) + seconds(final.ru_stime) - seconds(initial.ru_utime) - seconds(initial.ru_stime)
        print("PASS: 100 panel open/close cycles, stable listener count (\(baseline)); all listeners removed; no audio routing in default state")
        print("PASS: \(devices) audio devices, \(apps) app rows; AX trust=\(trusted); quit monitor stops cleanly")
        print("IDLE: \(String(format: "%.3f", cpuTime)) CPU seconds over 8 seconds (\(String(format: "%.3f", cpuTime/8*100))% of one core)")
        mixer.shutdown()
        if ProcessInfo.processInfo.environment["OPENISLAND_VISUAL_CHECK"] == "1" {
            let preview = AudioMixerController()
            let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 440, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "OpenIsland Controls Preview"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AudioMixerPanel(mixer: preview, settings: {})
                .padding(20).background(.black).foregroundStyle(.white).environment(\.colorScheme, .dark))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            try! String(window.windowNumber).write(toFile: "/tmp/openisland-preview-window.txt", atomically: true, encoding: .utf8)
            try? await Task.sleep(for: .seconds(60))
            window.close()
            preview.shutdown()
        }
    }

    static func checkGainBuffers() {
        for sourceInterleaved in [true, false] {
            for destinationInterleaved in [true, false] {
                let sources = AudioBufferList.allocate(maximumBuffers: sourceInterleaved ? 1 : 2)
                let targets = AudioBufferList.allocate(maximumBuffers: destinationInterleaved ? 1 : 2)
                var allocated: [UnsafeMutablePointer<Float>] = []
                defer { allocated.forEach { $0.deallocate() }; sources.unsafeMutablePointer.deallocate(); targets.unsafeMutablePointer.deallocate() }
                for index in sources.indices {
                    let count = sourceInterleaved ? 4 : 2
                    let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
                    pointer.initialize(repeating: 0, count: count)
                    allocated.append(pointer)
                    if sourceInterleaved { for i in 0..<4 { pointer[i] = Float(i + 1) } }
                    else { pointer[0] = Float(index + 1); pointer[1] = Float(index + 3) }
                    sources[index] = AudioBuffer(mNumberChannels: sourceInterleaved ? 2 : 1, mDataByteSize: UInt32(count * 4), mData: pointer)
                }
                for index in targets.indices {
                    let count = destinationInterleaved ? 4 : 2
                    let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
                    pointer.initialize(repeating: 99, count: count)
                    allocated.append(pointer)
                    targets[index] = AudioBuffer(mNumberChannels: destinationInterleaved ? 2 : 1, mDataByteSize: UInt32(count * 4), mData: pointer)
                }
                precondition(AudioGainProcessor.containsSignal(input: sources.unsafePointer))
                for gain: Float in [0, 0.25, 0.5, 0.75, 1] {
                    AudioGainProcessor.render(input: sources.unsafePointer, output: targets.unsafeMutablePointer, from: gain, to: gain)
                    for index in targets.indices {
                        let values = targets[index].mData!.assumingMemoryBound(to: Float.self)
                        let count = destinationInterleaved ? 4 : 2
                        for sample in 0..<count {
                            let original = destinationInterleaved ? Float(sample + 1) : Float(index + 1 + sample * 2)
                            precondition(values[sample] == original * gain, "Channel mapping or gain is incorrect")
                        }
                    }
                }
                // A complete buffer may skip the initial clear, but a shorter input
                // must still leave every unfilled output sample silent.
                for index in sources.indices { sources[index].mDataByteSize /= 2 }
                for target in targets { memset(target.mData!, 0x3f, Int(target.mDataByteSize)) }
                AudioGainProcessor.render(input: sources.unsafePointer, output: targets.unsafeMutablePointer, from: 0.5, to: 0.5)
                for index in targets.indices {
                    let values = targets[index].mData!.assumingMemoryBound(to: Float.self)
                    for sample in 0..<(destinationInterleaved ? 4 : 2) {
                        let frame = destinationInterleaved ? sample / 2 : sample
                        let original = destinationInterleaved ? Float(sample + 1) : Float(index + 1 + sample * 2)
                        precondition(values[sample] == (frame == 0 ? original * 0.5 : 0), "Short input leaked stale output samples")
                    }
                }
                for index in sources.indices { sources[index].mDataByteSize *= 2 }
                AudioGainProcessor.render(input: sources.unsafePointer, output: targets.unsafeMutablePointer, from: 0, to: 1)
                for index in targets.indices {
                    let values = targets[index].mData!.assumingMemoryBound(to: Float.self)
                    for sample in 0..<(destinationInterleaved ? 4 : 2) {
                        let frame = destinationInterleaved ? sample / 2 : sample
                        let original = destinationInterleaved ? Float(sample + 1) : Float(index + 1 + sample * 2)
                        precondition(values[sample] == original * Float(frame + 1) / 2, "Gain ramp changed during optimization")
                    }
                }
                for source in sources {
                    memset(source.mData!, 0, Int(source.mDataByteSize))
                }
                precondition(!AudioGainProcessor.containsSignal(input: sources.unsafePointer), "Silent input cannot activate routing")
                sources.last!.mData!.assumingMemoryBound(to: Float.self)[0] = .nan
                precondition(!AudioGainProcessor.containsSignal(input: sources.unsafePointer), "Invalid input cannot activate routing")
            }
        }
        print("PASS: stereo channel mapping (all planar/interleaved combinations), 0/25/50/75/100% gain; short buffers clear their tails; gain ramps preserved; silence/invalid input does not activate routing")
    }

    @MainActor static func checkCloseBehavior(service: QuitOnCloseService, appURL: URL) async {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.openisland.OpenIsland").isEmpty else {
            print("SKIP: Quit OpenIsland before the red-button test; two active quit monitors would interfere")
            return
        }
        func windows(_ app: NSRunningApplication) -> [AXUIElement] {
            var value: CFTypeRef?
            let element = AXUIElementCreateApplication(app.processIdentifier)
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
            return value as? [AXUIElement] ?? []
        }
        func clickClose(_ window: AXUIElement) async {
            var buttonValue: CFTypeRef?
            precondition(AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &buttonValue) == .success)
            let button = unsafeDowncast(buttonValue!, to: AXUIElement.self)
            var value: CFTypeRef?
            precondition(AXUIElementCopyAttributeValue(button, kAXPositionAttribute as CFString, &value) == .success)
            var point = CGPoint.zero
            AXValueGetValue(unsafeDowncast(value!, to: AXValue.self), .cgPoint, &point)
            precondition(AXUIElementCopyAttributeValue(button, kAXSizeAttribute as CFString, &value) == .success)
            var size = CGSize.zero
            AXValueGetValue(unsafeDowncast(value!, to: AXValue.self), .cgSize, &size)
            point.x += size.width / 2; point.y += size.height / 2
            let source = CGEventSource(stateID: .hidSystemState)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            // Fast real clicks must work too; long down/up gaps can hide AX delivery races.
            try? await Task.sleep(for: .milliseconds(5))
            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .seconds(1))
        }
        do {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            defer { if !app.isTerminated { app.terminate() } }
            try? await Task.sleep(for: .seconds(1))
            precondition(windows(app).count == 2)
            await clickClose(windows(app)[0])
            precondition(!app.isTerminated && windows(app).count == 1, "Closing one of two windows terminated the app")
            await clickClose(windows(app)[0])
            print("CLOSE CHECK: pid=\(app.processIdentifier), windows=\(windows(app).count), requests=\(service.requestCount), terminated=\(app.isTerminated)")
            precondition(app.isTerminated && service.requestCount == 1, "Last red-button close did not terminate through the tested service")
            print("PASS: actual red-button clicks preserve another window, then terminate after last window closes")
            config.arguments = ["veto"]
            let vetoApp = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            defer { vetoApp.terminate() }
            try? await Task.sleep(for: .seconds(1))
            await clickClose(windows(vetoApp)[0])
            precondition(!vetoApp.isTerminated && windows(vetoApp).count == 2, "Cancelled close terminated an app")
            print("PASS: cancelled close leaves the application and its windows alive; normal terminate used")
            config.arguments = ["delayed"]
            let delayedApp = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            defer { if !delayedApp.isTerminated { delayedApp.terminate() } }
            try? await Task.sleep(for: .seconds(1))
            await clickClose(windows(delayedApp)[0])
            precondition(!delayedApp.isTerminated && windows(delayedApp).count == 1, "Delayed first close terminated another window")
            await clickClose(windows(delayedApp)[0])
            try? await Task.sleep(for: .milliseconds(500))
            precondition(delayedApp.isTerminated && service.requestCount == 2, "Delayed last-window close did not quit")
            print("PASS: delayed red-button close preserves another window, then quits after last window finishes closing")
            config.arguments = []
            let mixedApp = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            defer { if !mixedApp.isTerminated { mixedApp.terminate() } }
            try? await Task.sleep(for: .seconds(1))
            await clickClose(windows(mixedApp)[0])
            let last = windows(mixedApp)[0]
            var close: CFTypeRef?
            precondition(AXUIElementCopyAttributeValue(last, kAXCloseButtonAttribute as CFString, &close) == .success)
            let button = unsafeDowncast(close!, to: AXUIElement.self)
            precondition(AXUIElementPerformAction(button, kAXPressAction as CFString) == .success)
            try? await Task.sleep(for: .milliseconds(700))
            precondition(!mixedApp.isTerminated && windows(mixedApp).isEmpty && service.requestCount == 2,
                         "An old red-button gesture terminated a later programmatic close")
            print("PASS: a completed first-window red click cannot quit after a later programmatic close")
        } catch { print("Close UI check unavailable: \(error)") }
    }
}
