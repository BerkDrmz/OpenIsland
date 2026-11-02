import AppKit
import SwiftUI

/// Geliştirici eşdeğerlik koşumu (OPENISLAND_APPKIT_TOOLSPARITY=klasör): Araçlar penceresini açar, istenen bölüme geçer
/// (OPENISLAND_APPKIT_TOOLSPARITY_SECTION=uninstaller|cleaner) ve pencere numaralarını `klasör/windows.txt`
/// dosyasına yazar. Uygulama listesi yalnız okunur; hiçbir dosya taşınmaz. Ada kurulmaz.
@MainActor
enum ToolsParityHarness {
    private static var retained: NSWindow?

    static func runIfRequested(_ environment: AppEnvironment) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["OPENISLAND_APPKIT_TOOLSPARITY"] else { return false }
        let controller = environment.maintenance
        controller.open()
        // Karşılaştırma: aynı denetleyiciye bağlı SwiftUI penceresi, AppKit penceresinin aynı boyutunda.
        if let appKitWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "OpenIslandMaintenance" }) {
            appKitWindow.identifier = NSUserInterfaceItemIdentifier("OpenIslandMaintenance-ak")
            let window = NSWindow(contentRect: appKitWindow.contentRect(forFrameRect: appKitWindow.frame),
                                  styleMask: appKitWindow.styleMask, backing: .buffered, defer: false)
            window.title = appKitWindow.title
            window.identifier = NSUserInterfaceItemIdentifier("OpenIslandMaintenance-sui")
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: MaintenanceView(controller: controller))
            hosting.sizingOptions = []
            window.contentView = hosting
            window.setContentSize(appKitWindow.contentRect(forFrameRect: appKitWindow.frame).size)
            window.setFrameOrigin(CGPoint(x: appKitWindow.frame.minX + 40, y: appKitWindow.frame.minY - 40))
            window.orderFrontRegardless()
            retained = window
        }
        switch env["OPENISLAND_APPKIT_TOOLSPARITY_SECTION"] {
        case "cleaner": controller.select(.cleaner)
        default: break
        }
        if env["OPENISLAND_APPKIT_TOOLSPARITY_SCAN"] == "1" {
            // Salt okunur tarama (önbellek ya da seçili uygulamanın kalıntıları); hiçbir dosya taşınmaz.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { controller.scan() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                let windows = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("OpenIslandMaintenance") == true }
                let lines = windows.map { "\($0.identifier!.rawValue) \($0.windowNumber)" }
                try? (lines.joined(separator: "\n") + "\n").write(toFile: dir + "/windows.txt", atomically: true, encoding: .utf8)
            }
        }
        if let count = env["OPENISLAND_APPKIT_TOOLSPARITY_BENCH"].flatMap(Int.init) {
            // GCD bloğu değil çalışma döngüsü zamanlayıcısı: iç içe döngüde ana kuyruk (gözlem güncellemeleri) işlenebilsin.
            Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
                MainActor.assumeIsolated { bench(count, controller: controller, dir: dir) }
            }
        }
        return true
    }

    /// İşlemci süresi (A/B/B/A): içeriğin kurulup yerleşip çizilmesi ve — yalnız ölçülen görünüm bağlıyken — bölüm
    /// değiştirme (gözlem → güncelleme → çizim). `klasör/bench.txt`.
    private static func bench(_ count: Int, controller: MaintenanceController, dir: String) {
        guard let ak = NSApp.windows.first(where: { $0.identifier?.rawValue == "OpenIslandMaintenance-ak" }),
              let sui = NSApp.windows.first(where: { $0.identifier?.rawValue == "OpenIslandMaintenance-sui" }) else { return }
        func make(_ name: String) -> NSView {
            if name == "sui" {
                let hosting = NSHostingView(rootView: MaintenanceView(controller: controller))
                hosting.sizingOptions = []
                return hosting
            }
            return MaintenanceWindowView(controller: controller)
        }
        func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        var result: [String] = []
        // Profil kaydı için: yalnız AppKit bölüm değiştirme, OPENISLAND_APPKIT_TOOLSPARITY_PROFILE saniye boyunca.
        if let seconds = ProcessInfo.processInfo.environment["OPENISLAND_APPKIT_TOOLSPARITY_PROFILE"].flatMap(Double.init) {
            sui.contentView = NSView()
            ak.contentView = make("ak")
            let sections: [MaintenanceController.Section] = [.cleaner, .uninstaller]
            let end = Date().addingTimeInterval(seconds)
            var index = 0
            while Date() < end {
                controller.select(sections[index % sections.count])
                index += 1
                spin(0.02)
                ak.displayIfNeeded()
                CATransaction.flush()
            }
            try? "profil \(index)\n".write(toFile: dir + "/bench.txt", atomically: true, encoding: .utf8)
            return
        }
        for name in ["sui", "ak", "ak", "sui"] {
            let window = name == "sui" ? sui : ak
            let start = cpuTime()
            for _ in 0..<count {
                window.contentView = make(name)
                window.contentView?.layoutSubtreeIfNeeded()
                window.display()
                CATransaction.flush()
            }
            result.append(String(format: "açılış %@ %.3f ms", name, (cpuTime() - start) * 1000 / Double(count)))
        }
        let sections: [MaintenanceController.Section] = [.cleaner, .uninstaller]
        for name in ["sui", "ak", "ak", "sui"] {
            let (window, other) = name == "sui" ? (sui, ak) : (ak, sui)
            other.contentView = NSView()
            window.contentView = make(name)
            spin(0.3)
            // Doğrulama: her adımdan sonra pencerede görünen 17 pt başlık seçilen bölüm mü?
            func title(_ view: NSView) -> String? {
                if let label = view as? TextLabel, label.font.pointSize == 17 { return label.stringValue }
                return view.subviews.lazy.compactMap(title).first
            }
            var correct = 0
            var checked: Double = 0
            var perSection: [MaintenanceController.Section: Double] = [:]
            let start = cpuTime()
            for index in 0..<(count * sections.count) {
                let sectionStart = cpuTime()
                controller.select(sections[index % sections.count])
                spin(0.02)
                window.displayIfNeeded()
                CATransaction.flush()
                perSection[sections[index % sections.count], default: 0] += cpuTime() - sectionStart
                if name == "ak" {
                    let c = cpuTime()
                    if title(window.contentView!) == controller.section.rawValue { correct += 1 }
                    checked += cpuTime() - c
                }
            }
            let elapsed = (cpuTime() - start - checked) * 1000 / Double(count * sections.count)
            // Taban: aynı döngü, bölüm değişmeden (yalnız çalışma döngüsü + çizim denetimi).
            let idleStart = cpuTime()
            for _ in 0..<(count * sections.count) {
                spin(0.02)
                window.displayIfNeeded()
                CATransaction.flush()
            }
            let idle = (cpuTime() - idleStart) * 1000 / Double(count * sections.count)
            let shown = name == "ak" ? "\(correct)/\(count * sections.count)" : "-"
            result.append(String(format: "bölüm %@ %.3f ms (taban %.3f ms, başlık %@)", name, elapsed, idle, shown))
            result.append("   " + sections.map { String(format: "%@ %.1f ms", $0.rawValue, (perSection[$0] ?? 0) * 1000 / Double(count)) }.joined(separator: " · "))
        }
        try? (result.joined(separator: "\n") + "\n").write(toFile: dir + "/bench.txt", atomically: true, encoding: .utf8)
    }

    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
