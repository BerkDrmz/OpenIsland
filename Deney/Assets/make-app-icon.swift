// OpenIsland Deney uygulama simgesi üreticisi: `AppIcon.icns` bu dosyadan üretilir (elle çizim yok).
//
//   swiftc -O Deney/Assets/make-app-icon.swift -o /tmp/make-app-icon && /tmp/make-app-icon Deney/Assets
//
// Tasarım: macOS simge ızgarası (1024 tuvalde 824 pt yuvarlatılmış kare), koyu gece mavisi zemin; ortada çentikten
// açılan ada: siyah kapsül, çevresinde medya renklerinde ince parıltı, içinde kamera noktası ve ses dalgası.
import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let space = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                           CGFloat(hex & 0xff) / 255, alpha])!
}

func capsule(_ rect: CGRect) -> CGPath {
    let radius = min(rect.width, rect.height) / 2
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(_ size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high

    // Zemin: macOS ızgarası, altta hafif gölge.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(color(0x0B0D18)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x283066), color(0x12152E), color(0x07080F)] as CFArray,
                                locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Üstten gelen yumuşak ışık (ekranın çentiği).
    let halo = CGGradient(colorsSpace: space, colors: [color(0x7F8CFF, 0.30), color(0x7F8CFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: CGPoint(x: 512, y: 600), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 600), endRadius: 420, options: [])

    // Ada: kapsülün çevresinde renkli parıltı.
    let island = CGRect(x: 232, y: 452, width: 560, height: 172)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70, color: color(0x6E7BFF, 0.55))
    ctx.addPath(capsule(island)); ctx.setFillColor(color(0x000000)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(capsule(island.insetBy(dx: -5, dy: -5))); ctx.addPath(capsule(island)); ctx.clip(using: .evenOdd)
    let ring = CGGradient(colorsSpace: space, colors: [color(0x36D1FF), color(0x7A6CFF), color(0xFF5FB8)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(ring, start: CGPoint(x: island.minX, y: 0), end: CGPoint(x: island.maxX, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.addPath(capsule(island)); ctx.setFillColor(color(0x000000)); ctx.fillPath()

    // Kapsül içi: solda kamera noktası, sağda ses dalgası.
    let lens = CGRect(x: island.minX + 58, y: island.midY - 26, width: 52, height: 52)
    ctx.setFillColor(color(0x1A1D2B)); ctx.fillEllipse(in: lens)
    ctx.setFillColor(color(0x3B4466)); ctx.fillEllipse(in: lens.insetBy(dx: 14, dy: 14))
    let bars: [CGFloat] = [0.34, 0.62, 1.0, 0.72, 0.46, 0.84, 0.4]
    let barWidth: CGFloat = 20, gap: CGFloat = 13
    let total = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
    var x = island.maxX - 64 - total
    for (i, h) in bars.enumerated() {
        let height = 96 * h
        let bar = CGRect(x: x, y: island.midY - height / 2, width: barWidth, height: height)
        ctx.saveGState()
        ctx.addPath(capsule(bar))
        ctx.clip()
        let t = CGFloat(i) / CGFloat(bars.count - 1)
        ctx.drawLinearGradient(ring, start: CGPoint(x: x - t * 300, y: 0), end: CGPoint(x: x + (1 - t) * 300, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
        x += barWidth + gap
    }

    // Alt bölge: açılan panelin silik içerik çizgileri.
    for (i, width) in [CGFloat(420), 330, 250].enumerated() {
        let row = CGRect(x: 512 - width / 2, y: 352 - CGFloat(i) * 62, width: width, height: 26)
        ctx.addPath(capsule(row)); ctx.setFillColor(color(0xFFFFFF, 0.12 - CGFloat(i) * 0.03)); ctx.fillPath()
    }
    ctx.restoreGState()

    // İnce iç kenar: koyu zeminde simgenin sınırı okunur.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1, dy: 1), cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.10)); ctx.setLineWidth(2); ctx.strokePath()

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let iconset = output.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil başarısız") }
print("AppIcon.icns yazıldı")
