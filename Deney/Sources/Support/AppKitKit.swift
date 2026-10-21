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

/// Metin etiketi: SwiftUI `Text` gibi iç boşluksuz çizer; içerik yalnız değişince katmana bir kez çizilir
/// (kare başı iş yok). Varsayılan tek satır + sondan kesme; `maximumLines` ile çok satırlı ortalı metin.
final class TextLabel: NSView {
    var stringValue: String { didSet { if stringValue != oldValue { invalidate() } } }
    var font: NSFont { didSet { if font != oldValue { invalidate() } } }
    var textColor: NSColor { didSet { if textColor != oldValue { needsDisplay = true } } }
    var alignment: NSTextAlignment { didSet { if alignment != oldValue { needsDisplay = true } } }
    var lineBreakMode: NSLineBreakMode { didSet { needsDisplay = true } }
    var maximumLines = 1 { didSet { invalidate() } }
    /// SwiftUI `minimumScaleFactor`: tek satır sığmazsa yazı en çok bu orana kadar küçülür.
    var minimumScaleFactor: CGFloat = 1 { didSet { needsDisplay = true } }

    init(_ text: String = "", font: NSFont = Fonts.body, color: NSColor = Palette.primary,
         alignment: NSTextAlignment = .left, truncation: NSLineBreakMode = .byTruncatingTail) {
        stringValue = text
        self.font = font
        textColor = color
        self.alignment = alignment
        lineBreakMode = truncation
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(_ text: String) { if stringValue != text { stringValue = text } }

    private func invalidate() {
        needsDisplay = true
        invalidateIntrinsicContentSize()
        setAccessibilityValue(stringValue)
    }

    var lineHeight: CGFloat { TextMetrics.lineHeight(for: font) }

    private var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = maximumLines == 1 ? lineBreakMode : .byWordWrapping
        return [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraph]
    }

    /// Doğal tek satır genişliği.
    var naturalWidth: CGFloat { ceil((stringValue as NSString).size(withAttributes: [.font: font]).width) }

    override var intrinsicContentSize: NSSize { NSSize(width: naturalWidth, height: lineHeight) }

    /// Verilen genişlikte gereken yükseklik (çok satırlı metin için): satır sayısı × SwiftUI satır yüksekliği.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard maximumLines != 1 else { return lineHeight }
        var lines = TextMetrics.lineCount(stringValue, attributes: attributes, width: width)
        if maximumLines > 0 { lines = min(lines, maximumLines) }
        return CGFloat(max(lines, 1)) * lineHeight
    }

    override func draw(_ dirtyRect: NSRect) {
        var attributes = self.attributes
        var rect = bounds
        if maximumLines == 1, minimumScaleFactor < 1, naturalWidth > bounds.width, naturalWidth > 0 {
            let scale = max(minimumScaleFactor, bounds.width / naturalWidth)
            let scaled = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
            attributes[.font] = scaled
            // Küçülen satır dikeyde ortada kalır (SwiftUI ile aynı).
            rect.origin.y += ((font.ascender - font.descender) - (scaled.ascender - scaled.descender)) / 2
        }
        (stringValue as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: attributes, context: nil)
    }
}

/// SwiftUI `Text` ile aynı satır yüksekliği. SwiftUI'nin değeri yalnız punto boyutuna bağlı (ağırlık ve yuvarlak tasarım
/// değiştirmiyor) ve basit bir formüle oturmuyor; 7–28 pt aralığı ölçülmüştür (Deney/README.md → Ölçümler).
enum TextMetrics {
    private static let table: [Double: CGFloat] = [
        7.0: 9, 7.5: 9, 8.0: 10, 8.5: 10, 9.0: 11, 9.5: 12, 10.0: 13, 10.5: 13, 11.0: 14, 11.5: 14, 12.0: 15, 12.5: 15,
        13.0: 16, 13.5: 16, 14.0: 17, 14.5: 18, 15.0: 19, 15.5: 19, 16.0: 19, 16.5: 20, 17.0: 20, 17.5: 21, 18.0: 21,
        18.5: 22, 19.0: 23, 19.5: 24, 20.0: 24, 20.5: 25, 21.0: 25, 21.5: 26, 22.0: 26, 22.5: 27, 23.0: 27, 23.5: 28,
        24.0: 28, 24.5: 29, 25.0: 29, 25.5: 30, 26.0: 30, 26.5: 32, 27.0: 32, 27.5: 33, 28.0: 33,
    ]

    static func lineHeight(for font: NSFont) -> CGFloat {
        table[(Double(font.pointSize) * 2).rounded() / 2] ?? ceil(font.ascender - font.descender + font.leading)
    }

    /// Verilen genişlikte satır sayısı (TextKit ile, sözcük kaydırma).
    static func lineCount(_ text: String, attributes: [NSAttributedString.Key: Any], width: CGFloat) -> Int {
        let storage = NSTextStorage(string: text, attributes: attributes)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        var lines = 0
        var index = 0
        let glyphs = manager.numberOfGlyphs
        while index < glyphs {
            var range = NSRange()
            manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            index = NSMaxRange(range)
            lines += 1
        }
        return lines
    }
}

/// SwiftUI gibi kenarları piksel ızgarasına (2× ekranda 0,5 pt) yuvarlar.
func pixelRect(_ r: CGRect, scale: CGFloat = 2) -> CGRect {
    func p(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
    let x0 = p(r.minX), y0 = p(r.minY), x1 = p(r.maxX), y1 = p(r.maxY)
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
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
        // Düğme ve satır içindeki simgeler ayrı öğe değildir (SwiftUI ile aynı); `exposeAsImage` ile açılır.
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

    private var isExposed = false
    override func isAccessibilityElement() -> Bool { isExposed }
    override func accessibilityChildren() -> [Any]? { nil }

    /// Bağımsız görsel olarak AX'e açar (SwiftUI `Image(systemName:)`): sistemin sembol etiketi, sözcükler büyük harfle.
    func exposeAsImage() {
        let description = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.accessibilityDescription ?? ""
        isExposed = true
        setAccessibilityRole(.image)
        setAccessibilityLabel(description.capitalized(with: Locale(identifier: "tr_TR")))
    }
}

/// Süs görseli: AX'te ayrı öğe olarak görünmez (SwiftUI düğme içindeki `Image`).
final class DecorativeImageView: NSImageView {
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { nil }
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
