import AppKit
import IslandCore

/// `IslandPalette` (UI/IslandDesign.swift) AppKit karşılığı. Kontrastı Artır ayarı renk çözümlendiği anda okunur.
@MainActor
enum Palette {
    static let primary = NSColor.white
    static let secondary = white(0.62, increased: 0.8)
    static let tertiary = white(0.48, increased: 0.7)
    static let fill = white(0.07, increased: 0.14)
    static let fillHover = white(0.12, increased: 0.22)
    static let separator = white(0.12, increased: 0.32)
    static let track = white(0.18, increased: 0.34)
    static let pulse = NSColor(srgbRed: 1.0, green: 0.8, blue: 0.42, alpha: 1)
    static let accentBlue = NSColor.systemBlue

    static var increasedContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    private static func white(_ standard: CGFloat, increased: CGFloat) -> NSColor {
        NSColor(name: nil) { _ in
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: increasedContrast ? increased : standard)
        }
    }
}

/// `IslandType` AppKit karşılığı (SF Pro; sayaçlarda SF Pro Rounded + eş genişlikli rakamlar).
@MainActor
enum Fonts {
    static let title = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let body = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let bodyEmphasized = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let caption = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let caption2 = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let sectionLabel = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let numeric = rounded(12, .semibold)
    static let numericSmall = rounded(10, .medium)
    static let numericLarge = rounded(19, .semibold)

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight, monospacedDigits: Bool = true) -> NSFont {
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = font.fontDescriptor.withDesign(.rounded), let rounded = NSFont(descriptor: descriptor, size: size) {
            font = rounded
        }
        guard monospacedDigits else { return font }
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [[.typeIdentifier: kNumberSpacingType, .selectorIdentifier: kMonospacedNumbersSelector]]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: features])
        return NSFont(descriptor: descriptor, size: size) ?? font
    }
}

enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let cardRadius = IslandLayoutEngine.concentricRadius(
        outer: IslandLayoutEngine.expandedBottomRadius, inset: IslandLayoutEngine.contentInset)
}

/// Tek satırlık, seçilemez etiket.
final class TextLabel: NSTextField {
    init(_ text: String = "", font: NSFont = Fonts.body, color: NSColor = Palette.primary,
         alignment: NSTextAlignment = .left, truncation: NSLineBreakMode = .byTruncatingTail) {
        super.init(frame: .zero)
        stringValue = text
        self.font = font
        textColor = color
        self.alignment = alignment
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = truncation
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
        usesSingleLineMode = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override var allowsVibrancy: Bool { false }

    func set(_ text: String) { if stringValue != text { stringValue = text } }

    /// Doğal tek satır genişliği.
    var naturalWidth: CGFloat { ceil(attributedStringValue.size().width) + 4 }
}

/// SF Symbol görünümü. Sembol değişimi istenirse `.replace` içerik geçişiyle yapılır (SwiftUI `contentTransition`).
final class SymbolView: NSImageView {
    private var symbol: String = ""
    private var configuration: NSImage.SymbolConfiguration

    init(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = Palette.primary,
         scale: NSImage.SymbolScale = .medium) {
        configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight, scale: scale)
        super.init(frame: .zero)
        imageScaling = .scaleNone
        contentTintColor = color
        set(name, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func set(_ name: String, animated: Bool = true) {
        guard name != symbol else { return }
        symbol = name
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        if animated, let image, #available(macOS 14.0, *) {
            setSymbolImage(image, contentTransition: .replace)
        } else {
            self.image = image
        }
    }

    func setConfiguration(size: CGFloat, weight: NSFont.Weight) {
        configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        let name = symbol
        symbol = ""
        set(name, animated: false)
    }

    override var intrinsicContentSize: NSSize { image?.size ?? .zero }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Sürekli eğrilikli (squircle) köşeli dolgu katmanı olan görünüm.
class RoundedView: NSView {
    init(radius: CGFloat, fill: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        self.fill = fill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override var isFlipped: Bool { true }

    var fill: NSColor = .clear { didSet { updateLayer() } }
    var stroke: (color: NSColor, width: CGFloat)? { didSet { updateLayer() } }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        // Dinamik renkler (Kontrastı Artır) görünümün görünüşüyle çözülür.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = stroke?.color.cgColor
            layer?.borderWidth = stroke?.width ?? 0
        }
    }
}

extension NSView {
    /// Yarım değil, tam piksele hizalı çerçeve (y-aşağı kaplar için).
    func setFrameAligned(_ rect: CGRect) {
        let scale = window?.backingScaleFactor ?? 2
        frame = CGRect(x: (rect.minX * scale).rounded() / scale, y: (rect.minY * scale).rounded() / scale,
                       width: (rect.width * scale).rounded() / scale, height: (rect.height * scale).rounded() / scale)
    }
}

extension NSColor {
    /// "#RRGGBB" → NSColor
    convenience init?(hexString hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
