import AppKit
import IslandCore

/// Adanın pencerelerinin Space ve tam ekran geçişlerindeki davranışını yöneten tek nokta.
///
/// Sağlayıcılar `SpacePresentationPolicy.measuredOrder` sırasıyla denenir (ölçüm: private Space 0 pt, public
/// 1774 pt kayma). Her kurulumdan ve her Space değişiminden sonra her pencere **gerçekten** doğrulanır: ekranda mı,
/// macOS'un kaydırdığı bir Space'in üyesi mi (üyelik ile kayma cihazda birebir örtüştü). Sağlayıcı işini
/// yapmıyorsa etkisi geri alınır ve sıradakine geçilir; zincirin sonu görünürlüğü garanti etmeye çalışan güvenli
/// yedektir. Yedekteki pencereler uyanma, ekran uyanması, kilit açma ve ekran değişiminde birincil sağlayıcıyla
/// yeniden denenir. Yoklama yok: doğrulama yalnızca bu olaylarda, pencere başına iki WindowServer sorgusudur.
///
/// A/B testi: `defaults write io.github.openisland.OpenIsland spacePresentationProvider public` (veya `private`,
/// `fallback`) istenen sağlayıcıyı öne alır; kalanlar yedek olarak kalır. Anahtar silinince ölçülen sıra geçerlidir.
@MainActor
@Observable
final class SpacePresentationController {
    static let shared = SpacePresentationController()
    static let overrideKey = "spacePresentationProvider"

    private(set) var status: SpacePresentationStatus = .pending
    let order: [SpaceProviderKind]
    let preferred: SpaceProviderKind?

    private final class Member {
        weak var window: NSWindow?
        var index: Int
        var behavior: SpaceBehavior?
        var repairAttempts = 0
        var retryAttempts = 0
        var repairTask: Task<Void, Never>?
        var retryTask: Task<Void, Never>?
        func cancelTasks() {
            repairTask?.cancel()
            repairTask = nil
            retryTask?.cancel()
            retryTask = nil
        }
        init(_ window: NSWindow, index: Int) { self.window = window; self.index = index }
    }

    @ObservationIgnored private let providers: [SpaceProviderKind: any SpaceProvider]
    @ObservationIgnored private let probe: (any SpaceMembershipProbe)?
    @ObservationIgnored private var members: [Member] = []
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private let isOnScreen: (Int) -> Bool
    @ObservationIgnored private let repairDelays: [Duration]
    @ObservationIgnored private let retryDelays: [Duration]
    @ObservationIgnored private var isTornDown = false

    private init() {
        let privateProvider = PrivateSpaceProvider()
        providers = [.privateSpace: privateProvider, .publicStationary: PublicStationaryProvider(), .safeFallback: SafeFallbackProvider()]
        probe = privateProvider.isAvailable ? privateProvider : nil
        preferred = UserDefaults.standard.string(forKey: Self.overrideKey).flatMap(SpaceProviderKind.init(rawValue:))
        order = SpacePresentationPolicy.order(preferred: preferred)
        isOnScreen = Self.windowIsOnScreen
        repairDelays = [.milliseconds(250), .milliseconds(750), .seconds(2)]
        retryDelays = [.seconds(1), .seconds(3), .seconds(10)]
    }

    /// Aynı yaşam döngüsünü gerçek sağlayıcılar yerine kontrollü arka uçlarla doğrulamak için.
    init(providers: [SpaceProviderKind: any SpaceProvider], probe: (any SpaceMembershipProbe)?,
         preferred: SpaceProviderKind? = nil, isOnScreen: @escaping (Int) -> Bool,
         repairDelays: [Duration] = [.milliseconds(250), .milliseconds(750), .seconds(2)],
         retryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(10)]) {
        self.providers = providers
        self.probe = probe
        self.preferred = preferred
        order = SpacePresentationPolicy.order(preferred: preferred)
        self.isOnScreen = isOnScreen
        self.repairDelays = repairDelays
        self.retryDelays = retryDelays
    }

    /// Kullanımdaki sağlayıcılar (her pencere için; en kötü pencere `status`'ta).
    var activeProviders: Set<SpaceProviderKind> {
        Set(members.compactMap { $0.window == nil ? nil : order[$0.index] })
    }

    // MARK: - Pencereler

    /// Yeni pencereleri birincil sağlayıcıyla kurar; zaten izlenen pencereleri (ekran değişimi) birincilden
    /// yeniden dener. Tekrar çağırmak zararsızdır.
    func attach(_ windows: [NSWindow]) {
        guard !isTornDown else { return }
        startObserving()
        var targets: [Member] = []
        for window in windows {
            if let member = members.first(where: { $0.window === window }) {
                targets.append(member)
            } else {
                let member = Member(window, index: 0)
                members.append(member)
                targets.append(member)
            }
        }
        restart(targets)
    }

    func detach(_ windows: [NSWindow]) {
        for member in members where windows.contains(where: { $0 === member.window }) {
            member.cancelTasks()
            if let window = member.window { providers[order[member.index]]?.uninstall([window]) }
        }
        members.removeAll { member in member.window == nil || windows.contains { $0 === member.window } }
        refreshStatus()
    }

    func tearDown() {
        isTornDown = true
        members.forEach { $0.cancelTasks() }
        members.removeAll()
        recoveryTask?.cancel()
        recoveryTask = nil
        observers.forEach { center, token in center.removeObserver(token) }
        observers.removeAll()
        providers.values.forEach { $0.tearDown() }
        refreshStatus()
    }

    // MARK: - Zincir

    /// Birincil sağlayıcıdan başlat (geçerli sağlayıcının etkisi önce geri alınır).
    private func restart(_ targets: [Member], resetRetryBudget: Bool = true) {
        guard !isTornDown else { return }
        for member in targets {
            guard members.contains(where: { $0 === member }), let window = member.window else { continue }
            member.cancelTasks()
            member.repairAttempts = 0
            if resetRetryBudget { member.retryAttempts = 0 }
            if member.index != 0 { providers[order[member.index]]?.uninstall([window]) }
            member.index = 0
            install(member)
        }
        refreshStatus()
        scheduleVerification(targets)
    }

    /// Geçerli sağlayıcıyı kurar; kullanılamıyorsa sıradakine geçer.
    private func install(_ member: Member) {
        guard let window = member.window else { return }
        while let provider = providers[order[member.index]], !provider.isAvailable, member.index + 1 < order.count {
            member.index += 1
        }
        member.behavior = nil
        providers[order[member.index]]?.install([window])
    }

    /// WindowServer kurulumu sıradaki turda yansıtır.
    private func scheduleVerification(_ targets: [Member]) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.verify(targets) }
        }
    }

    private func verify(_ targets: [Member]) {
        guard !isTornDown else { return }
        var advanced: [Member] = []
        for member in targets {
            guard members.contains(where: { $0 === member }),
                  let window = member.window, window.isVisible else { continue }
            let kind = order[member.index]
            let behavior = SpacePresentationPolicy.behavior(isOnScreen: isOnScreen(window.windowNumber),
                                                            managedSpaces: probe?.managedSpaces(of: window.windowNumber))
            member.behavior = behavior
            if SpacePresentationPolicy.accepts(behavior, from: kind) {
                member.repairTask?.cancel()
                member.repairTask = nil
                member.repairAttempts = 0
                if member.index == 0 {
                    member.retryTask?.cancel()
                    member.retryTask = nil
                    member.retryAttempts = 0
                }
                continue
            }

            // WindowServer animasyon/ekran değişiminde geçici olarak offscreen bildirebilir.
            // Tek örnekle private üyeliği kaldırmak, sağlam adayı kayan Space'lere geri sokuyordu.
            // Üyeliği yerinde onar; bildirimler aynı sınırlı doğrulamayı paylaşır, süreyi uzatmaz.
            if kind == .privateSpace {
                if member.repairTask != nil { continue }
                if member.repairAttempts < repairDelays.count {
                    let delay = repairDelays[member.repairAttempts]
                    member.repairAttempts += 1
                    providers[kind]?.install([window])
                    member.repairTask = Task { [weak self, weak member] in
                        try? await Task.sleep(for: delay)
                        guard !Task.isCancelled, let self, let member else { return }
                        member.repairTask = nil
                        self.verify([member])
                    }
                    continue
                }
            }

            guard SpacePresentationPolicy.next(after: kind, in: order) != nil else { continue }
            providers[kind]?.uninstall([window])
            let demotedFromPrimary = member.index == 0
            member.index += 1
            member.repairAttempts = 0
            install(member)
            advanced.append(member)
            if demotedFromPrimary { scheduleDemotionRetry(member) }
        }
        refreshStatus()
        if !advanced.isEmpty { scheduleVerification(advanced) }
    }

    /// Deneme bütçesi pencere başınadır: sağlam panel, arızalı sensörün/diğer ekranın bütçesini sıfırlayamaz.
    private func scheduleDemotionRetry(_ member: Member) {
        guard member.retryTask == nil, member.retryAttempts < retryDelays.count else { return }
        let delay = retryDelays[member.retryAttempts]
        member.retryAttempts += 1
        member.retryTask = Task { [weak self, weak member] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let member else { return }
            member.retryTask = nil
            self.restart([member], resetRetryBudget: false)
        }
    }

    private func refreshStatus() {
        for member in members where member.window == nil { member.cancelTasks() }
        members.removeAll { $0.window == nil }
        let combined = SpacePresentationPolicy.combine(members.map { (order[$0.index], $0.behavior) })
        if status != combined { status = combined }
    }

    // MARK: - Olaylar

    private func startObserving() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.verify(self.members) }
        }))
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recoverAfterWake() }
            }))
        }
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverAfterWake() }
        }))
    }

    /// Uyanma bildirimi geldiğinde doğrulama henüz pencereleri yedeğe düşürmemiş olabilir.
    /// Bütün pencereleri yeniden kur; WindowServer hazır olmadan başarısız olanları kısa,
    /// sınırlı bir toparlanma aralığında yeniden dene. Boştayken yoklama yapılmaz.
    private func recoverAfterWake() {
        recoveryTask?.cancel()
        restart(members)
        recoveryTask = Task { [weak self] in
            for delay in [250, 750, 2_000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                self?.retryDemoted()
            }
            self?.recoveryTask = nil
        }
    }

    /// Birincilden aşağı düşmüş pencereleri yeniden dene (kendini onarma).
    private func retryDemoted() {
        let demoted = members.filter { $0.index != 0 }
        if !demoted.isEmpty { restart(demoted, resetRetryBudget: false) }
    }

    private static func windowIsOnScreen(_ number: Int) -> Bool {
        guard number > 0,
              let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]]
        else { return false }
        return info.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }
}
