// K5-A eşdeğerlik denetimi (yerleşim): özgün başlık satırı yapısı (gövde genişliğinde kutu, ortalanmış) ile
// adayın sabit kutu + `IslandLayoutEngine.headerRowShift` kaymasını gerçek SwiftUI yerleşiminde karşılaştırır.
// Konumlar çizilen katman ağacından okunur (SwiftUI'nin piksel yuvarlaması dahil).
// Derleme: swiftc -O IslandCore/*.swift main.swift (bkz. run-header-equivalence.sh)
import AppKit
import SwiftUI

struct Config: Hashable { let gap: CGFloat; let pad: CGFloat; let leading: Int; let trailing: Int }

let tab: CGFloat = IslandLayoutEngine.tabButtonSize.width
let spacing: CGFloat = IslandLayoutEngine.tabSpacing
let pin: CGFloat = 9.5 * 2.1
let canvas: CGFloat = 760
/// Negatif kontrol: kayma uygulanmazsa denetim uyuşmazlık bulmalıdır.
let negativeControl = ProcessInfo.processInfo.environment["HEADER_EQ_NEGATIVE"] == "1"
/// Negatif kontrol 2: iskelet olmadan içerik genişliği dar gövdelerde farklı olmalıdır.
let negativeSkeleton = ProcessInfo.processInfo.environment["HEADER_EQ_NO_SKELETON"] == "1"

func rowWidths(_ c: Config) -> (CGFloat, CGFloat) {
    let a = c.leading > 0 ? CGFloat(c.leading) * tab + CGFloat(c.leading - 1) * spacing : 0
    let b = CGFloat(c.trailing) * (tab + spacing) + pin
    return (a, b)
}

/// Özgün yapı: `ExpandedIslandView.header` ile aynı yığın; renkler yalnızca katmanları ayırt etmek için.
struct HeaderRow: View {
    let c: Config
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: spacing) {
                ForEach(0..<c.leading, id: \.self) { i in
                    Color(red: Double(i + 1) / 16, green: 0.25, blue: 1).frame(width: tab, height: 24)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            Color.clear.frame(width: c.gap)
            HStack(spacing: spacing) {
                ForEach(0..<c.trailing, id: \.self) { i in
                    Color(red: Double(i + 8) / 16, green: 0.25, blue: 1).frame(width: tab, height: 24)
                }
                Color(red: 15 / 16, green: 0.25, blue: 1).frame(width: pin, height: pin)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Adayın iç ZStack'indeki görünmez iskelet: özgün başlıkla aynı yığın, yalnızca Color.clear kutular.
struct HeaderSkeleton: View {
    let c: Config
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: spacing) { ForEach(0..<c.leading, id: \.self) { _ in Color.clear.frame(width: tab, height: 24) } }
                .frame(maxWidth: .infinity, alignment: .trailing)
            Color.clear.frame(width: c.gap)
            HStack(spacing: spacing) {
                ForEach(0..<c.trailing, id: \.self) { _ in Color.clear.frame(width: tab, height: 24) }
                Color.clear.frame(width: pin, height: pin)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Panel içeriğinin yerini temsil eder: sol ve sağ kenarında 12 pt işaretçi (içerik genişliğini ölçer).
struct ContentMarkers: View {
    var body: some View {
        HStack(spacing: 0) {
            Color(red: 0.2, green: 0.9, blue: 0.1).frame(width: 12, height: 4)
            Spacer(minLength: 0)
            Color(red: 0.3, green: 0.9, blue: 0.1).frame(width: 12, height: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
    }
}

struct Rows: View {
    let c: Config
    let widths: [CGFloat]
    let candidate: Bool
    var body: some View {
        VStack(spacing: 0) {
            ForEach(widths, id: \.self) { w in
                if candidate {
                    let (a, b) = rowWidths(c)
                    let shift = IslandLayoutEngine.headerRowShift(bodyWidth: w, sidePadding: c.pad, centerGap: c.gap,
                                                                 leadingRowWidth: a, trailingRowWidth: b, scale: 2).map { negativeControl ? 0 : $0 } ?? .nan
                    ZStack(alignment: .top) {
                        HeaderRow(c: c).padding(.horizontal, c.pad).frame(width: canvas, height: 32)
                            .offset(x: shift)
                        ZStack(alignment: .top) {
                            if !negativeSkeleton { HeaderSkeleton(c: c).padding(.horizontal, c.pad).frame(height: 32).hidden() }
                            ContentMarkers()
                        }
                        .frame(width: w, height: 32, alignment: .top)
                    }
                    .frame(width: canvas, height: 32, alignment: .top)
                } else {
                    ZStack(alignment: .top) {
                        HeaderRow(c: c).padding(.horizontal, c.pad).frame(height: 32)
                        ContentMarkers()
                    }
                    .frame(width: w, height: 32, alignment: .top)
                    .frame(width: canvas, height: 32)
                }
            }
        }
    }
}

@MainActor let sharedHost: NSHostingView<AnyView> = {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: canvas, height: 32), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderBack(nil)
    return host
}()

@MainActor func positions(_ view: some View, rows: Int) -> [[CGFloat]] {
    let host = sharedHost
    let size = CGSize(width: canvas, height: CGFloat(rows) * 32)
    host.window?.setContentSize(size)
    host.frame = CGRect(origin: .zero, size: size)
    host.rootView = AnyView(view)
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.12))
    var out = [[CGFloat]](repeating: [], count: rows)
    func walk(_ layer: CALayer, _ origin: CGPoint) {
        let o = CGPoint(x: origin.x + layer.frame.minX, y: origin.y + layer.frame.minY)
        if layer.backgroundColor != nil, layer.bounds.width < 25, layer.bounds.width > 10 {
            let row = Int((o.y + layer.bounds.height / 2) / 32)
            if row >= 0, row < rows { out[row].append(o.x) }
        }
        for s in layer.sublayers ?? [] { walk(s, o) }
    }
    if let root = host.layer { walk(root, .zero) }
    host.rootView = AnyView(EmptyView())
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    return out.map { $0.sorted() }
}

@MainActor func run() {
    var configs: [Config] = []
    for gap in [185.0, 200.0, 12.0] as [CGFloat] {
        for pad in [8.0, 12.0] as [CGFloat] {
            for l in 0...5 { for t in 0...4 { configs.append(Config(gap: gap, pad: pad, leading: l, trailing: t)) } }
        }
    }
    var compared = 0, mismatches = 0, nilCount = 0, shiftedRows = 0
    for c in configs {
        let (a, b) = rowWidths(c)
        // En az 60 pt: içerik işaretçileri (2 × 12 pt, 16 pt yan boşluk) ayrışabilsin; uygulamada gövde ≥ ~200 pt.
        let low = max(c.gap + 2 * c.pad + 10, 60)
        let high = c.gap + 2 * c.pad + 2 * max(a, b) + 12
        let widths = stride(from: (low).rounded(), through: (high).rounded(), by: 1).map { CGFloat($0) }
        var lo = 0
        while lo < widths.count {
            let chunk = Array(widths[lo..<min(lo + 150, widths.count)])
            let orig = positions(Rows(c: c, widths: chunk, candidate: false), rows: chunk.count)
            let cand = positions(Rows(c: c, widths: chunk, candidate: true), rows: chunk.count)
            for (i, w) in chunk.enumerated() {
                let shift = IslandLayoutEngine.headerRowShift(bodyWidth: w, sidePadding: c.pad, centerGap: c.gap,
                                                             leadingRowWidth: a, trailingRowWidth: b, scale: 2)
                guard let shift else { nilCount += 1; continue }
                if shift != 0 { shiftedRows += 1 }
                compared += 1
                let o = orig[i]
                let n = cand[i]
                if o.count != c.leading + c.trailing + 3 || o != n {
                    mismatches += 1
                    if mismatches <= 15 { print("MISMATCH \(c) w=\(w) shift=\(shift)\n  orig=\(o)\n  cand=\(n)") }
                }
            }
            lo += 150
        }
    }
    print("configs=\(configs.count) comparedRows=\(compared) shiftedRows=\(shiftedRows) fallbackRows=\(nilCount) mismatches=\(mismatches)")
    print(mismatches == 0 && compared > 0 ? "PASS" : "FAIL")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated { run() }
