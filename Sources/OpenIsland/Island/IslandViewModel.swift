import AppKit
import IslandCore
import SwiftUI

/// Saf `IslandMachine` ile SwiftUI arasındaki köprü.
///
/// Render maliyeti için gözlemlenen durum parçalara ayrılmıştır: makinenin kendisi gözlemlenmez;
/// yalnızca değişen türetilmiş değerler (`presentation`, `layout`, `hud`, `isPinned`, `isRelaxing`)
/// yayınlanır. Böylece örneğin bir HUD seviye değişimi genişletilmiş içeriği yeniden çizdirmez.
///
/// Pencere artık animasyon sırasında yeniden boyutlanmadığından "yerleşim oturdu" gibi pencere
/// senkronizasyon geri çağrılarına gerek yoktur; denetleyici yalnızca hedef yerleşimi öğrenir.
@MainActor
@Observable
final class IslandViewModel {
    @ObservationIgnored private(set) var machine: IslandMachine
    private(set) var presentation: IslandPresentation
    private(set) var layout: IslandLayout
    private(set) var hud: HUDPayload?
    private(set) var notice: IslandNotice?
    private(set) var isPinned = false
    private(set) var isRelaxing = false
    /// Pil tasarrufu etkin (Düşük Güç Modu / ısınma): müzik nabzı sakin formda sabit kalır.
    var energySaving = false

    var metrics: NotchMetrics {
        didSet {
            guard metrics != oldValue else { return }
            layout = IslandLayoutEngine.layout(for: presentation, metrics: metrics)
        }
    }

    @ObservationIgnored var hapticsEnabled = true
    @ObservationIgnored private let hapticPerformer: (NSHapticFeedbackManager.FeedbackPattern) -> Void
    /// Kullanıcının seçtiği stil; sistemin "Hareketi Azalt" ayarı her zaman önceliklidir.
    var motionStyle: MotionStyle = .expressive
    @ObservationIgnored var onPhaseChange: ((_ old: IslandPhase, _ new: IslandPhase) -> Void)?
    /// Hedef yerleşim değiştiğinde (girdi sensörü ve hover bölgesi güncellenir).
    @ObservationIgnored var onLayoutChange: ((_ new: IslandLayout) -> Void)?
    /// Yalnızca tanılama modunda: SwiftUI'nin adayı çizdiği dikdörtgen (hosting view koordinatları).
    @ObservationIgnored var onRenderedFrame: ((CGRect) -> Void)?

    @ObservationIgnored private var timers: [IslandTimer: (token: UInt64, task: Task<Void, Never>)] = [:]
    /// Yeniden-giriş koruması: bir olay işlenirken geri çağrılardan (ör. yerleşim değişiminde imleç
    /// doğrulaması) gelen yeni olaylar sıraya alınır ve dıştaki olay tamamen bittikten sonra işlenir.
    /// Böylece dıştaki çağrı eski durumla `isRelaxing` yazmaz veya bayat faz bildirmez.
    @ObservationIgnored private var isProcessing = false
    @ObservationIgnored private var pendingEvents: [IslandEvent] = []

    init(metrics: NotchMetrics, configuration: IslandConfiguration,
         hapticPerformer: @escaping (NSHapticFeedbackManager.FeedbackPattern) -> Void = {
             NSHapticFeedbackManager.defaultPerformer.perform($0, performanceTime: .now)
         }) {
        let machine = IslandMachine(configuration: configuration)
        self.machine = machine
        self.metrics = metrics
        self.hapticPerformer = hapticPerformer
        presentation = machine.presentation
        layout = IslandLayoutEngine.layout(for: machine.presentation, metrics: metrics)
    }

    func configure(_ configuration: IslandConfiguration) {
        machine.configuration = configuration
        for (timer, pending) in timers where !machine.isTimerCurrent(timer, token: pending.token) {
            pending.task.cancel()
            timers[timer] = nil
        }
    }

    var pendingEffectCount: Int { timers.count }

    func cancelPendingEffects() {
        timers.values.forEach { $0.task.cancel() }
        timers.removeAll()
        pendingEvents.removeAll()
    }

    private var resizeAnimation: Animation {
        IslandMotion.resize(style: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .reduced : motionStyle)
    }

    /// İçerik miktarı değişti (ör. panoya öğe eklendi): ada açıksa görünür gövde yeni boyuta yay ile morph eder.
    /// Görsel panelin tuvali içerikten bağımsızdır; pencere yeniden boyutlanmaz.
    func updateContent(_ content: ExpandedContent) {
        guard metrics.content != content else { return }
        withAnimation(resizeAnimation) {
            metrics.content = content
        }
    }

    func send(_ event: IslandEvent) {
        pendingEvents.append(event)
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        while !pendingEvents.isEmpty {
            process(pendingEvents.removeFirst())
        }
    }

    private func process(_ event: IslandEvent) {
        let previousPhase = machine.phase
        var next = machine
        let effects = next.send(event)
        machine = next
        for (timer, pending) in timers where !next.isTimerCurrent(timer, token: pending.token) {
            pending.task.cancel()
            timers[timer] = nil
        }

        let newPresentation = next.presentation
        let newLayout = IslandLayoutEngine.layout(for: newPresentation, metrics: metrics)
        let style: MotionStyle = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .reduced : motionStyle
        let layoutChanged = newLayout != layout
        if layoutChanged || newPresentation != presentation || next.hud != hud || next.notice != notice || next.context.isPinned != isPinned {
            let animation = IslandMotion.morph(from: presentation, to: newPresentation, style: style)
            withAnimation(animation) {
                if newPresentation != presentation { presentation = newPresentation }
                if layoutChanged { layout = newLayout }
                if next.hud != hud { hud = next.hud }
                if next.notice != notice { notice = next.notice }
                if next.context.isPinned != isPinned { isPinned = next.context.isPinned }
            }
            if layoutChanged { onLayoutChange?(newLayout) }
        }

        if next.isRelaxing != isRelaxing {
            withAnimation(style == .reduced ? IslandMotion.reduced : IslandMotion.relax) { isRelaxing = next.isRelaxing }
        }
        if previousPhase != next.phase { onPhaseChange?(previousPhase, next.phase) }

        for effect in effects {
            switch effect {
            // Deliver the state machine's one opening feedback while the input is current.
            // Animation completion can arrive after the finger has left the trackpad.
            case .haptic(let moment): playHaptic(moment)
            case let .schedule(timer, token, delay): schedule(timer, token: token, after: delay)
            }
        }
    }

    private func schedule(_ timer: IslandTimer, token: UInt64, after delay: TimeInterval) {
        timers[timer]?.task.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.timers[timer] = nil
            self?.send(.timerFired(timer, token: token))
        }
        timers[timer] = (token, task)
    }

    /// Gerçek açılma ve etkileşim başına bir kez; kısa veya yinelenen hover olayları efekt üretmez.
    private func playHaptic(_ moment: HapticMoment) {
        guard hapticsEnabled else { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern = switch moment {
        case .expanded, .dropLocked: .alignment
        case .dropCompleted: .levelChange
        case .pinChanged: .generic
        }
        hapticPerformer(pattern)
    }
}
