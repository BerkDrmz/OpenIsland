import AppKit
import IslandCore
import SwiftUI

/// Sekme içerikleri her seçimde `.id(tab)` ile sıfırdan kurulmak yerine her sekme için **kalıcı** bir `NSHostingView`'da.
///
/// Ölçüm: 80 ms hızlı geçişte panelin sıfırdan kurulması (görünüm grafiği, platform görünümleri, metin ölçümü) seçimden
/// sonraki ilk karede 70–160M talimat; toplam iş azaldıkça bu patlama daha sık E-çekirdekte/düşük frekansta yürüyüp kare
/// süresini kaçırıyordu (Animation Hitches). Kalıcı host ilk kare işini yarıdan fazla azaltır.
///
/// Eşdeğerlik: SwiftUI'de `.id` değişiminde eski içerik eski konumunda donarak söner, yeni içerik ilk karede son konumunda
/// belirir (`RemovalSemantics` deneyi). Sahne aynı davranışı üretir: etkin host son içerik dikdörtgeninde, sönen host kendi
/// dikdörtgeninde kalır; saydamlık aynı süre/eğriyle CA'da canlanır. Gizlenen host pencereden çıkarılır: SwiftUI
/// `onDisappear` çalışır ve `task`'lar iptal edilir; yeniden eklenince `onAppear` yeniden çalışır (`HostLifecycle`
/// deneyi). Fark: panel içi `@State` (kaydırma, hover, taslak) aynı açık oturum boyunca korunur; ada kapanınca bütün
/// host'lar bırakılır ve her açılış özgünle aynı başlar. Erişilebilirlik ve klavye: `PanelHostingView`, `PanelAXOrder`,
/// `NotchPanel.invalidateKeyViewLoop`. Host'u süreyle bırakmak (2,5 sn) ölçüldü: 650 ms'de her dönüşte yeni host
/// kurulduğu için +%6,6 talimat; reddedildi.
struct PanelStage: NSViewRepresentable {
    let tab: ExpandedTab
    /// Etkin içeriğin sahnedeki dikdörtgeni (sahne = sabit genişlikli dış çerçeve, üst kenarı sabit).
    let contentRect: CGRect
    let motionStyle: MotionStyle
    let energySaving: Bool
    /// İçeriğin girdileri (ölçüler vb.); `rootView` yalnızca bu değişince yeniden atanır. Paneller verilerini kendi
    /// modellerinden (Observation) okur, bu yüzden veri değişimi için yeniden atama gerekmez.
    let inputs: NotchMetrics
    let make: (ExpandedTab) -> AnyView

    func makeNSView(context: Context) -> PanelStageView { PanelStageView() }

    /// Boyut her zaman dış çerçeveden gelir; AppKit'e içsel boyut sorulmaz (kök yerleşim önbelleği bozulmasın).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PanelStageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func updateNSView(_ view: PanelStageView, context: Context) {
        let lively = motionStyle == .expressive
        let fadeIn = motionStyle == .reduced ? 0.10 : (lively ? 0.12 : 0.15)
        let fadeOut = motionStyle == .reduced ? 0.06 : (lively ? 0.08 : 0.10)
        let key = PanelStageView.Key(tab: tab, inputs: inputs, style: motionStyle, energySaving: energySaving)
        let content = { AnyView(
            make(tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea()
                .foregroundStyle(IslandPalette.primary)
                .environment(\.islandMotionStyle, motionStyle)
                .environment(\.islandEnergySaving, energySaving)
                .environment(\.colorScheme, .dark)
        ) }
        view.show(tab, key: key, content: content, rect: contentRect, fadeIn: fadeIn, fadeOut: fadeOut,
                  animated: context.transaction.animation != nil || !context.transaction.disablesAnimations)
    }

    static func dismantleNSView(_ view: PanelStageView, coordinator: ()) {
        view.removeAll()
    }
}

final class PanelStageView: NSView {
    struct Key: Equatable {
        let tab: ExpandedTab
        let inputs: NotchMetrics
        let style: MotionStyle
        let energySaving: Bool
    }

    private final class Entry {
        let host: PanelHostingView
        var rect: CGRect
        var key: Key
        var removal: DispatchWorkItem?
        init(host: PanelHostingView, rect: CGRect, key: Key) { self.host = host; self.rect = rect; self.key = key }
    }

    /// Yaşam döngüsü yan etkisi olmayan paneller pencerede gizli kalır (yeniden takma maliyeti yok). Diğerleri
    /// pencereden çıkarılır: `onAppear`/`onDisappear` (örnekleme, kamera, konum izleme) özgün anlarda çalışır.
    private static let staysInWindow: Set<ExpandedTab> = [] // ölçüldü: gizli host'lar pencerede kalınca her karede güncelleniyor (+%41 talimat)

    private var entries: [ExpandedTab: Entry] = [:]
    private var active: ExpandedTab?

    override var isFlipped: Bool { true }

    /// Yalnızca bir host'un içine düşen noktalar bu görünüme aittir; başlık ve boş alanlar alttaki/üstteki SwiftUI'ye geçer.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func show(_ tab: ExpandedTab, key: Key, content: () -> AnyView, rect: CGRect, fadeIn: Double, fadeOut: Double, animated: Bool) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let aligned = CGRect(x: (rect.minX * scale).rounded() / scale, y: (rect.minY * scale).rounded() / scale,
                             width: (rect.width * scale).rounded() / scale, height: (rect.height * scale).rounded() / scale)
        if active == tab, let entry = entries[tab] {
            if entry.key != key { entry.key = key; entry.host.rootView = content() }
            if entry.rect != aligned { entry.rect = aligned; entry.host.frame = aligned }
            return
        }
        // İlk gösterim genişletilmiş görünümle birlikte gelir: içerik ayrıca solmaz (geçişi dış görünüm yapar).
        let isFirst = active == nil
        // Önceki etkin içerik: kendi dikdörtgeninde kalır ve söner, sonunda pencereden çıkarılır (onDisappear).
        if let previous = active, let old = entries[previous] {
            fade(old.host, to: 0, duration: animated ? fadeOut : 0, timing: .easeIn)
            let work = DispatchWorkItem { [weak self, weak old] in
                guard let self, let old, self.active != previous else { return }
                if Self.staysInWindow.contains(previous) { old.host.isHidden = true } else { old.host.removeFromSuperview() }
                old.removal = nil
            }
            old.removal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? fadeOut : 0), execute: work)
        }
        active = tab
        let entry: Entry
        if let existing = entries[tab] {
            entry = existing
            entry.removal?.cancel(); entry.removal = nil
            if entry.key != key { entry.key = key; entry.host.rootView = content() }
        } else {
            let host = PanelHostingView(rootView: content())
            host.sizingOptions = [] // çerçeve sahneden gelir; içsel boyut kısıtı eklenmez
            host.wantsLayer = true
            entry = Entry(host: host, rect: aligned, key: key)
            entries[tab] = entry
        }
        entry.rect = aligned
        entry.host.frame = aligned
        if entry.host.superview !== self || entry.host.isHidden {
            entry.host.layer?.opacity = isFirst ? 1 : 0
            if entry.host.superview !== self { addSubview(entry.host) }
            entry.host.isHidden = false
        }
        fade(entry.host, to: 1, duration: animated && !isFirst ? fadeIn : 0, timing: .easeOut)
    }

    func removeAll() {
        for entry in entries.values { entry.removal?.cancel(); entry.host.removeFromSuperview() }
        entries.removeAll()
        active = nil
    }

    private func fade(_ host: NSView, to target: Float, duration: Double, timing: CAMediaTimingFunctionName) {
        guard let layer = host.layer else { return }
        let current = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "panelFade")
        layer.opacity = target
        guard duration > 0, current != target else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = current
        animation.toValue = target
        animation.duration = duration * Double(abs(target - current))
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        layer.add(animation, forKey: "panelFade")
    }
}

/// Panel host'u erişilebilirlikte görünmez: öğeleri tabandaki gibi doğrudan adanın "OpenIsland" kapsayıcısında,
/// başlık düğmelerinden sonra yer alır (ara grup yok). Öğelerin `AXParent` zinciri ve isabet testi tabanla aynıdır.
/// Kök `IslandHostingView` gibi ilk tıklamayı kabul eder (etkin olmayan pencerede ilk tıklama denetime ulaşır) ve
/// çentik bölgesinin safe-area boşluğunu yok sayar. Sağ tık, SwiftUI menüsü yoksa yanıtlayıcı zinciriyle kök host'un
/// ada menüsüne ulaşır.
final class PanelHostingView: NSHostingView<AnyView> {
    override func isAccessibilityElement() -> Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

/// Kalıcı panel host'unun en üst düzeyinde SwiftUI erişilebilirlik öğelerini konuma göre sıralar (tabandaki kök `.contain`
/// kapsayıcısı ağaç sırası verir). Sütunlu panellerde sütunlara azalan öncelik verilerek özgün ağaç sırası korunur;
/// sütun içinde konum sırası ağaç sırasıyla aynıdır. Öncelik yalnız sıralamayı etkiler (görünüm, isabet ve odak aynı).
enum PanelAXOrder {
    static let first: Double = 3
    static let second: Double = 2
    static let third: Double = 1
}
