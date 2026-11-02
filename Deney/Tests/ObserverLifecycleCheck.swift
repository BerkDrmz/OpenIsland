import Foundation
import Observation

/// Gerçek `Observer` (PanelKit.swift) göster/gizle sözleşmesi: değişmeyen değerler için her gösterim yeni bir
/// Observation kaydı eklememeli (kayıtlar tetiklenene kadar registrar'da kalır), değişiklikler yalnız görünürken
/// uygulanmalı ve yeniden gösterimde güncel değer uygulanmalı.
@Observable @MainActor final class Probe { var value = 0 }

@MainActor func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

@main @MainActor enum ObserverLifecycleCheck {
    static func main() {
        let probe = Probe()
        var tracked = 0, applied: [Int] = []
        let observer = Observer(track: { tracked += 1; _ = probe.value }, apply: { applied.append(probe.value) })
        for _ in 0..<1000 { observer.start(); observer.stop() }
        precondition(tracked == 1, "her gösterim yeni kayıt ekledi: \(tracked)")
        precondition(applied.count == 1000 && applied.allSatisfy { $0 == 0 }, "gösterimde uygulama eksik")

        observer.start(); applied.removeAll()
        probe.value = 1; drain()
        precondition(applied == [1] && tracked == 2, "görünürken değişiklik bir kez uygulanmadı: \(applied) \(tracked)")

        observer.stop(); applied.removeAll()
        probe.value = 2; drain()
        precondition(applied.isEmpty && tracked == 2, "gizliyken değişiklik uygulandı: \(applied)")
        observer.start()
        precondition(applied == [2] && tracked == 3, "yeniden gösterimde güncel değer uygulanmadı: \(applied) \(tracked)")
        probe.value = 3; drain()
        precondition(applied == [2, 3] && tracked == 4, "yeniden kayıt sonrası değişiklik kaçtı: \(applied) \(tracked)")

        // Bildirim kuyruktayken gizle/göster: kayıt kaybolmamalı, tek kayıt kalmalı.
        applied.removeAll()
        probe.value = 4; observer.stop(); observer.start(); drain()
        precondition(applied == [4, 4] && tracked == 5, "kuyruktaki bildirim sonrası kayıt kayboldu: \(applied) \(tracked)")
        probe.value = 5; drain()
        precondition(applied == [4, 4, 5] && tracked == 6, "kuyruk sonrası değişiklik kaçtı: \(applied) \(tracked)")
        print("observer lifecycle: 1000 göster/gizle → 1 kayıt; görünür/gizli/kuyruk sözleşmesi geçti")
    }
}
