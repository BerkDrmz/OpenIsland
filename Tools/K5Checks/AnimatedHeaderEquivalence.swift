// K5 ara kare eşdeğerliği: özgün yapı (başlık + içerik, gövde genişliğinde ZStack) ile aday (sabit kutu + aynı
// transaction'da canlanan kayma ofseti + görünmez iskelet) aynı pencerede, aynı durum değişikliği ve aynı yay
// (IslandMotion.livelyResize: response 0,22, ζ 0,95, blend 0,06) ile canlanır. Her ~4 ms'de iki görünümün
// katman ağacından başlık düğmeleri ve içerik kenar işaretçilerinin konumları okunur ve karşılaştırılır.
// Senaryo: 80 ms ve 650 ms aralıklarla, dar/orta/geniş gövdeler arasında yeniden hedeflenen geçişler.
import AppKit
import SwiftUI

let tab: CGFloat = 14, spacing: CGFloat = 2.5, pin: CGFloat = 9.5 * 2.1, gap: CGFloat = 185, pad: CGFloat = 8
let canvas: CGFloat = 760
let spring = Animation.spring(response: 0.22, dampingFraction: 0.95, blendDuration: 0.06)
let leadingRow: CGFloat = 5 * tab + 4 * spacing
let trailingRow: CGFloat = 4 * (tab + spacing) + pin
let negative = ProcessInfo.processInfo.environment["NEGATIVE"] == "1" // ofset canlanmaz: fark bulunmalı

final class Box: ObservableObject { @Published var width: CGFloat = 380 }

struct Row: View {
    let tint: Double
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: spacing) { ForEach(0..<5, id: \.self) { i in Color(red: Double(i + 1) / 16, green: tint, blue: 1).frame(width: tab, height: 24) } }
                .frame(maxWidth: .infinity, alignment: .trailing)
            Color.clear.frame(width: gap)
            HStack(spacing: spacing) {
                ForEach(0..<4, id: \.self) { i in Color(red: Double(i + 8) / 16, green: tint, blue: 1).frame(width: tab, height: 24) }
                Color(red: 15 / 16, green: tint, blue: 1).frame(width: pin, height: pin)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Skeleton: View {
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: spacing) { ForEach(0..<5, id: \.self) { _ in Color.clear.frame(width: tab, height: 24) } }
                .frame(maxWidth: .infinity, alignment: .trailing)
            Color.clear.frame(width: gap)
            HStack(spacing: spacing) {
                ForEach(0..<4, id: \.self) { _ in Color.clear.frame(width: tab, height: 24) }
                Color.clear.frame(width: pin, height: pin)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Markers: View {
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

struct Original: View {
    @ObservedObject var box: Box
    var body: some View {
        ZStack(alignment: .top) {
            Row(tint: 0.25).padding(.horizontal, pad).frame(height: 32)
            Markers()
        }
        .frame(width: box.width, height: 40, alignment: .top)
        .frame(width: canvas, height: 40)
    }
}

struct Candidate: View {
    @ObservedObject var box: Box
    var body: some View {
        let shift = IslandLayoutEngine.headerRowShift(bodyWidth: box.width, sidePadding: pad, centerGap: gap,
                                                      leadingRowWidth: leadingRow, trailingRowWidth: trailingRow, scale: 2) ?? 0
        ZStack(alignment: .top) {
            Row(tint: 0.25).padding(.horizontal, pad).frame(width: canvas, height: 32)
                .offset(x: shift)
                .transaction { if negative { $0.animation = nil } }
            ZStack(alignment: .top) {
                Skeleton().padding(.horizontal, pad).frame(height: 32).hidden()
                Markers()
            }
            .frame(width: box.width, height: 40, alignment: .top)
        }
        .frame(width: canvas, height: 40, alignment: .top)
    }
}

@MainActor final class Runner {
    let box = Box()
    var window: NSWindow!
    var a: NSHostingView<Original>!, b: NSHostingView<Candidate>!
    var samples = 0, mismatches = 0, maxDelta: CGFloat = 0, moving = 0
    var last: [CGFloat] = []
    let start = Date()
    // Gövde genişlikleri: medya 380, raf/not 361, pano 370 (orta bölge), nook 604, sistem 572.
    let script: [(Double, CGFloat)] = {
        var s: [(Double, CGFloat)] = []
        var t = 0.3
        let widths: [CGFloat] = [380, 361, 370, 361, 604, 572]
        for _ in 0..<4 { for w in widths { s.append((t, w)); t += 0.08 } }      // hızlı: üst üste binen yeniden hedefleme
        for _ in 0..<2 { for w in widths { s.append((t, w)); t += 0.65 } }      // normal: oturan geçişler
        for w in [361.0, 380, 361, 370, 380, 361] as [CGFloat] { s.append((t, w)); t += 0.05 } // 50 ms
        s.append((t + 0.8, -1))
        return s
    }()

    func positions(_ v: NSView) -> [CGFloat] {
        var out: [CGFloat] = []
        func walk(_ l: CALayer, _ o: CGPoint) {
            // Sunum katmanı değil model katmanı: SwiftUI kareyi süreç içinde hesaplayıp katmanlara yazar.
            let p = CGPoint(x: o.x + l.frame.minX, y: o.y + l.frame.minY)
            if l.backgroundColor != nil, l.bounds.width < 25, l.bounds.width > 10 { out.append((p.x * 1000).rounded() / 1000) }
            for s in l.sublayers ?? [] { walk(s, p) }
        }
        if let r = v.layer { walk(r, .zero) }
        return out.sorted()
    }

    func run() {
        window = NSWindow(contentRect: CGRect(x: 60, y: 60, width: canvas, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        let stack = NSView(frame: CGRect(x: 0, y: 0, width: canvas, height: 80))
        a = NSHostingView(rootView: Original(box: box)); a.frame = CGRect(x: 0, y: 40, width: canvas, height: 40)
        b = NSHostingView(rootView: Candidate(box: box)); b.frame = CGRect(x: 0, y: 0, width: canvas, height: 40)
        stack.addSubview(a); stack.addSubview(b)
        window.contentView = stack
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        for (t, w) in script {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [self] in
                if w < 0 { finish(); return }
                withAnimation(spring) { box.width = w }
            }
        }
        tick()
    }

    func tick() {
        let pa = positions(a), pb = positions(b)
        if pa.count == 12, pb.count == 12 {
            samples += 1
            if pa != last { moving += 1; last = pa }
            let d = zip(pa, pb).map { abs($0 - $1) }.max() ?? 0
            maxDelta = max(maxDelta, d)
            if d > 0.001 { mismatches += 1; if mismatches <= 5 { print("t=\(String(format: "%.3f", Date().timeIntervalSince(start))) Δ=\(d)\n orig=\(pa)\n cand=\(pb)") } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.004) { [self] in tick() }
    }

    func finish() {
        print("samples=\(samples) distinctOriginalFrames=\(moving) mismatchedSamples=\(mismatches) maxDelta=\(maxDelta) negative=\(negative)")
        print(mismatches == 0 && moving > 50 ? "PASS" : "FAIL")
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let runner = MainActor.assumeIsolated { Runner() }
MainActor.assumeIsolated { runner.run() }
app.run()
