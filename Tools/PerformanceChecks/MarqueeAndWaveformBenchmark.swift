import AppKit
import IslandCore
import QuartzCore
import SwiftUI

enum MotionStyle: Sendable { case expressive, natural, reduced }

// MARK: - Naive SwiftUI Implementations for A/B Comparative Baseline

/// Naive SwiftUI TimelineView-based Marquee (60 FPS main thread body re-evaluations)
struct SwiftUIMarqueeView: View {
    let text: String
    let font: Font
    let speed: CGFloat = 28.0
    
    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let offset = -CGFloat(elapsed * Double(speed)).truncatingRemainder(dividingBy: 300)
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .offset(x: offset)
                .frame(width: 140, alignment: .leading)
                .clipped()
        }
    }
}

/// Naive SwiftUI TimelineView-based Waveform (30 FPS main thread body re-evaluations)
struct SwiftUIWaveformView: View {
    let isPlaying: Bool
    
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { bar in
                    let phase = elapsed * 4.0 + Double(bar) * 0.5
                    let h = 4.0 + 12.0 * abs(sin(phase))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.orange)
                        .frame(width: 3, height: h)
                }
            }
            .frame(width: 25, height: 18)
        }
    }
}

// MARK: - CPU Timing Measurement Helper

func measureCPU(seconds: Double, block: @escaping () -> Void) -> (userSec: Double, sysSec: Double, cpuPercent: Double) {
    var uStart = rusage()
    getrusage(RUSAGE_SELF, &uStart)
    let startMono = ProcessInfo.processInfo.systemUptime
    
    block()
    
    // Run runloop for requested duration
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    
    let endMono = ProcessInfo.processInfo.systemUptime
    var uEnd = rusage()
    getrusage(RUSAGE_SELF, &uEnd)
    
    let userSec = Double(uEnd.ru_utime.tv_sec - uStart.ru_utime.tv_sec) + Double(uEnd.ru_utime.tv_usec - uStart.ru_utime.tv_usec) / 1_000_000.0
    let sysSec = Double(uEnd.ru_stime.tv_sec - uStart.ru_stime.tv_sec) + Double(uEnd.ru_stime.tv_usec - uStart.ru_stime.tv_usec) / 1_000_000.0
    let wallSec = endMono - startMono
    let cpuPercent = 100.0 * (userSec + sysSec) / max(0.001, wallSec)
    
    return (userSec, sysSec, cpuPercent)
}

@main
struct MarqueeAndWaveformBenchmark {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)
        
        let testDuration = 6.0
        let resultsFile = "/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261013-tab-optimization/marquee-waveform-ab-results.json"
        var results: [String: Any] = [:]
        
        print("=======================================================")
        print("MARQUEE & WAVEFORM A/B COMPARATIVE BENCHMARK")
        print("=======================================================")
        
        // -----------------------------------------------------------------
        // 1. MARQUEE COMPARISON
        // -----------------------------------------------------------------
        let longTitle = "Bohemian Rhapsody — Remastered 2011 — Queen With Extra Long Title"
        
        // 1A: Naive SwiftUI TimelineView Marquee
        print("-> Running 1A: Naive SwiftUI TimelineView Marquee (6s)...")
        let swiftUIHosting = NSHostingView(rootView: SwiftUIMarqueeView(text: longTitle, font: .system(size: 14, weight: .semibold)))
        swiftUIHosting.frame = NSRect(x: 20, y: 20, width: 140, height: 25)
        
        let m1 = measureCPU(seconds: testDuration) {
            window.contentView = swiftUIHosting
        }
        print(String(format: "   Sonuç 1A (SwiftUI): CPU: %%.2f%%%%, User: %%.3fs, Sys: %%.3fs", m1.cpuPercent, m1.userSec, m1.sysSec))
        results["marquee_swiftui"] = ["cpu_percent": m1.cpuPercent, "user_seconds": m1.userSec, "sys_seconds": m1.sysSec]
        
        window.contentView = nil
        Thread.sleep(forTimeInterval: 1.0)
        
        // 1B: Native Core Animation Marquee
        print("-> Running 1B: Native Core Animation MarqueeView (6s)...")
        let caMarquee = MarqueeLayerView()
        caMarquee.frame = NSRect(x: 20, y: 20, width: 140, height: 25)
        caMarquee.update(
            text: longTitle,
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: .white,
            speed: 28.0,
            delay: 1.0,
            trailingGap: 36.0,
            isPaused: false
        )
        
        let m2 = measureCPU(seconds: testDuration) {
            window.contentView = caMarquee
            caMarquee.layout()
        }
        caMarquee.stopAnimations()
        print(String(format: "   Sonuç 1B (CoreAnimation): CPU: %%.2f%%%%, User: %%.3fs, Sys: %%.3fs", m2.cpuPercent, m2.userSec, m2.sysSec))
        results["marquee_core_animation"] = ["cpu_percent": m2.cpuPercent, "user_seconds": m2.userSec, "sys_seconds": m2.sysSec]
        
        window.contentView = nil
        Thread.sleep(forTimeInterval: 1.0)
        
        // -----------------------------------------------------------------
        // 2. WAVEFORM COMPARISON
        // -----------------------------------------------------------------
        
        // 2A: Naive SwiftUI TimelineView Waveform
        print("-> Running 2A: Naive SwiftUI TimelineView Waveform (6s)...")
        let swiftUIWaveHosting = NSHostingView(rootView: SwiftUIWaveformView(isPlaying: true))
        swiftUIWaveHosting.frame = NSRect(x: 20, y: 20, width: 30, height: 20)
        
        let w1 = measureCPU(seconds: testDuration) {
            window.contentView = swiftUIWaveHosting
        }
        print(String(format: "   Sonuç 2A (SwiftUI): CPU: %%.2f%%%%, User: %%.3fs, Sys: %%.3fs", w1.cpuPercent, w1.userSec, w1.sysSec))
        results["waveform_swiftui"] = ["cpu_percent": w1.cpuPercent, "user_seconds": w1.userSec, "sys_seconds": w1.sysSec]
        
        window.contentView = nil
        Thread.sleep(forTimeInterval: 1.0)
        
        // 2B: Native Core Animation WaveformView
        print("-> Running 2B: Native Core Animation WaveformView (6s)...")
        let caWave = WaveformLayerView()
        caWave.frame = NSRect(x: 20, y: 20, width: 34, height: 18)
        caWave.update(isPlaying: true, color: .systemOrange, reduceMotion: false)
        
        let w2 = measureCPU(seconds: testDuration) {
            window.contentView = caWave
            caWave.layout()
        }
        caWave.stopAnimations()
        print(String(format: "   Sonuç 2B (CoreAnimation): CPU: %%.2f%%%%, User: %%.3fs, Sys: %%.3fs", w2.cpuPercent, w2.userSec, w2.sysSec))
        results["waveform_core_animation"] = ["cpu_percent": w2.cpuPercent, "user_seconds": w2.userSec, "sys_seconds": w2.sysSec]
        
        window.close()
        
        // JSON olarak kaydet
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: resultsFile))
            print("✅ Sonuçlar kaydedildi: \(resultsFile)")
        }
    }
}
