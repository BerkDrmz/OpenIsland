import AppKit

/// Adanın sağ tık (veya Control-tık) menüsü: dinlenmede görünmez sensörde, açıkken panelin kendi menüsü
/// olmayan alanlarında. Raf öğeleri ve metin alanları gibi içerikler kendi menülerini göstermeye devam eder.
/// Menü açıkken ada kapanmaz (`IslandHold`): imleç menüye giderken adadan çıksa da yerinde kalır.
@MainActor
final class IslandContextMenu: NSObject, NSMenuDelegate {
    /// Menü kapandı. Menü izleme döngüsü sürerken AppKit adanın hover çıkış olayını teslim etmeyebiliyor
    /// (cihazda: imleç menü öğesine giderken çıkış kayboldu, ada "imleç içeride" sanıp açık kaldı);
    /// sahip, imlecin gerçek konumunu burada bir kez doğrular.
    var onClose: (() -> Void)?

    private let model: IslandViewModel
    private let environment: AppEnvironment

    init(model: IslandViewModel, environment: AppEnvironment) {
        self.model = model
        self.environment = environment
    }

    /// Menü her açılışta o anki duruma göre yeniden kurulur (işaretler güncel kalır).
    func make() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let model = model, environment = environment
        let isExpanded = model.machine.isExpanded
        menu.addItem(ActionItem(isExpanded ? "Adayı kapat" : "Adayı aç") {
            model.send(isExpanded ? .escapePressed : .tapped)
        })
        menu.addItem(ActionItem("Adayı açık tut", isOn: model.isPinned) { model.send(.togglePin) })
        menu.addItem(ActionItem("Demo modu", isOn: environment.preferences.demoMode) {
            environment.preferences.demoMode.toggle()
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Araçlar…") { environment.maintenance.open() })
        menu.addItem(ActionItem("Ayarlar…") { environment.openSettings() })
        menu.addItem(ActionItem("OpenIsland'den Çık") { NSApp.terminate(nil) })
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) { environment.hold.begin() }
    func menuDidClose(_ menu: NSMenu) {
        environment.hold.end()
        onClose?()
    }
}

/// Eylemi kapanış olarak taşıyan menü öğesi.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, isOn: Bool? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        target = self
        if let isOn { state = isOn ? .on : .off }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) desteklenmiyor") }

    @objc private func runHandler() { handler() }
}
