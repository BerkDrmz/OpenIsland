import AppKit

/// Ekrandan renk damlalığı: sistemin kendi büyüteçli örnekleyicisi (`NSColorSampler`).
/// Ekran kaydı izni gerektirmez; seçilen renk sRGB HEX olarak panoya kopyalanır ve son renkler saklanır.
@MainActor
@Observable
final class ColorPickerService {
    private(set) var recentColors: [String] = []
    @ObservationIgnored var onPicked: ((String) -> Void)?
    @ObservationIgnored private let storeKey = "recentPickedColors"
    @ObservationIgnored private var isSampling = false

    init() {
        recentColors = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
    }

    func pick() {
        guard !isSampling else { return }
        isSampling = true
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate() // örnekleyici imleci yalnızca aktif uygulamadan devralabilir
        NSColorSampler().show { [weak self] color in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isSampling = false
                    previous?.activate()
                    guard let color, let hex = Self.hex(from: color) else { return }
                    self.copy(hex)
                    self.onPicked?(hex)
                }
            }
        }
    }

    func copy(_ hex: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hex, forType: .string)
        recentColors.removeAll { $0 == hex }
        recentColors.insert(hex, at: 0)
        if recentColors.count > 12 { recentColors.removeLast(recentColors.count - 12) }
        UserDefaults.standard.set(recentColors, forKey: storeKey)
    }

    nonisolated static func hex(from color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
