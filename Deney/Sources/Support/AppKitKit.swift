import AppKit
import IslandCore

/// `IslandPalette` (UI/IslandDesign.swift) AppKit karşılığı. Kontrastı Artır ayarı renk çözümlendiği anda okunur.
@MainActor
enum Palette {
    static let primary = NSColor.white
    static let secondary = white(0.62, increased: 0.8)
    static let tertiary = white(0.48, increased: 0.7)
    static let fill = white(0.07, increased: 0.14)
    /// Renk animasyonunda `clear` yerine (önçarpımlı karışımda SwiftUI ile aynı: siyaha değil beyaza doğru solar).
    static let clearWhite = NSColor(white: 1, alpha: 0)
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

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(_ text: String) { if stringValue != text { stringValue = text } }

    private func invalidate() {
        measuredWidth = nil
        measuredHeight = nil
        needsDisplay = true
        invalidateIntrinsicContentSize()
        setAccessibilityValue(stringValue)
    }

    /// Ölçüm önbellekleri (metin ya da yazı tipi değişince silinir): yerleşim geçişleri her seferinde CoreText/TextKit
    /// ölçümü yapıyordu (Pano satırlarında sekme geçişinin en büyük yerleşim kalemi).
    private var measuredWidth: CGFloat?
    private var measuredHeight: (width: CGFloat, height: CGFloat)?

    /// SwiftUI metin stilleri (`.title2`, `.headline` …) aynı puntodaki sistem fontundan farklı satır yüksekliği
    /// kullanır; ölçülen değer burada verilir.
    var lineHeightOverride: CGFloat? { didSet { if lineHeightOverride != oldValue { invalidate() } } }
    var lineHeight: CGFloat { lineHeightOverride ?? TextMetrics.lineHeight(for: font) }


    /// Çok satırlı SwiftUI `Text` son satırda tek sözcük bırakmaz (`.standard`: pushOut); gerektiği yerde verilir.
    var lineBreakStrategy: NSParagraphStyle.LineBreakStrategy = [] { didSet { if lineBreakStrategy != oldValue { invalidate() } } }

    private var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = maximumLines == 1 ? lineBreakMode : .byWordWrapping
        paragraph.lineBreakStrategy = lineBreakStrategy
        return [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraph]
    }

    /// Doğal tek satır genişliği.
    var naturalWidth: CGFloat { ceil(exactWidth) }
    /// Yuvarlanmamış tek satır genişliği.
    var exactWidth: CGFloat {
        if let measuredWidth { return measuredWidth }
        let width = (stringValue as NSString).size(withAttributes: [.font: font]).width
        measuredWidth = width
        return width
    }

    override var intrinsicContentSize: NSSize { NSSize(width: naturalWidth, height: lineHeight) }

    /// `minimumScaleFactor` ile tek satırın verilen genişliğe sığması için uygulanan ölçek (1 = küçülmez).
    func fittingScale(forWidth width: CGFloat) -> CGFloat {
        guard maximumLines == 1, minimumScaleFactor < 1, width > 0 else { return 1 }
        let natural = exactWidth
        return natural > width ? max(minimumScaleFactor, width / natural) : 1
    }

    /// SwiftUI küçülen metnin satır yüksekliğini küçülmüş puntoyla hesaplar (ör. 19 pt × 0,99 → 22 pt, 23 değil);
    /// yığınlarda (VStack) yerleşim bu yüksekliğe göre yapılır.
    func fittedLineHeight(forWidth width: CGFloat) -> CGFloat {
        let scale = fittingScale(forWidth: width)
        return scale < 1 ? TextMetrics.lineHeight(forPointSize: font.pointSize * scale) : lineHeight
    }

    /// Verilen genişlikte gereken yükseklik (çok satırlı metin için): satır sayısı × SwiftUI satır yüksekliği.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard maximumLines != 1 else { return lineHeight }
        if let measuredHeight, measuredHeight.width == width { return measuredHeight.height }
        var lines = TextMetrics.layout(stringValue, attributes: attributes, width: width).lines
        if maximumLines > 0 { lines = min(lines, maximumLines) }
        let height = CGFloat(max(lines, 1)) * lineHeight
        measuredHeight = (width, height)
        return height
    }

    /// AX çerçevesi SwiftUI `Text` gibi metnin kapladığı alandır: genişlik piksele (0,5 pt) yukarı yuvarlanır, hizalamaya
    /// göre yerleşir. Yalnız AX sorgusunda hesaplanır.
    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        let used: CGFloat
        var height = min(lineHeight, bounds.height)
        if maximumLines == 1 {
            used = exactWidth
        } else {
            used = TextMetrics.layout(stringValue, attributes: attributes, width: bounds.width).usedWidth
            height = bounds.height
        }
        let width = min(pixelCeil(used), bounds.width)
        let x: CGFloat = switch alignment {
        case .center: (bounds.width - width) / 2
        case .right: bounds.width - width
        default: 0
        }
        return window.convertToScreen(convert(CGRect(x: x, y: 0, width: width, height: height), to: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        var attributes = self.attributes
        var rect = bounds
        if alignment == .center || alignment == .right {
            // SwiftUI metin kutusu piksele yukarı yuvarlanmış genişliktedir ve kutu piksele oturur; satırlar kutu içinde
            // hizalanır. Alt piksel ortalama farklı kenar yumuşatması üretir.
            let used = maximumLines == 1 ? exactWidth : TextMetrics.layout(stringValue, attributes: self.attributes, width: bounds.width).usedWidth
            let w = min(pixelCeil(used), bounds.width)
            let free = bounds.width - w
            let x = alignment == .center ? free / 2 : free
            rect = CGRect(x: (x * 2 + 0.5).rounded(.down) / 2, y: 0, width: w, height: bounds.height)
        }
        let scale = fittingScale(forWidth: bounds.width)
        if scale < 1 {
            attributes[.font] = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
            // SwiftUI: küçülen satırın kutusu küçülmüş satır yüksekliğidir ve kapsayıcıda dikeyde ortalanır; kutu zaten
            // bu yükseklikteyse kayma sıfırdır.
            rect.origin.y += (bounds.height - fittedLineHeight(forWidth: bounds.width)) / 2
        }
        let drawFont = attributes[.font] as? NSFont ?? font
        if maximumLines == 1, lineBreakMode == .byTruncatingTail, scale == 1, exactWidth > rect.width,
           let context = NSGraphicsContext.current?.cgContext {
            // SwiftUI tek satırı CoreText kesmesiyle kısaltır (`CTLineCreateTruncatedLine`, "…"); NSString çizimi
            // farklı noktada keser (61 genişlikte ölçüldü). Taban çizgisi NSString çizimiyle aynı yerde.
            let plain: [NSAttributedString.Key: Any] = [.font: drawFont, .foregroundColor: textColor]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: stringValue, attributes: plain))
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: plain))
            let truncated = CTLineCreateTruncatedLine(line, Double(rect.width), .end, token) ?? line
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: rect.minX, y: rect.minY + drawFont.ascender)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(truncated, context)
            context.restoreGState()
            return
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

    /// Tablo dışı (küçülmüş) punto: SwiftUI'nin basamaklı değeri, ölçülmüş en yakın alt basamaktan alınır
    /// (18,8 pt → 22; 19 pt → 23).
    /// Metin satırının üstünden taban çizgisine uzaklık (SwiftUI `Label` simge hizası için; 11 pt ölçüldü).
    static func baseline(for font: NSFont) -> CGFloat {
        if font.pointSize == 11 { return 11.125 }
        let lh = lineHeight(for: font)
        return (((lh - (font.ascender - font.descender)) / 2 + font.ascender) * 8).rounded() / 8
    }

    static func lineHeight(forPointSize size: CGFloat) -> CGFloat {
        let step = (Double(size) * 2).rounded(.down) / 2
        return table[step] ?? ceil(size * 1.2)
    }

    /// Verilen genişlikte satır sayısı ve en geniş satırın kullanılan genişliği (TextKit ile, sözcük kaydırma).
    static func layout(_ text: String, attributes: [NSAttributedString.Key: Any], width: CGFloat) -> (lines: Int, usedWidth: CGFloat) {
        let storage = NSTextStorage(string: text, attributes: attributes)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        var lines = 0
        var usedWidth: CGFloat = 0
        var index = 0
        let glyphs = manager.numberOfGlyphs
        while index < glyphs {
            var range = NSRange()
            usedWidth = max(usedWidth, manager.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: &range).width)
            index = NSMaxRange(range)
            lines += 1
        }
        return (lines, usedWidth)
    }
}

/// Piksele (2× ekranda 0,5 pt) yukarı yuvarlar; SwiftUI metin çerçevesi genişliği.
func pixelCeil(_ v: CGFloat, scale: CGFloat = 2) -> CGFloat { ceil(v * scale) / scale }

/// SwiftUI gibi en yakın piksele (yarım değerler yukarı) yuvarlar.
func pixelRound(_ v: CGFloat, scale: CGFloat = 2) -> CGFloat { (v * scale + 0.5).rounded(.down) / scale }

/// SwiftUI gibi kenarları piksel ızgarasına (2× ekranda 0,5 pt) yuvarlar.
func pixelRect(_ r: CGRect, scale: CGFloat = 2) -> CGRect {
    func p(_ v: CGFloat) -> CGFloat { (v * scale + 0.5).rounded(.down) / scale } // yarım değerler yukarı (SwiftUI)
    let x0 = p(r.minX), y0 = p(r.minY), x1 = p(r.maxX), y1 = p(r.maxY)
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
}

/// SF Symbol görünümü. Sembol değişimi istenirse `.replace` içerik geçişiyle yapılır (SwiftUI `contentTransition`).
final class SymbolView: NSImageView {
    private var symbol: String = ""
    var symbolName: String { symbol }
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
        inkBounds = nil
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

    /// Yalnız renk değişince yazılır: aynı rengi yeniden atamak bile sembolü baştan rasterleştirir (CoreUI glif
    /// çözümlemesi dahil; sekme geçişinde uygulama CPU'sunun ~%20'si buydu).
    override var contentTintColor: NSColor? {
        get { super.contentTintColor }
        set { if newValue != super.contentTintColor { super.contentTintColor = newValue } }
    }

    /// Görünen yatay kayma (başlık satırının kayma animasyonu): çerçeve yerinde kalır, görüntü katmanı tam piksel
    /// adımlarıyla kaydırılır.
    /// `NSImageView` her çerçeve değişiminde iç görüntü alt görünümünü güncelleyip sembolü yeniden rasterleştiriyordu
    /// (sekme geçişinde uygulama CPU'sunun en büyük kalemi). Dururken ofset sıfırdır; görüntü değişmez.
    func setVisualOffset(_ offset: CGFloat) {
        // Cihaz pikseline yuvarlanır: `NSImageView` görüntüsünü piksele oturtarak kaydırıyordu (keskin, piksel adımlı);
        // piksel arası kaydırma kenarları her karede yumuşatıp keskinleştirir, kayma sırasında titreme gibi görünür.
        let scale = window?.backingScaleFactor ?? 2
        let dx = (offset * scale).rounded() / scale
        guard dx != visualOffset || (dx != 0 && layer?.sublayerTransform.m41 != dx) else { return }
        if FrameDriver.isLogging, let layer, layer.sublayerTransform.m41 != visualOffset {
            FrameDriver.note("SymbolView \(symbol): sublayerTransform dışarıdan değişmiş (\(layer.sublayerTransform.m41) ≠ \(visualOffset))")
        }
        visualOffset = dx
        wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayerTransform = dx == 0 ? CATransform3DIdentity : CATransform3DMakeTranslation(dx, 0, 0)
        CATransaction.commit()
    }

    private var visualOffset: CGFloat = 0

    override var intrinsicContentSize: NSSize { image?.size ?? .zero }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// SwiftUI `Image(systemName:)` yerleşim kutusu: genişlik hizalama genişliği, yükseklik görüntü yüksekliği − 0,5
    /// (çalışma anında 24 sembol/boyutta ölçülmüştür; Deney/README.md → Ölçümler).
    var layoutSize: CGSize {
        guard let image else { return .zero }
        return CGSize(width: image.alignmentRect.width, height: image.size.height - 0.5)
    }

    /// Yerleşim kutusu `origin`'de olan sembolün çizim çerçevesi: SwiftUI görüntüyü kutunun sol-alt köşesine yaslar
    /// (üstte 0,5 pt taşar) ve kökeni en yakın piksele yuvarlar.
    /// `halfPixelUp`: adanın başlık satırında SwiftUI yarım pikseli yukarı yuvarlar (gövde içinde aşağı); ekran
    /// görüntüsü karşılaştırmasıyla belirlenmiştir.
    func drawingFrame(layoutOrigin origin: CGPoint, scale: CGFloat = 2, halfPixelUp: Bool = false) -> CGRect {
        guard let image else { return .zero }
        func snapX(_ v: CGFloat) -> CGFloat { (v * scale + 0.5).rounded(.down) / scale }
        func snapY(_ v: CGFloat) -> CGFloat { halfPixelUp ? (v * scale - 0.5).rounded(.up) / scale : (v * scale + 0.5).rounded(.down) / scale }
        let layout = layoutSize
        return CGRect(x: snapX(origin.x - image.alignmentRect.minX), y: snapY(origin.y + layout.height - image.size.height),
                      width: image.size.width, height: image.size.height)
    }

    /// Düz düğmenin etiketi olan sembol: düğmenin çerçevesi yerleşim kutusudur, sembol mutlak piksel ızgarasına oturur.
    /// `origin` düğmenin üst görünümünün koordinatlarındadır.
    func place(asLabelOf button: NSView, layoutOrigin origin: CGPoint) {
        button.frame = CGRect(origin: origin, size: layoutSize)
        frame = drawingFrame(layoutOrigin: origin).offsetBy(dx: -origin.x, dy: -origin.y)
        (button as? PlainButton)?.inkSymbol = self // SwiftUI: yalnız simgeli düğmenin AX çerçevesi simge mürekkebidir
    }

    /// SwiftUI `.frame(width:height:)` içinde ortalanmış sembolün çizim çerçevesi.
    func drawingFrame(centeredIn rect: CGRect, halfPixelUp: Bool = false) -> CGRect {
        let layout = layoutSize
        return drawingFrame(layoutOrigin: CGPoint(x: rect.midX - layout.width / 2, y: rect.midY - layout.height / 2), halfPixelUp: halfPixelUp)
    }

    private var isExposed = false
    override func isAccessibilityElement() -> Bool { isExposed }
    override func accessibilityChildren() -> [Any]? { nil }

    /// Bağımsız görsel olarak AX'e açar (SwiftUI `Image(systemName:)`): sistemin sembol etiketi, sözcükler büyük harfle.
    func exposeAsImage(frameOf container: NSView? = nil) {
        let description = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.accessibilityDescription ?? ""
        frameContainer = container
        isExposed = true
        setAccessibilityRole(.image)
        setAccessibilityLabel(description.capitalized(with: Locale(identifier: "tr_TR")))
    }

    /// SwiftUI sembol görselinin AX çerçevesi, sembolün mürekkep sınırıdır (görüntü kutusu değil). Yalnız AX sorgusunda,
    /// sembol başına bir kez 2× taranır.
    private var inkBounds: CGRect?
    /// Kaplama (`overlay`) olarak kullanılan sembolde AX çerçevesi taşıyıcı kutunun çerçevesidir.
    private weak var frameContainer: NSView?

    override func accessibilityFrame() -> NSRect {
        if let frameContainer, let window = frameContainer.window {
            return window.convertToScreen(frameContainer.convert(frameContainer.bounds, to: nil))
        }
        guard isExposed, let ink = inkScreenFrame() else { return super.accessibilityFrame() }
        return ink
    }

    /// Sembol mürekkebinin ekran çerçevesi (yalnız AX sorgularında hesaplanır).
    func inkScreenFrame() -> NSRect? {
        guard let window, let image else { return nil }
        let ink = inkBounds ?? Self.measureInk(image)
        inkBounds = ink
        // Görüntü sınırların ortasında çizilir (`scaleNone`); mürekkep üstten ölçülmüştür, görünüm çevrik değildir.
        let imageBottom = (bounds.height - image.size.height) / 2
        let rect = CGRect(x: (bounds.width - image.size.width) / 2 + ink.minX,
                          y: imageBottom + image.size.height - ink.maxY, width: ink.width, height: ink.height)
        return window.convertToScreen(convert(rect, to: nil))
    }

    private static func measureInk(_ image: NSImage) -> CGRect {
        let w = Int(image.size.width * 2), h = Int(image.size.height * 2)
        guard w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return CGRect(origin: .zero, size: image.size) }
        rep.size = image.size // bağlam oluşturulmadan önce: 2× ölçek
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return CGRect(origin: .zero, size: image.size) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return CGRect(origin: .zero, size: image.size) }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = data + y * rep.bytesPerRow
            for x in 0..<w where row[x * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return CGRect(origin: .zero, size: image.size) }
        return CGRect(x: CGFloat(minX) / 2, y: CGFloat(minY) / 2, width: CGFloat(maxX - minX + 1) / 2, height: CGFloat(maxY - minY + 1) / 2)
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

    nonisolated override var isFlipped: Bool { true }

    var fill: NSColor = .clear { didSet { updateLayer() } }
    var stroke: (color: NSColor, width: CGFloat)? { didSet { updateLayer() } }

    nonisolated override var wantsUpdateLayer: Bool { true }
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

/// Geliştirici tanısı (OPENISLAND_DENEY_IMGPROBE=dosya): görüntü görünümlerinin katman yeniden çizimleri (AppKit'in iç
/// `_NSSimpleImageView.updateLayer` çağrısı) görünüm yolu ve sembol başına sayılır, 2 s'de bir dosyaya yazılır.
@MainActor
enum ImageRedrawProbe {
    private static var counts: [String: Int] = [:]
    private static var installed = false

    static func install() {
        guard !installed, let path = ProcessInfo.processInfo.environment["OPENISLAND_DENEY_IMGPROBE"],
              let cls = NSClassFromString("_NSSimpleImageView"),
              let method = class_getInstanceMethod(cls, NSSelectorFromString("updateLayer")) else { return }
        installed = true
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        let selector = NSSelectorFromString("updateLayer")
        let block: @convention(block) (AnyObject) -> Void = { object in
            if let view = object as? NSView {
                var parts: [String] = []
                var v = view.superview
                if let symbol = v as? SymbolView { parts.append(symbol.symbolName) }
                while let current = v, parts.count < 6 {
                    parts.append(String(describing: type(of: current)))
                    v = current.superview
                }
                MainActor.assumeIsolated { counts[parts.joined(separator: " < "), default: 0] += 1 }
                if parts.first == "timer", ProcessInfo.processInfo.environment["OPENISLAND_DENEY_IMGPROBE_STACKS"] != nil {
                    record(object, "updateLayer")
                }
            }
            original(object, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        if ProcessInfo.processInfo.environment["OPENISLAND_DENEY_IMGPROBE_STACKS"] != nil { installInvalidationStacks(cls) }
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = FileHandle(forWritingAtPath: path)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !counts.isEmpty else { return }
                var text = String(format: "--- %.1f\n", CACurrentMediaTime())
                for (k, n) in counts.sorted(by: { $0.value > $1.value }) { text += "\(n)\t\(k)\n" }
                handle?.write(Data(text.utf8))
                counts.removeAll()
            }
        }
    }

    /// Yeniden çizimi isteyen çağrı yığınları (görüntü görünümünün `setNeedsDisplay…` çağrıları).
    private static func installInvalidationStacks(_ cls: AnyClass) {
        for name in ["_updateImageSubview", "layout"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(NSImageView.self, selector) else { continue }
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
            let block: @convention(block) (AnyObject) -> Void = { object in
                if let symbol = object as? SymbolView, MainActor.assumeIsolated({ symbol.symbolName }) == "timer" {
                    recordImageView(symbol, "NSImageView." + name)
                }
                original(object, selector)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        for layerClass in [NSClassFromString("NSViewBackingLayer"), CALayer.self].compactMap({ $0 }) {
            let selector = NSSelectorFromString("setNeedsDisplay")
            guard let method = class_getInstanceMethod(layerClass, selector) else { continue }
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
            let block: @convention(block) (AnyObject) -> Void = { object in
                if let layer = object as? CALayer, let delegate = layer.delegate as? NSObject, delegate.isMember(of: cls) {
                    record(delegate, "layer.setNeedsDisplay0")
                }
                original(object, selector)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
            break
        }
        if let method = class_getInstanceMethod(NSClassFromString("NSViewBackingLayer") ?? CALayer.self, NSSelectorFromString("setNeedsDisplayInRect:")) {
            let selector = NSSelectorFromString("setNeedsDisplayInRect:")
            typealias Fn = @convention(c) (AnyObject, Selector, CGRect) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
            let block: @convention(block) (AnyObject, CGRect) -> Void = { object, rect in
                if let layer = object as? CALayer, let delegate = layer.delegate as? NSObject, delegate.isMember(of: cls) {
                    record(delegate, "layer.setNeedsDisplay")
                }
                original(object, selector, rect)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        for name in ["setNeedsDisplayInRect:", "setNeedsDisplay:"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(cls, selector) else { continue }
            if name == "setNeedsDisplay:" {
                typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
                let block: @convention(block) (AnyObject, Bool) -> Void = { object, flag in
                    if flag { record(object, name) }
                    original(object, selector, flag)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            } else {
                typealias Fn = @convention(c) (AnyObject, Selector, NSRect) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
                let block: @convention(block) (AnyObject, NSRect) -> Void = { object, rect in
                    record(object, name)
                    original(object, selector, rect)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            }
        }
    }

    private nonisolated static func recordImageView(_ object: AnyObject, _ name: String) {
        let frames = Thread.callStackSymbols.dropFirst(2).prefix(40).map { line -> String in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            return parts.count > 3 ? String(parts[3].prefix(70)) : line
        }
        let key = "INVAL \(name) timer :: " + frames.joined(separator: " <- ")
        MainActor.assumeIsolated { counts[key, default: 0] += 1 }
    }

    private nonisolated static func record(_ object: AnyObject, _ name: String) {
        nonisolated(unsafe) let object = object // yalnız ana iş parçacığında çağrılır
        let symbol = MainActor.assumeIsolated { () -> String in
            let view = object as? NSView
            if let symbolView = view?.superview as? SymbolView { return symbolView.symbolName }
            let chain = [view?.superview, view?.superview?.superview, view?.superview?.superview?.superview]
                .map { $0.map { String(describing: type(of: $0)) } ?? "-" }.joined(separator: "<")
            return "[\(chain) w=\(view?.window.map { String(describing: type(of: $0)) } ?? "-")]"
        }
        let depth = Int(ProcessInfo.processInfo.environment["OPENISLAND_DENEY_IMGPROBE_STACKS"] ?? "") ?? 9
        let frames = Thread.callStackSymbols.dropFirst(2).prefix(depth).map { line -> String in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            return parts.count > 3 ? String(parts[3].prefix(70)) : line
        }
        let key = "INVAL \(name) \(symbol) :: " + frames.joined(separator: " <- ")
        MainActor.assumeIsolated { counts[key, default: 0] += 1 }
    }
}
