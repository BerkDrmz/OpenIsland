import AppKit
import QuartzCore

/// Geliştirici tanısı (OPENISLAND_POINTER_LOG): imleç giriş/çıkışı ve faz değişimleri, imleç konumu ve hover
/// dikdörtgeniyle. Değişken yoksa hiçbir şey yapmaz.
enum PointerProbe {
    private static let handle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["OPENISLAND_POINTER_LOG"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static var isEnabled: Bool { handle != nil }

    /// Pencerenin katman ağacı: toplam, görünür (gizli/opaklığı 0 olmayan) ve içerik taşıyan katman sayısı.
    @MainActor
    static func layerCensus(_ window: NSWindow?) -> String {
        guard let root = window?.contentView?.layer else { return "katman yok" }
        var total = 0, visible = 0, withContents = 0
        func walk(_ layer: CALayer, _ shown: Bool) {
            total += 1
            let isShown = shown && !layer.isHidden && layer.opacity > 0
            if isShown { visible += 1; if layer.contents != nil { withContents += 1 } }
            layer.sublayers?.forEach { walk($0, isShown) }
        }
        walk(root, true)
        return "katman toplam=\(total) görünür=\(visible) içerikli=\(withContents)"
    }

    static func note(_ text: @autoclosure () -> String) {
        guard let handle else { return }
        handle.write(Data(String(format: "%.3f %@\n", CACurrentMediaTime(), text()).utf8))
    }
}
