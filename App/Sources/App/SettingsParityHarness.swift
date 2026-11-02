import AppKit
import SwiftUI

/// Geliştirici eşdeğerlik koşumu (OPENISLAND_APPKIT_SETTINGSPARITY=klasör): Ayarlar penceresinin SwiftUI
/// (`SettingsView`) ve AppKit sürümünü aynı ortamla (test tercih alanı) yan yana açar; pencere numaralarını
/// `klasör/windows.txt` dosyasına yazar. Ada kurulmaz. Sekme dışarıdan (AX) seçilir.
@MainActor
enum SettingsParityHarness {
    private static var windows: [NSWindow] = []

    static func runIfRequested(_ environment: AppEnvironment) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["OPENISLAND_APPKIT_SETTINGSPARITY"] else { return false }
        if let mode = env["OPENISLAND_APPKIT_SETTINGSPARITY_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        }
        if env["OPENISLAND_APPKIT_SETTINGSPARITY_SWATCH"] == "1" { swatches(dir) }
        let hosting = NSHostingController(rootView: SettingsView(environment: environment))
        let sui = NSWindow(contentViewController: hosting)
        sui.styleMask = [.titled, .closable, .miniaturizable]
        sui.identifier = NSUserInterfaceItemIdentifier("OpenIslandSettings-sui")
        var made = [("OpenIslandSettings-sui", sui)]
        if let make = appKitWindow {
            let ak = make(environment)
            ak.identifier = NSUserInterfaceItemIdentifier("OpenIslandSettings-ak")
            made.append(("OpenIslandSettings-ak", ak))
        }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // _ONLY=sui|ak: yalnız biri, ilk konumda (duvar kâğıdı tonu konuma bağlı; karşılaştırma için sırayla aynı yerde).
        if let only = env["OPENISLAND_APPKIT_SETTINGSPARITY_ONLY"] { made = made.filter { $0.0.hasSuffix(only) } }
        for (index, (_, window)) in made.enumerated() {
            window.title = "OpenIsland Ayarları"
            window.isReleasedWhenClosed = false
            window.setFrameTopLeftPoint(CGPoint(x: screen.minX + 40 + CGFloat(index) * (window.frame.width + 30), y: screen.maxY - 20))
            window.orderFrontRegardless()
            windows.append(window)
        }
        if let count = env["OPENISLAND_APPKIT_SETTINGSPARITY_BENCH"].flatMap(Int.init), let ak = made.last?.1, ak !== sui {
            // GCD bloğu değil çalışma döngüsü zamanlayıcısı: iç içe döngüde ana kuyruk (gözlem güncellemeleri) işlenebilsin.
            Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
                MainActor.assumeIsolated { bench(count, environment: environment, sui: sui, ak: ak, dir: dir) }
            }
        }
        let dumpDelay = env["OPENISLAND_APPKIT_SETTINGSPARITY_DUMPDELAY"].flatMap(Double.init) ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + dumpDelay) {
            MainActor.assumeIsolated {
                // Görünüm ağacı dökümü (sınıf, çerçeve, katman rengi/köşe/kenarlık, malzeme): `klasör/tree.txt`
                var out: [String] = []
                @MainActor func walk(_ v: NSView, _ d: Int) {
                    guard d < 14 else { return }
                    var extra = ""
                    if let e = v as? NSVisualEffectView { extra += " material=\(e.material.rawValue) blend=\(e.blendingMode.rawValue) state=\(e.state.rawValue)" }
                    if let t = v as? NSTabView { extra += " tabType=\(t.tabViewType.rawValue) draws=\(t.drawsBackground)" }
                    if let sc = v as? NSScrollView { extra += " draws=\(sc.drawsBackground) bg=\(sc.backgroundColor)" }
                    func rgba(_ c: CGColor) -> String { (c.converted(to: CGColorSpace(name: CGColorSpace.extendedSRGB)!, intent: .defaultIntent, options: nil)?.components ?? []).map { String(format: "%.4f", $0) }.joined(separator: ",") }
                    if let l = v.layer {
                        if let c = l.backgroundColor { extra += " bg=(\(rgba(c)))" }
                        if l.cornerRadius > 0 { extra += " r=\(l.cornerRadius) curve=\(l.cornerCurve.rawValue)" }
                        if l.borderWidth > 0, let c = l.borderColor { extra += " border=\(l.borderWidth)(\(rgba(c)))" }
                        if l.opacity < 1 { extra += " op=\(l.opacity) layer=\(type(of: l))" }
                        if l.masksToBounds { extra += " mask" }
                        if let m = l.mask { extra += " maskLayer=\(type(of: m))" }
                        for sub in l.sublayers ?? [] where !(sub.delegate is NSView) {
                            var e2 = "  ·\(type(of: sub)) \(sub.frame)"
                            if let c = sub.backgroundColor { e2 += " bg=(\(rgba(c)))" }
                            if sub.cornerRadius > 0 { e2 += " r=\(sub.cornerRadius)" }
                            if sub.borderWidth > 0, let c = sub.borderColor { e2 += " border=\(sub.borderWidth)(\(rgba(c)))" }
                            if let sh = sub as? CAShapeLayer, let f = sh.fillColor { e2 += " fill=(\(rgba(f)))" }
                            out.append(String(repeating: " ", count: d + 1) + e2)
                        }
                    }
                    out.insert(String(repeating: " ", count: d) + "\(type(of: v)) \(v.frame)" + extra, at: out.count - (v.layer?.sublayers?.filter { !($0.delegate is NSView) }.count ?? 0))
                    v.subviews.forEach { walk($0, d + 1) }
                }
                if let root = sui.contentView?.superview { walk(root, 0) }
                if let ak = made.last?.1, ak !== sui, let root = ak.contentView?.superview { out.append("==== AK"); walk(root, 0) }
                try? out.joined(separator: "\n").write(toFile: dir + "/tree.txt", atomically: true, encoding: .utf8)
                let lines = made.map { "\($0.0) \($0.1.windowNumber)" }
                try? (lines.joined(separator: "\n") + "\n").write(toFile: dir + "/windows.txt", atomically: true, encoding: .utf8)
            }
        }
        return true
    }

    /// İşlemci süresi (A/B/B/A, `klasör/bench.txt`): içeriği kur-yerleştir-çiz; sekme geçişi; tercih değişince
    /// güncelleme (Genel sekmesi açıkken bir anahtar). Ölçülen sırada yalnız bir görünüm bağlı.
    private static func bench(_ count: Int, environment: AppEnvironment, sui: NSWindow, ak: NSWindow, dir: String) {
        func make(_ name: String) -> NSView {
            if name == "sui" {
                let hosting = NSHostingView(rootView: SettingsView(environment: environment))
                hosting.frame = CGRect(x: 0, y: 0, width: 560, height: 600)
                return hosting
            }
            return SettingsRootView(environment: environment)
        }
        func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func tabView(_ view: NSView) -> NSTabView? { (view as? NSTabView) ?? view.subviews.lazy.compactMap(tabView).first }
        var result: [String] = []
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
        for name in ["sui", "ak", "ak", "sui"] {
            let (window, other) = name == "sui" ? (sui, ak) : (ak, sui)
            other.contentView = NSView()
            window.contentView = make(name)
            spin(0.3)
            guard let tabs = tabView(window.contentView!) else { continue }
            let start = cpuTime()
            for index in 0..<(count * 3) {
                tabs.selectTabViewItem(at: (index + 1) % 3)
                spin(0.02)
                window.displayIfNeeded()
                CATransaction.flush()
            }
            result.append(String(format: "sekme %@ %.3f ms", name, (cpuTime() - start) * 1000 / Double(count * 3)))
        }
        let p = environment.preferences
        let original = p.hapticsEnabled
        for name in ["sui", "ak", "ak", "sui"] {
            let (window, other) = name == "sui" ? (sui, ak) : (ak, sui)
            other.contentView = NSView()
            window.contentView = make(name)
            tabView(window.contentView!)?.selectTabViewItem(at: 0)
            spin(0.3)
            let start = cpuTime()
            for _ in 0..<(count * 3) {
                p.hapticsEnabled.toggle()
                spin(0.02)
                window.displayIfNeeded()
                CATransaction.flush()
            }
            result.append(String(format: "tercih %@ %.3f ms", name, (cpuTime() - start) * 1000 / Double(count * 3)))
        }
        p.hapticsEnabled = original
        try? (result.joined(separator: "\n") + "\n").write(toFile: dir + "/bench.txt", atomically: true, encoding: .utf8)
    }

    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    /// Renk örnekleri (OPENISLAND_APPKIT_SETTINGSPARITY_SWATCH=1): aday sistem renkleri pencere zemininde 40 × 40 pt kareler; ad ve sıra
    /// `klasör/swatches.txt`.
    private static func swatches(_ dir: String) {
        let colors: [(String, NSColor)] = [
            ("windowBackground", .windowBackgroundColor), ("controlBackground", .controlBackgroundColor),
            ("underPage", .underPageBackgroundColor), ("textBackground", .textBackgroundColor),
            ("quaternarySystemFill", .quaternarySystemFill), ("tertiarySystemFill", .tertiarySystemFill),
            ("secondarySystemFill", .secondarySystemFill), ("systemFill", .systemFill),
            ("quaternaryLabel", .quaternaryLabelColor), ("tertiaryLabel", .tertiaryLabelColor), ("separator", .separatorColor),
            ("grid", .gridColor), ("unemphasizedSelection", .unemphasizedSelectedContentBackgroundColor),
            ("alternating1", NSColor.alternatingContentBackgroundColors[1]), ("controlColor", .controlColor),
            ("secondaryLabel", .secondaryLabelColor), ("label", .labelColor), ("headerText", .headerTextColor),
        ]
        let size: CGFloat = 40
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: CGFloat(colors.count) * size, height: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("swatch")
        let root = NSView()
        for (index, (_, color)) in colors.enumerated() {
            let view = SwatchView(color: color)
            view.frame = CGRect(x: CGFloat(index) * size, y: 0, width: size, height: size)
            root.addSubview(view)
        }
        window.contentView = root
        window.setFrameTopLeftPoint(CGPoint(x: 20, y: 200))
        window.orderFrontRegardless()
        windows.append(window)
        try? colors.map(\.0).joined(separator: "\n").write(toFile: dir + "/swatches.txt", atomically: true, encoding: .utf8)
        try? "swatch \(window.windowNumber)\n".write(toFile: dir + "/swatchwin.txt", atomically: true, encoding: .utf8)
    }

    /// AppKit Ayarlar penceresi (hazır olunca bağlanır).
    static var appKitWindow: ((AppEnvironment) -> NSWindow)? = { SettingsWindowFactory.makeWindow(environment: $0) }
}

private final class SwatchView: NSView {
    let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill(using: .sourceOver) }
}
