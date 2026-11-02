import AppKit
import ApplicationServices
import IslandCore
import SwiftUI

/// Geliştirici eşdeğerlik koşumu (OPENISLAND_DENEY_DOCKPARITY=klasör): aynı sahte Dock önizleme modelini SwiftUI
/// (`DockPreviewPanel`) ve AppKit (`DockPreviewPanelView`) panelinde yan yana gösterir; pencere numaralarını
/// `klasör/windows.txt` dosyasına yazar (ekran görüntüsü ve AX çerçeveleri dışarıdan alınır). Ada kurulmaz.
/// OPENISLAND_DENEY_DOCKPARITY_PERMISSION=1: ekran erişimi satırlı panel.
@MainActor
enum DockPreviewParityHarness {
    private static var panels: [NSPanel] = []

    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["OPENISLAND_DENEY_DOCKPARITY"] else { return false }
        let permission = env["OPENISLAND_DENEY_DOCKPARITY_PERMISSION"] == "1"
        let element = AXUIElementCreateApplication(getpid())
        let windows = [
            DockPreviewWindow(title: "Belgeler — Proje planı ve notlar", frame: CGRect(x: 0, y: 0, width: 1200, height: 800), minimized: false, element: element),
            DockPreviewWindow(title: "İndirilenler", frame: CGRect(x: 0, y: 0, width: 900, height: 600), minimized: true, element: element),
            DockPreviewWindow(title: "Ayarlar", frame: CGRect(x: 0, y: 0, width: 700, height: 500), minimized: false, element: element),
        ]
        let image = sampleImage()
        func model() -> DockPreviewModel {
            let m = DockPreviewModel()
            m.applicationName = "Finder"
            m.applicationIcon = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
            m.windows = windows
            m.needsScreenAccess = permission
            m.requestImage = { [weak m] id in
                if id == windows[0].id { m?.images[id] = image }
                if id == windows[1].id { m?.unavailable.insert(id) }
            }
            m.selectWindow = { _ in }
            m.requestPermission = {}
            return m
        }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = DockPreviewRules.panelFrame(anchor: CGRect(x: screen.midX, y: screen.minY, width: 40, height: 40), screen: screen,
                                                visibleFrame: screen, windowCount: windows.count, permissionFooter: permission)
        let size = frame.size
        let swiftUIModel = model(), appKitModel = model()
        let hosting = NSHostingView(rootView: DockPreviewPanel(model: swiftUIModel).frame(width: size.width, height: size.height))
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)
        let appKit = DockPreviewPanelView(model: appKitModel, size: size)
        var lines: [String] = []
        for (index, (name, content)) in [("sui", hosting as NSView), ("ak", appKit as NSView)].enumerated() {
            let origin = CGPoint(x: screen.minX + 80 + CGFloat(index) * (size.width + 40), y: screen.minY + 260)
            let panel = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.animationBehavior = .none
            panel.title = "Dock eşdeğerlik \(name)"
            panel.contentView = content
            panel.orderFrontRegardless()
            panels.append(panel)
            lines.append("\(name) \(panel.windowNumber)")
        }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: dir + "/windows.txt", atomically: true, encoding: .utf8)
        if let count = env["OPENISLAND_DENEY_DOCKPARITY_BENCH"].flatMap(Int.init) {
            // Gösterim maliyeti: içerik kurulur, pencereye takılır, yerleşir ve çizilir (denetleyicinin her gösterimi).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    var result: [String] = []
                    for (name, make) in [("sui", { () -> NSView in
                                             let h = NSHostingView(rootView: DockPreviewPanel(model: swiftUIModel).frame(width: size.width, height: size.height))
                                             h.sizingOptions = []; h.frame = CGRect(origin: .zero, size: size); return h }),
                                         ("ak", { () -> NSView in DockPreviewPanelView(model: appKitModel, size: size) })]
                        + [("sui2", { () -> NSView in
                                             let h = NSHostingView(rootView: DockPreviewPanel(model: swiftUIModel).frame(width: size.width, height: size.height))
                                             h.sizingOptions = []; h.frame = CGRect(origin: .zero, size: size); return h }),
                           ("ak2", { () -> NSView in DockPreviewPanelView(model: appKitModel, size: size) })] {
                        let panel = panels[name.hasPrefix("sui") ? 0 : 1]
                        let start = cpuTime()
                        for _ in 0..<count {
                            panel.contentView = make()
                            panel.contentView?.layoutSubtreeIfNeeded()
                            panel.display()
                            CATransaction.flush()
                        }
                        result.append(String(format: "%@ %.3f ms/gösterim", name, (cpuTime() - start) * 1000 / Double(count)))
                    }
                    try? (result.joined(separator: "\n") + "\n").write(toFile: dir + "/bench.txt", atomically: true, encoding: .utf8)
                }
            }
        }
        return true
    }

    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    /// Önizleme görüntüsü yerine: 320 × 200 piksel, belirgin kenarlı degrade.
    private static func sampleImage() -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: .systemBlue, ending: .systemOrange)?.draw(in: CGRect(x: 0, y: 0, width: 320, height: 200), angle: 30)
        NSColor.white.setFill()
        CGRect(x: 20, y: 20, width: 120, height: 60).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: CGSize(width: 320, height: 200))
        image.addRepresentation(rep)
        return image
    }
}
