import AppKit
import ObjectiveC

/// Geliştirici tanısı (OPENISLAND_APPKIT_DISPLAYPROBE=1, yalnız kare günlüğü açıkken): AppKit'in görüntü görünümü
/// çizimlerini (`_NSSimpleImageView updateLayer`) üst görünüm zincirine göre sayar ve 2 sn'de bir kare günlüğüne yazar.
/// Animasyonun her karesinde yeniden çizilen simge/resim görünümlerini bulmak için. Normal kullanımda hiç kurulmaz.
@MainActor
enum DisplayProbe {
    private static var counts: [String: Int] = [:]
    private static var installed = false

    static func installIfRequested() {
        guard !installed, FrameDriver.isLogging, ProcessInfo.processInfo.environment["OPENISLAND_APPKIT_DISPLAYPROBE"] == "1",
              let cls = NSClassFromString("_NSSimpleImageView") else { return }
        installed = true
        let selector = #selector(NSView.updateLayer)
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Original = @convention(c) (NSView, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let block: @convention(block) (NSView) -> Void = { view in
            MainActor.assumeIsolated { record(view) }
            original(view, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        let interval = ProcessInfo.processInfo.environment["OPENISLAND_APPKIT_DISPLAYPROBE_FINE"] == "1" ? 0.02 : 2
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { flush() } }
    }

    private static func record(_ view: NSView) {
        var chain: [String] = []
        var node: NSView? = view.superview
        while let current = node, chain.count < 7 {
            chain.append(String(describing: type(of: current)))
            node = current.superview
        }
        let size = "\(Int(view.bounds.width))x\(Int(view.bounds.height))"
        counts[size + " < " + chain.joined(separator: " < "), default: 0] += 1
    }

    private static func flush() {
        guard !counts.isEmpty else { return }
        for (key, n) in counts.sorted(by: { $0.value > $1.value }).prefix(12) { FrameDriver.note("imageview.display \(n)x \(key)") }
        counts.removeAll()
    }
}
