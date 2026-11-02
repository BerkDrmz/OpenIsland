import AppKit
import IslandCore

/// README görselleri: yalıtılmış kök ve örnek verilerle (gerçek takvim, pano, not veya rafa dokunmadan) adanın sekmeleri ve
/// Ayarlar penceresi yalnız bu sürecin pencerelerinden PNG'ye alınır. Kullanım: OPENISLAND_TEST_* ortamıyla, çıktı klasörü
/// ilk argüman, isteğe bağlı ikinci argüman uygulama simgesi (App/Assets/AppIcon.icns).
@main @MainActor final class ReadmeShots: NSObject, NSApplicationDelegate {
    static var retained: ReadmeShots?
    static func main() {
        let e = ProcessInfo.processInfo.environment
        guard e["OPENISLAND_DIAGNOSTICS"] != nil, let root = e["OPENISLAND_TEST_ROOT"], root.hasPrefix("/"),
              let support = e["OPENISLAND_TEST_SUPPORT"], support.hasPrefix(root + "/"),
              e["OPENISLAND_TEST_DEFAULTS"]?.hasPrefix("io.github.openisland.") == true,
              Bundle.main.bundleIdentifier?.hasPrefix("io.github.openisland.validation.") == true,
              CommandLine.arguments.count > 1 else { exit(78) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let d = ReadmeShots(); retained = d; app.delegate = d; app.run()
    }

    func applicationDidFinishLaunching(_ note: Notification) { Task { await run() } }

    func run() async {
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let support = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPENISLAND_TEST_SUPPORT"]!)
        try? "Alışveriş: süt, ekmek\nPazartesi 10:00 toplantı notları\n• Ada için yeni simge".write(to: support.appendingPathComponent("QuickNotes.md"), atomically: true, encoding: .utf8)
        // Test ikilisi paket değil: Ayarlar başlığındaki simge uygulamanın kendi simgesinden.
        if CommandLine.arguments.count > 2 { NSApp.applicationIconImage = NSImage(contentsOfFile: CommandLine.arguments[2]) }
        let env = AppEnvironment(); env.system.privateEnabled = false
        for text in ["#F5A623", "Merhaba dünya", "https://github.com/BerkDrmz/OpenIsland"] {
            env.clipboard.copy(ClipItem(content: .text(text), date: Date(), sourceApp: "Örnek"))
        }
        let metrics = NotchMetrics(notchSize: CGSize(width: 192, height: 33.5), style: .notch, scale: 2)
        let model = IslandViewModel(metrics: metrics, configuration: .init(), hapticPerformer: { _ in })
        model.hapticsEnabled = false; model.motionStyle = .expressive
        model.send(.demoModeChanged(isOn: true))
        let window = NSPanel(contentRect: CGRect(x: 60, y: 120, width: 900, height: 420), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true; window.backgroundColor = .clear; window.isOpaque = false
        window.hasShadow = false
        let canvas = IslandCanvasView(model: model, environment: env); window.contentView = canvas
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1500))
        snap(window, out, "island-closed")
        model.send(.tapped)
        try? await Task.sleep(for: .milliseconds(1200))
        for tab in [ExpandedTab.nook, .clipboard, .notes, .focus, .system, .shelf] { // mikser çalışan uygulamaları gösterir: alınmaz
            model.send(.selectTab(tab))
            try? await Task.sleep(for: .milliseconds(tab == .system ? 2500 : 1200))
            snap(window, out, "island-\(tab.rawValue)")
        }
        model.send(.escapePressed)
        try? await Task.sleep(for: .milliseconds(800))
        window.orderOut(nil)

        let settings = SettingsWindowFactory.makeWindow(environment: env)
        settings.appearance = NSAppearance(named: .darkAqua)
        settings.setFrameOrigin(CGPoint(x: 80, y: 80)); settings.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1500))
        snap(settings, out, "settings", crop: false)
        settings.orderOut(nil)
        print("OK \(out.path)")
        exit(0)
    }

    /// Yalnız bu sürecin penceresi; saydam kenarlar kırpılır.
    func snap(_ window: NSWindow, _ out: URL, _ name: String, crop: Bool = true) {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.bestResolution, .boundsIgnoreFraming]) else {
            print("FAIL capture \(name)"); return
        }
        let final = crop ? (Self.trimmed(image) ?? image) : image
        let rep = NSBitmapImageRep(cgImage: final)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        print("shot \(name) \(final.width)x\(final.height)")
    }

    static func trimmed(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where p[(y * w + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX else { return nil }
        let pad = 24
        let rect = CGRect(x: max(0, minX - pad), y: max(0, minY - pad), width: min(w, maxX + pad) - max(0, minX - pad), height: min(h, maxY + pad) - max(0, minY - pad))
        return image.cropping(to: rect)
    }
}
