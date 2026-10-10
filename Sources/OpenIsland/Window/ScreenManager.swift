import AppKit
import IslandCore

/// Bir ekranın ada açısından önemli geometrisi. Tüm dikdörtgenler AppKit global ekran
/// koordinatlarındadır (sol-alt orijin, birincil ekranın sol-alt köşesi = 0,0).
struct NotchScreen: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let isBuiltIn: Bool
    /// Donanım çentiğinin ekrandaki dikdörtgeni; çentiksiz ekranlarda `nil`.
    let notchRect: CGRect?
    let menuBarHeight: CGFloat
    /// Retina ölçeği (piksel hizalama için).
    let backingScale: CGFloat

    var hasNotch: Bool { notchRect != nil }

    var metrics: NotchMetrics {
        if let notchRect { return NotchMetrics(notchSize: notchRect.size, style: .notch, scale: backingScale) }
        return .pill(menuBarHeight: menuBarHeight, scale: backingScale)
    }

    /// Adanın asılacağı üst-orta nokta: **x = screen.frame.midX** (piksel hizalı), **y = screen.frame.maxY**.
    /// MacBook çentiği ekranın tam ortasındadır; `auxiliaryTopLeft/RightArea`'dan hesaplanan çentik
    /// merkezi de aynı değeri verir (tanılama modu ikisini karşılaştırır).
    var anchor: CGPoint {
        CGPoint(x: (frame.midX * backingScale).rounded() / backingScale, y: frame.maxY)
    }
}

extension DisplayTarget {
    var title: String {
        switch self {
        case .primary: "Yalnızca MacBook ekranı"
        case .allDisplays: "Tüm ekranlar"
        }
    }
}

/// Ekran ve Space değişikliklerinde, geçiş oturduktan sonra da ekran geometrisini yeniden okur.
@MainActor
@Observable
final class ScreenManager {
    private(set) var screens: [NotchScreen] = []
    @ObservationIgnored var onChange: (([NotchScreen]) -> Void)?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored var onExternalChange: ((String, DisplayChangeKind) -> Void)?
    @ObservationIgnored private var externalTransitions = ExternalDisplayTransitions([])

    private static func externalConfigurations(_ screens: [NotchScreen]) -> [ExternalDisplayConfiguration] {
        screens.filter { !$0.isBuiltIn }.map {
            ExternalDisplayConfiguration(id: $0.id, name: $0.name, x: $0.frame.minX, y: $0.frame.minY,
                width: $0.frame.width, height: $0.frame.height, scale: $0.backingScale)
        }
    }

    init() {
        screens = NSScreen.screens.map(Self.describe)
        externalTransitions = ExternalDisplayTransitions(Self.externalConfigurations(screens))
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.scheduleRefresh()
            }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }))
        }
    }

    /// Space bildirimi animasyon bitmeden gelebilir. Kalıcı yoklama yerine iptal edilebilir iki son okuma.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            for delay in [0.35, 0.9] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        observers.forEach { center, token in center.removeObserver(token) }
        observers.removeAll()
    }

    func refresh() {
        let latest = NSScreen.screens.map(Self.describe)
        guard latest != screens else { return }
        screens = latest
        onChange?(latest)
        for (name, kind) in externalTransitions.update(Self.externalConfigurations(latest)) {
            onExternalChange?(name, kind)
        }
    }

    /// Kural `DisplaySelection`'dadır: varsayılan ayarda harici monitörde ada hiç görünmez.
    func targets(for target: DisplayTarget) -> [NotchScreen] {
        let candidates = screens.map { DisplayCandidate(id: $0.id, isBuiltIn: $0.isBuiltIn, hasNotch: $0.hasNotch) }
        let ids = DisplaySelection.targets(target, among: candidates)
        return screens.filter { ids.contains($0.id) }
    }

    /// Çentik dikdörtgenini `safeAreaInsets` ve `auxiliaryTopLeft/RightArea` (macOS 12+) ile hesaplar.
    /// Çentiğin genişliği = ekran genişliği − sol yardımcı alan − sağ yardımcı alan.
    static func describe(_ screen: NSScreen) -> NotchScreen {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top

        var notchRect: CGRect?
        if topInset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let minX = frame.minX + left.width
            let maxX = frame.maxX - right.width
            if maxX > minX {
                notchRect = CGRect(x: minX, y: frame.maxY - topInset, width: maxX - minX, height: topInset)
            }
        }

        // Menü çubuğu otomatik gizliyse visibleFrame farkı 0 olur; sistem kalınlığına düş.
        let reserved = frame.maxY - screen.visibleFrame.maxY
        let menuBarHeight = reserved > 0 ? reserved : NSStatusBar.system.thickness

        return NotchScreen(
            id: displayID,
            name: screen.localizedName,
            frame: frame,
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
            notchRect: notchRect,
            menuBarHeight: menuBarHeight,
            backingScale: screen.backingScaleFactor
        )
    }
}
