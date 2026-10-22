import AppKit
import QuartzCore

/// Geliştirici tanısı (OPENISLAND_POINTER_LOG): imleç giriş/çıkışı ve faz değişimleri, imleç konumu ve hover
/// dikdörtgeniyle. Değişken yoksa hiçbir şey yapmaz.
enum PointerProbe {
    nonisolated(unsafe) private static let handle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["OPENISLAND_POINTER_LOG"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static var isEnabled: Bool { handle != nil }

    static func note(_ text: @autoclosure () -> String) {
        guard let handle else { return }
        handle.write(Data(String(format: "%.3f %@\n", CACurrentMediaTime(), text()).utf8))
    }
}
