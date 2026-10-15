// TabIconTint piksel denetimi: özgün renk alfası ile beyaz + katman opaklığı çizimini karşılaştırır.
// ImageRenderer, 2x ölçek, saf siyah zemin; dinlenme ve 0,48…1,0 ara alfa değerleri.
// Alt yolları üst üste binen semboller (ExpandedTab.tintsWithLayerOpacity == false) özgün renk yolunu kullanır;
// denetim bunların farklı olduğunu belgeler ve geri kalan sembollerin <=1/255 eşit olmasını şart koşar.
// Çalıştırma: swift Tools/PerformanceChecks/TabIconTintCheck.swift
import AppKit
import SwiftUI

let symbols = ["square.grid.2x2.fill", "music.note", "tray.and.arrow.down.fill", "doc.on.clipboard", "timer",
               "note.text", "person.crop.circle", "cpu"]
let colorPathSymbols = ["slider.horizontal.3"] // mixer: özgün renk animasyonu korunur
let tertiary = Color(nsColor: NSColor(name: nil) { _ in
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.7 : 0.48)
})

struct Old: View { let s: String; let color: Color
    var body: some View { ZStack { Color.black; Image(systemName: s).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).frame(width: 14, height: 24) }.frame(width: 14, height: 24) } }
struct New: View { let s: String; let alpha: Double
    var body: some View { ZStack { Color.black; Image(systemName: s).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white).opacity(alpha).frame(width: 14, height: 24) }.frame(width: 14, height: 24) } }

@MainActor func pixels<V: View>(_ v: V) -> [UInt8] {
    let r = ImageRenderer(content: v); r.scale = 2
    guard let cg = r.cgImage else { fatalError("render failed") }
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buf
}

@MainActor func run() {
    let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    print("increaseContrast=\(increased)")
    var worst = 0, total = 0, differing = 0
    for s in symbols {
        // Dinlenme: dinamik tertiary renk vs beyaz × aynı alfa; seçili: beyaz vs beyaz × 1.
        var cases: [(String, [UInt8], [UInt8])] = [
            ("rest-unselected", pixels(Old(s: s, color: tertiary)), pixels(New(s: s, alpha: increased ? 0.7 : 0.48))),
            ("rest-selected", pixels(Old(s: s, color: .white)), pixels(New(s: s, alpha: 1))),
        ]
        // Ara kareler: SwiftUI beyazın yalnızca alfasını enterpole eder; aynı alfa her iki yolda da uygulanır.
        for a in [0.48, 0.55, 0.62, 0.7, 0.78, 0.86, 0.93, 1.0] {
            cases.append(("t\(a)", pixels(Old(s: s, color: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: a))), pixels(New(s: s, alpha: a))))
        }
        for (name, a, b) in cases {
            precondition(a.count == b.count)
            var m = 0, n = 0
            for i in 0..<a.count { let d = abs(Int(a[i]) - Int(b[i])); if d > 0 { n += 1 }; m = max(m, d) }
            total += 1; if m > 0 { differing += 1 }; worst = max(worst, m)
            if m > 1 { print("DIFF \(s) \(name): max=\(m) differingBytes=\(n)") }
        }
    }
    for s in colorPathSymbols {
        let a = pixels(Old(s: s, color: tertiary)), b = pixels(New(s: s, alpha: increased ? 0.7 : 0.48))
        var m = 0; for i in 0..<a.count { m = max(m, abs(Int(a[i]) - Int(b[i]))) }
        print("color-path symbol \(s): layer-opacity would differ by \(m)/255 -> original color animation kept")
    }
    print("cases=\(total) casesWithAnyDiff=\(differing) worstChannelDiff=\(worst)/255")
    print(worst <= 1 ? "PASS (<=1/255)" : "FAIL")
}
MainActor.assumeIsolated { run() }
