import AppKit
import IslandCore
import SwiftUI

enum AppPaths { static let isRunningAsBundle = false }
enum LifecycleLog { static func note(_ message: String) {} }

// K7-P sahnesinin gerçek kodu (PanelStageView) gerçek bir pencerede: yaşam döngüsü, yerleşim, yeniden kullanım ve bırakma.
@MainActor final class Log { static var lines: [String] = [] }

struct Probe: View {
    let name: String
    @State private var appearances = 0
    var body: some View {
        Text("\(name) \(appearances)")
            .onAppear { appearances += 1; Log.lines.append("appear \(name) #\(appearances)") }
            .onDisappear { Log.lines.append("disappear \(name)") }
    }
}

@main struct PanelStageCheck {
    @MainActor static func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.alphaValue = 0
        window.orderBack(nil)
        let stage = PanelStageView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(stage)
        let rectA = CGRect(x: 40, y: 40, width: 300, height: 120)
        let rectB = CGRect(x: 20, y: 40, width: 400, height: 150)
        func key(_ tab: ExpandedTab) -> PanelStageView.Key {
            .init(tab: tab, inputs: NotchMetrics(notchSize: CGSize(width: 185, height: 32), style: .notch), style: .expressive, energySaving: false)
        }
        func show(_ tab: ExpandedTab, _ rect: CGRect) {
            stage.show(tab, key: key(tab), content: { AnyView(Probe(name: "\(tab)")) }, rect: rect, fadeIn: 0.02, fadeOut: 0.02, animated: true)
        }
        func host(at rect: CGRect) -> NSView? { stage.subviews.first { $0.frame == rect } }

        // 1. İlk gösterim: solma yok (geçişi dış görünüm yapar), son dikdörtgen, onAppear.
        show(.clipboard, rectA); spin(0.1)
        let first = stage.subviews.first
        precondition(stage.subviews.count == 1 && first?.frame == rectA && first?.layer?.opacity == 1, "First show not at final rect / opaque")
        precondition(Log.lines == ["appear clipboard #1"], "First appear wrong: \(Log.lines)")

        // 2. Geçiş: yeni host son dikdörtgende, eski host yerinde donar; sönme bitince pencereden çıkar (onDisappear).
        show(.notes, rectB)
        precondition(host(at: rectA) === first && host(at: rectB) != nil, "Old host moved or new host misplaced")
        spin(0.15)
        precondition(stage.subviews.count == 1 && stage.subviews[0].frame == rectB, "Faded host not removed")
        precondition(Log.lines.suffix(2) == ["appear notes #1", "disappear clipboard"], "Lifecycle order: \(Log.lines)")

        // 3. 2,5 sn içinde dönüş: aynı örnek yeniden kullanılır (yeniden kurulum yok), onAppear yeniden çalışır.
        show(.clipboard, rectA); spin(0.15)
        precondition(stage.subviews.first === first, "Recent host was not reused")
        precondition(Log.lines.suffix(2) == ["appear clipboard #2", "disappear notes"], "Reuse lifecycle: \(Log.lines)")

        // 4. Sönme sırasında geri dönüş: bırakma iptal edilir, örnek görünür kalır.
        show(.notes, rectB); show(.clipboard, rectA); spin(0.15)
        precondition(stage.subviews.contains { $0 === first } && first?.layer?.opacity == 1, "Retarget during fade lost the host")

        // 5. İsabet testi: host dışı noktalar sahneye ait değildir.
        precondition(stage.hitTest(CGPoint(x: 590, y: 290)) == nil, "Stage captured a point outside hosts")

        // 6. Açık oturum boyunca örnek korunur (süre sınırı yok; ölçüldü: 2,5 sn sınır 650 ms'de +%6,6 talimat).
        show(.notes, rectB); spin(0.3)
        show(.clipboard, rectA); spin(0.1)
        precondition(stage.subviews.first === first, "Host not reused within the expanded session")

        // 7. Söküm: bütün host'lar pencereden çıkar.
        stage.removeAll(); spin(0.05)
        precondition(stage.subviews.isEmpty && Log.lines.last == "disappear clipboard", "removeAll left hosts")
        // 8. Kapanıştan sonraki ilk açılış yeni örnektir (durum sıfır): ada her açılışta özgünle aynı başlar.
        show(.clipboard, rectA); spin(0.1)
        precondition(stage.subviews.first !== first && Log.lines.last == "appear clipboard #1", "Reopen reused a dismantled host")
        print("PASS PanelStage: first show opaque at final rect; old host frozen while fading then removed (onDisappear); reuse within window keeps instance and re-runs onAppear; retarget during fade; hit test; session-scoped reuse; teardown; reopen starts fresh")
    }
}
