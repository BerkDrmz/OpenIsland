import Foundation

// MARK: - Durum modeli

/// Genişletilmiş panelde gösterilen sekmeler.
public enum ExpandedTab: String, CaseIterable, Sendable, Codable, Hashable {
    /// NotchNook'taki ana görünüm: kullanıcının seçip sıraladığı widget'lar yan yana.
    case nook
    case media, shelf, clipboard, focus, notes, mirror, system, mixer
}

/// Ada kapalıyken "kanatlarda" gösterilebilecek canlı etkinlikler (öncelik sırasıyla).
public enum CompactActivity: Sendable, Equatable, Hashable {
    /// Dosya aktarımı (indirme, AirDrop alma, Finder kopyası) — kısa ömürlü olduğu için en öncelikli.
    case transfer
    case media, timer, shelf

    /// Bildirim önceliğiyle aynı ölçek: bu değerin altındaki bildirimler etkinliğin üstüne binmez.
    public var priority: Int {
        switch self {
        case .transfer: 55
        case .timer: 25
        case .media: 15
        case .shelf: 5
        }
    }
}

public enum HUDKind: Sendable, Equatable, Hashable {
    case volume(muted: Bool)
    case brightness
    case keyboardBacklight
}

public struct HUDPayload: Sendable, Equatable, Hashable {
    public var kind: HUDKind
    /// 0...1 aralığında seviye.
    public var level: Double

    public init(kind: HUDKind, level: Double) {
        self.kind = kind
        self.level = min(max(level, 0), 1)
    }
}

/// Güç kaynağı olayları (IOKit `IOPowerSources` bildirimlerinden).
public struct PowerEvent: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        case pluggedIn, unplugged, chargingStarted, chargingStopped, low, critical, full
    }

    public var kind: Kind
    /// 0...1
    public var level: Double
    public var isCharging: Bool

    public init(kind: Kind, level: Double, isCharging: Bool) {
        self.kind = kind
        self.level = min(max(level, 0), 1)
        self.isCharging = isCharging
    }
}

public enum AudioOutputKind: Sendable, Equatable, Hashable {
    case builtIn, airPods, airPodsPro, airPodsMax, headphones, display, airPlay, external, bluetooth
}

/// Geçici bildirimlerin ekranda kalma süreleri — tek kaynak. Süre, okunacak içerik miktarına ve bilginin
/// önemine göre seçilir; hiçbir görünüm veya servis kendi süresini tanımlamaz.
public enum NoticeTiming {
    /// Tek bakışlık onay ("Renk kopyalandı").
    public static let glance: TimeInterval = 1.4
    /// Kilit açılma geri bildirimi: genişleme + sembol geçişi + kısa tutma + kapanma.
    public static let unlock: TimeInterval = 1.1
    /// Aygıt adı + durum ("AirPods Pro · Bağlandı", "AirDrop ile gönderildi").
    public static let brief: TimeInterval = 1.8
    /// Parça değişimi: kapak + ad + sanatçı kısa görünür, sonra kompakt medyaya döner.
    public static let trackChange: TimeInterval = 2.0
    /// Okunacak kısa bir metin (indirilen dosyanın adı, biten zamanlayıcı fazı).
    public static let standard: TimeInterval = 2.4
    /// Adaptör takıldı/çıkarıldı, tam şarj.
    public static let power: TimeInterval = 2.6
    /// Düşük pil: fark edilmesi gerekir.
    public static let lowBattery: TimeInterval = 3.5
    /// Kritik pil ve yaklaşan toplantı.
    public static let important: TimeInterval = 4.0
    /// İmleç bildirimin üzerindeyken süre dolarsa bildirim kapanmaz; imleç ayrıldıktan sonra bu kadar kalır.
    public static let lingerAfterHover: TimeInterval = 0.8
}

/// Birkaç saniye görünüp kendiliğinden sönen olay bildirimi (iPhone'daki geçici Dynamic Island).
public enum IslandNotice: Sendable, Equatable, Hashable {
    case power(PowerEvent)
    /// Ses çıkışı bağlandı/ayrıldı. Pil yüzdesi için güvenilir public API olmadığından gösterilmez.
    case audioOutput(name: String, kind: AudioOutputKind, connected: Bool)
    case nowPlaying(title: String, artist: String)
    case meeting(title: String, minutes: Int)
    case timerFinished(title: String)
    case transferFinished(name: String)
    case transferEnded(name: String, outcome: TransferOutcome)
    case networkChanged(isAvailable: Bool)
    case displayChanged(name: String, kind: DisplayChangeKind)
    case colorPicked(hex: String)
    case airDropSent(count: Int)
    /// Mac'in kilidi açıldı (NotchNook'taki kilit göstergesi).
    case unlocked

    /// Ekranda kalma süresi. Değerler yalnızca `NoticeTiming`'de tanımlıdır.
    public var duration: TimeInterval {
        switch self {
        case .power(let event):
            switch event.kind {
            case .critical: NoticeTiming.important
            case .low: NoticeTiming.lowBattery
            case .pluggedIn, .unplugged, .chargingStarted, .chargingStopped, .full: NoticeTiming.power
            }
        case .meeting: NoticeTiming.important
        case .nowPlaying: NoticeTiming.trackChange
        case .timerFinished, .transferFinished, .transferEnded: NoticeTiming.standard
        case .audioOutput, .airDropSent, .networkChanged, .displayChanged: NoticeTiming.brief
        case .colorPicked: NoticeTiming.glance
        case .unlocked: NoticeTiming.unlock
        }
    }

    /// Deterministik öncelik: daha önemli bir bildirim ekrandayken daha az önemli olan onu ezmez;
    /// kanatlarda daha önemli bir canlı etkinlik (ör. indirme) varken onun üstüne binmez.
    public var priority: Int {
        switch self {
        case .power(let event):
            switch event.kind {
            case .critical: 100
            case .low: 90
            case .pluggedIn, .unplugged, .chargingStarted, .chargingStopped, .full: 50
            }
        case .meeting: 80
        case .timerFinished: 60
        case .transferFinished, .transferEnded: 45
        case .networkChanged, .displayChanged: 40
        case .audioOutput: 40
        case .airDropSent: 35
        // Kilit açılma kısa, bölünmez bir sistem geri bildirimidir: aktarım (55) ve düşük öncelikli
        // bildirimlerce bastırılmaz/ezilmez; yalnızca pil, toplantı ve zamanlayıcı gibi daha önemli olaylar üstüne çıkar.
        case .unlocked: 70
        case .nowPlaying: 20
        case .colorPicked: 10
        }
    }

    /// Tam ekranda bile gösterilen bildirimler (kullanıcının hemen bilmesi gerekenler).
    public var isUrgent: Bool {
        if case .power(let event) = self { return event.kind == .critical || event.kind == .low }
        return false
    }
}

/// Makinenin kalıcı fazı. HUD ve bildirimler faz değil, fazın üzerine binen geçici katmanlardır.
public enum IslandPhase: Sendable, Equatable, Hashable {
    case idle
    case compact(CompactActivity)
    case peek
    case expanded(ExpandedTab)
    case dropTarget
}

/// View katmanının çizdiği nihai görünüm: faz + HUD katmanının birleşimi.
public enum IslandPresentation: Sendable, Equatable, Hashable {
    case idle
    case compact(CompactActivity)
    case peek(CompactActivity?)
    case hud(HUDPayload)
    case notice(IslandNotice)
    case expanded(ExpandedTab)
    case dropTarget
}

// MARK: - Olaylar ve yan etkiler

public enum IslandTimer: Sendable, Equatable, Hashable {
    case hoverExpand
    case collapseGrace
    case hudDismiss
    case noticeDismiss
    case dragExitGrace
    /// Duraklatılan medyanın kompakt kanatta kalma süresi doldu.
    case mediaLinger
}

/// Dokunsal geri bildirimin anlamlı olduğu fiziksel anlar. Hover gibi sürekli olaylar bilinçli olarak yok.
public enum HapticMoment: Sendable, Equatable, Hashable {
    /// Ada tam genişlemiş konuma oturdu (animasyon mantıksal olarak bittiğinde çalınır).
    case expanded
    /// Sürüklenen dosya adaya "kilitlendi".
    case dropLocked
    /// Bırakma tamamlandı.
    case dropCompleted
    case pinChanged
}

public enum IslandEvent: Sendable, Equatable {
    case pointerEntered
    case pointerExited
    /// Kapalı/peek durumdaki adaya tıklama.
    case tapped
    /// Ada açıkken dışarıya tıklama.
    case tappedOutside
    case escapePressed
    case selectTab(ExpandedTab)
    case togglePin
    case mediaPlaybackChanged(isPlaying: Bool)
    /// Çalan parça kalmadı (oynatıcı durdu veya kapandı): duraklatma beklemesi beklenmeden kanat kalkar.
    case mediaSessionEnded
    case timerRunningChanged(isRunning: Bool)
    case shelfCountChanged(Int)
    case transferActiveChanged(isActive: Bool)
    /// Quick Look, AirDrop sayfası, dosya seçici gibi adadan açılan sistem arayüzleri görünürken
    /// adanın kapanmasını geçici olarak engeller (kullanıcıya görünen pin'den bağımsız).
    case holdChanged(isHeld: Bool)
    /// Demo modu (ekran kaydı, sunum): ada kendiliğinden kapanmaz ve duraklatılan medya kanatta kalır.
    /// Kullanıcının kendi kapatması (Esc, kısayol, sağ tık menüsü) çalışmaya devam eder; kalıcı bir ayar değildir.
    case demoModeChanged(isOn: Bool)
    /// Adanın ekranında tam ekran bir uygulama öne geldi/çıktı: canlı etkinlikler ve bildirimler
    /// içeriği örtmesin diye gizlenir (hover ile açılma çalışmaya devam eder).
    case fullscreenChanged(isFullscreen: Bool)
    case noticeRequested(IslandNotice)
    /// Ekran kilitlendi / oturum arka plana alındı: yarım kalan kilit açılma geri bildirimi iptal edilir ve
    /// (sabitlenmemişse) açık ada kapanır; kilit açılınca temiz durumdan başlanır.
    case systemLocked
    /// Dosya sürüklemesi adanın üzerine girdi (native drag destination).
    case fileDragEntered
    /// Sürükleme adanın dışına çıktı; kısa bir tolerans sonrası vazgeçilmiş sayılır.
    case fileDragExited
    case fileDragEnded(dropped: Bool)
    case hudRequested(HUDPayload)
    case timerFired(IslandTimer, token: UInt64)
}

/// Reducer saf kalır; zamanlayıcı ve dokunsal geri bildirim gibi işler efekt olarak döner.
public enum IslandEffect: Sendable, Equatable {
    case schedule(IslandTimer, token: UInt64, after: TimeInterval)
    case haptic(HapticMoment)
}

public struct IslandConfiguration: Sendable, Equatable {
    public var expandsOnHover: Bool
    public var hoverExpandDelay: TimeInterval
    /// İmleç ayrıldıktan sonra kapanmadan önceki "sönümlenme" süresi.
    public var collapseGraceDelay: TimeInterval
    public var dropConfirmationDelay: TimeInterval
    public var dragExitGraceDelay: TimeInterval
    public var hudDuration: TimeInterval
    /// Müzik duraklatılınca kompakt medya bu kadar kalır: çubuklar sakin forma yerleşir; bu sürede yeniden
    /// çalınırsa kanat kapanıp açılmaz, nabız sakin formdan desene döner. Süre dolunca ada çentiğe döner.
    public var pausedMediaLinger: TimeInterval

    public init(
        expandsOnHover: Bool = true,
        hoverExpandDelay: TimeInterval = 0.10,
        collapseGraceDelay: TimeInterval = 0.35,
        dropConfirmationDelay: TimeInterval = 1.4,
        dragExitGraceDelay: TimeInterval = 0.45,
        hudDuration: TimeInterval = 1.6,
        pausedMediaLinger: TimeInterval = 3.0
    ) {
        self.expandsOnHover = expandsOnHover
        self.hoverExpandDelay = hoverExpandDelay
        self.collapseGraceDelay = collapseGraceDelay
        self.dropConfirmationDelay = dropConfirmationDelay
        self.dragExitGraceDelay = dragExitGraceDelay
        self.hudDuration = hudDuration
        self.pausedMediaLinger = pausedMediaLinger
    }
}

public struct IslandContext: Sendable, Equatable {
    public fileprivate(set) var isHovering = false
    public fileprivate(set) var isPinned = false
    public fileprivate(set) var isHeld = false
    public fileprivate(set) var isDemoMode = false
    public fileprivate(set) var isMediaPlaying = false
    /// Duraklatılan medya kısa bir süre daha kompakt kanatta gösteriliyor (bkz. `pausedMediaLinger`).
    public fileprivate(set) var isMediaLingering = false
    public fileprivate(set) var isTransferActive = false
    public fileprivate(set) var isFullscreen = false
    public fileprivate(set) var isTimerRunning = false
    public fileprivate(set) var shelfItemCount = 0
    public fileprivate(set) var isFileDragActive = false
    /// Kapanma zamanlayıcısı kurulu (imleç ayrıldı, tolerans süresi işliyor).
    public fileprivate(set) var isCollapsePending = false
    public fileprivate(set) var lastTab: ExpandedTab = .nook
}

// MARK: - Durum makinesi

/// Adanın tüm davranışını belirleyen, yan etkisiz durum makinesi.
///
/// ```
///            hover                 tap / hover-dwell
///  idle ─────────────▶ peek ───────────────────────▶ expanded(tab)
///   ▲  ◀─────────────   │  ◀── exit + decay (grace) ───┘   ▲
///   │      exit         │                                 │ drop
///   │ media/timer/shelf ▼                                 │
///  compact(activity) ◀──┘      fileDragEntered ──▶ dropTarget
/// ```
/// HUD (ses/parlaklık) fazı değiştirmez; `presentation` içinde üst katman olarak çözülür.
/// "expanding/collapsing" gibi animasyon evreleri burada değil, view model'in transaction
/// katmanında yaşar; böylece makine küçük ve test edilebilir kalır.
public struct IslandMachine: Sendable, Equatable {
    public var configuration: IslandConfiguration
    public private(set) var phase: IslandPhase = .idle
    public private(set) var context = IslandContext()
    public private(set) var hud: HUDPayload?
    public private(set) var notice: IslandNotice?

    /// Bekleyen hover/collapse/drag zamanlayıcılarını geçersiz kılmak için artan jeton.
    private var interactionToken: UInt64 = 0
    private var hudToken: UInt64 = 0
    private var noticeToken: UInt64 = 0
    /// One bounded deferred connection feedback; it never changes the underlying phase.
    private var pendingConnectionNotice: IslandNotice?
    private var pendingUnlockNotice: IslandNotice?
    /// Bildirimin süresi imleç üzerindeyken doldu: kullanıcı okurken/etkileşirken kapatılmaz,
    /// imleç ayrılınca kısa bir gecikmeyle söner.
    private var noticeAwaitsPointerExit = false
    private var mediaToken: UInt64 = 0

    public init(configuration: IslandConfiguration = .init()) {
        self.configuration = configuration
    }

    public var isExpanded: Bool {
        if case .expanded = phase { true } else { false }
    }

    /// Kullanıcıyla etkileşimde olan fazlar (pencere kenar payı ve fare modu buna göre seçilir).
    public var isEngaged: Bool {
        switch phase {
        case .peek, .expanded, .dropTarget: true
        case .idle, .compact: false
        }
    }

    /// İmleç ayrıldı ve kapanma bekleniyor: yüzey enerjisini kaybediyormuş gibi hafifçe "söner".
    public var isRelaxing: Bool { isExpanded && context.isCollapsePending }

    /// Pin, geçici kilit veya demo modu: ada imleç ayrılsa da açık kalır.
    private var isKeptOpen: Bool { context.isPinned || context.isHeld || context.isDemoMode }

    /// Kullanıcı etkileşimi yokken adanın döneceği etkinlik
    /// (öncelik: aktarım > medya > zamanlayıcı > raf).
    public var restingActivity: CompactActivity? {
        if context.isFullscreen { return nil } // tam ekran içerik (ör. video) kanatlarla örtülmez
        if context.isTransferActive { return .transfer }
        if context.isMediaPlaying || context.isMediaLingering { return .media }
        if context.isTimerRunning { return .timer }
        if context.shelfItemCount > 0 { return .shelf }
        return nil
    }

    public var restingPhase: IslandPhase {
        restingActivity.map(IslandPhase.compact) ?? .idle
    }

    public var presentation: IslandPresentation {
        switch phase {
        case .expanded(let tab): return .expanded(tab)
        case .dropTarget: return .dropTarget
        default: break
        }
        // Katman önceliği: kullanıcının kendi eylemi (HUD) > sistem olayı (bildirim) > temel faz.
        if let hud { return .hud(hud) }
        if let notice { return .notice(notice) }
        return basePresentation
    }

    /// Geçici katmanlar olmadan fazın görünümü (girdi sensörünün boyutu buna göre seçilir:
    /// HUD veya bildirim genişlediğinde menü çubuğu öğelerinin tıklamaları engellenmez).
    public var basePresentation: IslandPresentation {
        switch phase {
        case .idle: .idle
        case .compact(let activity): .compact(activity)
        case .peek: .peek(restingActivity)
        case .expanded(let tab): .expanded(tab)
        case .dropTarget: .dropTarget
        }
    }

    @discardableResult
    public mutating func send(_ event: IslandEvent) -> [IslandEffect] {
        switch event {
        case .pointerEntered:
            guard !context.isHovering else { return [] }
            context.isHovering = true
            invalidatePendingTimers() // sönümlenmeyi ve bekleyen kapanmayı iptal eder
            switch phase {
            case .idle, .compact:
                phase = .peek
                guard configuration.expandsOnHover else { return [] }
                return [.schedule(.hoverExpand, token: interactionToken, after: configuration.hoverExpandDelay)]
            default:
                return []
            }

        case .pointerExited:
            guard context.isHovering else { return [] }
            context.isHovering = false
            invalidatePendingTimers()
            var lingering: [IslandEffect] = []
            if noticeAwaitsPointerExit, notice != nil {
                noticeAwaitsPointerExit = false
                noticeToken &+= 1
                lingering = [.schedule(.noticeDismiss, token: noticeToken, after: NoticeTiming.lingerAfterHover)]
            }
            switch phase {
            case .peek:
                phase = restingPhase
                return lingering
            case .expanded where !isKeptOpen && !context.isFileDragActive:
                return [scheduleCollapse(after: configuration.collapseGraceDelay)] + lingering
            default:
                return lingering
            }

        case .tapped:
            switch phase {
            case .idle, .compact, .peek:
                invalidatePendingTimers()
                phase = .expanded(context.lastTab)
                return [.haptic(.expanded)]
            case .expanded, .dropTarget:
                return []
            }

        case .tappedOutside:
            guard isExpanded, !isKeptOpen else { return [] }
            collapse()
            return activatePendingFeedback()

        case .escapePressed:
            context.isPinned = false
            guard isExpanded || phase == .dropTarget else { return [] }
            context.isFileDragActive = false
            collapse()
            return activatePendingFeedback()

        case .selectTab(let tab):
            context.lastTab = tab
            if isExpanded { phase = .expanded(tab) }
            return []

        case .togglePin:
            context.isPinned.toggle()
            invalidatePendingTimers()
            var effects: [IslandEffect] = [.haptic(.pinChanged)]
            if context.isPinned, !isExpanded {
                phase = .expanded(context.lastTab)
            } else if !isKeptOpen, isExpanded, !context.isHovering {
                collapse()
                effects += activatePendingFeedback()
            }
            return effects

        case .mediaPlaybackChanged(let isPlaying):
            let wasPlaying = context.isMediaPlaying
            context.isMediaPlaying = isPlaying
            mediaToken &+= 1 // bekleyen bir önceki duraklatma zamanlayıcısı geçersiz
            guard !isPlaying, wasPlaying else {
                context.isMediaLingering = false
                settleIfResting()
                return []
            }
            context.isMediaLingering = true
            settleIfResting()
            return [.schedule(.mediaLinger, token: mediaToken, after: configuration.pausedMediaLinger)]

        case .mediaSessionEnded:
            mediaToken &+= 1
            context.isMediaPlaying = false
            context.isMediaLingering = false
            settleIfResting()
            return []

        case .timerRunningChanged(let isRunning):
            context.isTimerRunning = isRunning
            settleIfResting()
            return []

        case .shelfCountChanged(let count):
            context.shelfItemCount = max(0, count)
            settleIfResting()
            return []

        case .transferActiveChanged(let isActive):
            context.isTransferActive = isActive
            settleIfResting()
            return []

        case .holdChanged(let isHeld):
            guard isHeld != context.isHeld else { return [] }
            context.isHeld = isHeld
            invalidatePendingTimers()
            // Kilit kalktığında imleç dışarıdaysa normal sönümleme ile kapan.
            if !isHeld, isExpanded, !context.isHovering, !context.isPinned {
                return [scheduleCollapse(after: configuration.collapseGraceDelay)]
            }
            return []

        case .demoModeChanged(let isOn):
            guard isOn != context.isDemoMode else { return [] }
            context.isDemoMode = isOn
            if isOn {
                if context.isCollapsePending { invalidatePendingTimers() } // bekleyen kapanma iptal
                return []
            }
            // Demo bitti: normal kurallar kaldığı yerden işler (duraklatılmış medya ve imleç dışarıdaysa kapanma).
            var effects: [IslandEffect] = []
            if context.isMediaLingering, !context.isMediaPlaying {
                mediaToken &+= 1
                effects.append(.schedule(.mediaLinger, token: mediaToken, after: configuration.pausedMediaLinger))
            }
            if isExpanded, !context.isHovering, !isKeptOpen, !context.isFileDragActive {
                effects.append(scheduleCollapse(after: configuration.collapseGraceDelay))
            }
            return effects

        case .fullscreenChanged(let isFullscreen):
            guard isFullscreen != context.isFullscreen else { return [] }
            context.isFullscreen = isFullscreen
            settleIfResting()
            return []

        case .noticeRequested(let notice):
            guard !context.isFullscreen || notice.isUrgent else { return [] }
            if notice == .unlocked, case .audioOutput(_, _, true) = self.notice {
                pendingConnectionNotice = self.notice
            }
            if notice == .unlocked, isExpanded {
                pendingUnlockNotice = notice
                return []
            }
            if case .audioOutput(_, _, true) = notice, self.notice == .unlocked {
                pendingConnectionNotice = notice
                return []
            }
            if case .audioOutput(_, _, true) = notice, isExpanded {
                pendingConnectionNotice = notice
                return []
            }
            if let current = self.notice, current.priority > notice.priority { return [] }
            if let activity = restingActivity, activity.priority > notice.priority, !isEngaged { return [] }
            self.notice = notice
            if pendingUnlockNotice == notice { pendingUnlockNotice = nil }
            if pendingConnectionNotice == notice { pendingConnectionNotice = nil }
            noticeToken &+= 1
            noticeAwaitsPointerExit = false
            return [.schedule(.noticeDismiss, token: noticeToken, after: notice.duration)]

        case .systemLocked:
            pendingConnectionNotice = nil
            pendingUnlockNotice = nil
            if notice == .unlocked {
                notice = nil
                noticeToken &+= 1 // bekleyen kapanma zamanlayıcısı geçersiz
                noticeAwaitsPointerExit = false
            }
            guard isExpanded, !isKeptOpen, !context.isFileDragActive else { return [] }
            collapse()
            return []

        case .fileDragEntered:
            invalidatePendingTimers() // tolerans içinde geri dönüş: çıkışı iptal et
            guard !context.isFileDragActive else { return [] }
            context.isFileDragActive = true
            if isExpanded {
                context.lastTab = .shelf
                phase = .expanded(.shelf)
            } else {
                phase = .dropTarget
            }
            return [.haptic(.dropLocked)]

        case .fileDragExited:
            guard context.isFileDragActive else { return [] }
            invalidatePendingTimers()
            return [.schedule(.dragExitGrace, token: interactionToken, after: configuration.dragExitGraceDelay)]

        case .fileDragEnded(let dropped):
            let wasActive = context.isFileDragActive
            context.isFileDragActive = false
            invalidatePendingTimers()
            if dropped {
                // Bırakılan dosyaları göstermek için raf sekmesini aç.
                context.lastTab = .shelf
                phase = .expanded(.shelf)
                var effects: [IslandEffect] = [.haptic(.dropCompleted)]
                if !context.isHovering, !isKeptOpen {
                    effects.append(scheduleCollapse(after: configuration.dropConfirmationDelay))
                }
                return effects
            }
            guard wasActive, phase == .dropTarget else { return [] }
            phase = context.isHovering ? .peek : restingPhase
            return []

        case .hudRequested(let payload):
            hud = payload
            hudToken &+= 1
            return [.schedule(.hudDismiss, token: hudToken, after: configuration.hudDuration)]

        case let .timerFired(timer, token):
            switch timer {
            case .hudDismiss:
                guard token == hudToken else { return [] }
                hud = nil
                return []
            case .noticeDismiss:
                guard token == noticeToken else { return [] }
                // İmleç bildirimin üzerinde (genişlemeden okuyor): otomatik kapanma etkileşimi bölmez.
                if context.isHovering, !isExpanded, notice != .unlocked {
                    noticeAwaitsPointerExit = true
                    return []
                }
                notice = nil
                if let pending = pendingUnlockNotice {
                    return send(.noticeRequested(pending))
                }
                if let pending = pendingConnectionNotice {
                    return send(.noticeRequested(pending))
                }
                return []
            case .hoverExpand:
                guard configuration.expandsOnHover, token == interactionToken, phase == .peek, context.isHovering else { return [] }
                phase = .expanded(context.lastTab)
                return [.haptic(.expanded)]
            case .collapseGrace:
                guard token == interactionToken, isExpanded, !context.isHovering, !isKeptOpen else { return [] }
                collapse()
                return activatePendingFeedback()
            case .mediaLinger:
                // Demo modunda duraklatılan medya kanatta kalır; demo bitince bekleme yeniden kurulur.
                guard token == mediaToken, context.isMediaLingering, !context.isDemoMode else { return [] }
                context.isMediaLingering = false
                settleIfResting()
                return []
            case .dragExitGrace:
                guard token == interactionToken, context.isFileDragActive else { return [] }
                context.isFileDragActive = false
                switch phase {
                case .dropTarget:
                    phase = context.isHovering ? .peek : restingPhase
                    return []
                case .expanded where !context.isHovering && !isKeptOpen:
                    return [scheduleCollapse(after: configuration.collapseGraceDelay)]
                default:
                    return []
                }
            }
        }
    }

    /// Lets the effect runner cancel invalidated sleeps instead of merely ignoring their eventual wakeups.
    public func isTimerCurrent(_ timer: IslandTimer, token: UInt64) -> Bool {
        switch timer {
        case .hoverExpand: configuration.expandsOnHover && token == interactionToken && phase == .peek && context.isHovering
        case .collapseGrace: token == interactionToken && context.isCollapsePending
        case .dragExitGrace: token == interactionToken && context.isFileDragActive
        case .hudDismiss: token == hudToken && hud != nil
        case .noticeDismiss: token == noticeToken && notice != nil
        case .mediaLinger: token == mediaToken && context.isMediaLingering && !context.isDemoMode
        }
    }

    // MARK: - Yardımcılar

    /// Tüm bekleyen etkileşim zamanlayıcılarını geçersiz kılar.
    private mutating func invalidatePendingTimers() {
        interactionToken &+= 1
        context.isCollapsePending = false
    }

    private mutating func scheduleCollapse(after delay: TimeInterval) -> IslandEffect {
        context.isCollapsePending = true
        return .schedule(.collapseGrace, token: interactionToken, after: delay)
    }

    private mutating func collapse() {
        invalidatePendingTimers()
        phase = context.isHovering ? .peek : restingPhase
    }

    /// Device feedback waits until the user-visible expanded content has closed.
    private mutating func activatePendingFeedback() -> [IslandEffect] {
        guard !isExpanded else { return [] }
        if let pendingUnlockNotice { return send(.noticeRequested(pendingUnlockNotice)) }
        if let pendingConnectionNotice { return send(.noticeRequested(pendingConnectionNotice)) }
        return []
    }

    /// Yalnızca kullanıcı etkileşimi yokken (idle/compact) etkinlik değişimlerini yansıtır.
    private mutating func settleIfResting() {
        switch phase {
        case .idle, .compact: phase = restingPhase
        case .peek, .expanded, .dropTarget: break
        }
    }
}
