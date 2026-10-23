import AppKit
import SwiftUI

/// Geliştirici eşdeğerlik koşumu (OPENISLAND_DENEY_TOOLSPARITY=klasör): Araçlar penceresini açar, istenen bölüme geçer
/// (OPENISLAND_DENEY_TOOLSPARITY_SECTION=uninstaller|cleaner|updater) ve pencere numaralarını `klasör/windows.txt`
/// dosyasına yazar. Uygulama listesi yalnız okunur; hiçbir dosya taşınmaz. Ada kurulmaz.
@MainActor
enum ToolsParityHarness {
    private static var retained: NSWindow?
    static func runIfRequested(_ environment: AppEnvironment) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["OPENISLAND_DENEY_TOOLSPARITY"] else { return false }
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
        switch env["OPENISLAND_DENEY_TOOLSPARITY_SECTION"] {
        case "cleaner": controller.select(.cleaner)
        case "updater": controller.select(.updater)
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                let windows = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("OpenIslandMaintenance") == true }
                let lines = windows.map { "\($0.identifier!.rawValue) \($0.windowNumber)" }
                try? (lines.joined(separator: "\n") + "\n").write(toFile: dir + "/windows.txt", atomically: true, encoding: .utf8)
            }
        }
        return true
    }
}
