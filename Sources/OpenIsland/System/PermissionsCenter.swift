import AppKit
import ApplicationServices
import AVFoundation
import EventKit
import UserNotifications

/// Tüm sistem izinlerinin tek görünümü ("Sistem Erişimi").
///
/// Her izin bir özelliği açar; hiçbiri diğerlerini engellemez. İzin yoksa ilgili özellik sessizce
/// geriler (ör. HUD yerine macOS'un kendi göstergesi, takvim yerine erişim düğmesi).
/// Durumlar yalnızca Ayarlar açıldığında veya ilgili bir olayda okunur; arka planda sorgulama yoktur.
@MainActor
@Observable
final class PermissionsCenter {
    enum State: Equatable, Sendable {
        case granted
        case notGranted
        /// macOS ilk kullanımda sorar (ör. sistem sesi kaydı); önceden sorgulanabilen bir API yok.
        case askOnUse
        case unsupported
        case unavailable

        var label: String {
            switch self {
            case .granted: "İzin verildi"
            case .notGranted: "İzin verilmedi"
            case .askOnUse: "Kullanımda sorulur"
            case .unsupported: "Desteklenmiyor"
            case .unavailable: "Uygulamaya ulaşılamadı"
            }
        }
    }

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case camera = "Privacy_Camera"
        case calendars = "Privacy_Calendars"
        case reminders = "Privacy_Reminders"
        case automation = "Privacy_Automation"
        case pasteboard = "Privacy_Pasteboard"
        case screenCapture = "Privacy_ScreenCapture"

        var url: URL {
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
        }
    }

    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case accessibility, screenCapture, camera, calendar, reminders, spotify, music, clipboard, notifications
        var id: String { rawValue }
    }

    struct Entry: Identifiable {
        let kind: Kind
        let title: String
        /// Neden gerektiği (bir iki kısa cümle).
        let reason: String
        let state: State
        let isRequesting: Bool
        var id: Kind { kind }
    }

    private(set) var states: [Kind: State] = [:]
    @ObservationIgnored var onStateChange: ((Kind, State) -> Void)?
    @ObservationIgnored private let readAutomation: @Sendable (String, Bool) async -> State
    @ObservationIgnored private let launchAutomationTarget: (String) async -> Bool
    @ObservationIgnored private var automationTasks: [Kind: Task<Void, Never>] = [:]
    @ObservationIgnored private var automationGenerations: [Kind: UInt64] = [:]
    private var requestingAutomation: Set<Kind> = []
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var notificationQueryPending = false

    init(readAutomation: @escaping @Sendable (String, Bool) async -> State = PermissionsCenter.automationState,
         launchAutomationTarget: @escaping (String) async -> Bool = PermissionsCenter.ensureAutomationTargetRunning) {
        self.readAutomation = readAutomation
        self.launchAutomationTarget = launchAutomationTarget
    }

    func stop() {
        isStopped = true
        for kind in automationTasks.keys {
            automationGenerations[kind, default: 0] &+= 1
        }
        automationTasks.values.forEach { $0.cancel() }
        automationTasks.removeAll()
        requestingAutomation.removeAll()
        onStateChange = nil
        notificationQueryPending = false
    }

    private func publish(_ latest: [Kind: State]) {
        guard latest != states else { return }
        let previous = states
        states = latest
        for kind in Kind.allCases {
            if let value = latest[kind], value != previous[kind] { onStateChange?(kind, value) }
        }
    }

    private func setState(_ state: State, for kind: Kind) {
        guard !isStopped, states[kind] != state else { return }
        var latest = states
        latest[kind] = state
        publish(latest)
    }

    static let automationTargets: [Kind: String] = [.spotify: "com.spotify.client", .music: "com.apple.Music"]

    var entries: [Entry] {
        Kind.allCases.map { kind in
            Entry(kind: kind, title: Self.title(kind), reason: Self.reason(kind), state: states[kind] ?? .askOnUse, isRequesting: requestingAutomation.contains(kind))
        }
    }

    func state(of kind: Kind) -> State { states[kind] ?? .askOnUse }

    func refresh() {
        guard !isStopped else { return }
        var latest = states
        latest[.accessibility] = AXIsProcessTrusted() ? .granted : .notGranted
        latest[.screenCapture] = CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        latest[.camera] = switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .notDetermined: .askOnUse
        default: .notGranted
        }
        latest[.calendar] = Self.eventKitState(.event)
        latest[.reminders] = Self.eventKitState(.reminder)
        if #available(macOS 15.4, *) {
            latest[.clipboard] = switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: .granted
            case .alwaysDeny: .notGranted
            default: .askOnUse
            }
        } else {
            latest[.clipboard] = .granted
        }
        if AppPaths.isRunningAsBundle, !notificationQueryPending {
            notificationQueryPending = true
            UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
                let state: State = switch settings.authorizationStatus {
                case .authorized, .provisional: .granted
                case .notDetermined: .askOnUse
                default: .notGranted
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, !self.isStopped else { return }
                        self.notificationQueryPending = false
                        self.setState(state, for: .notifications)
                    }
                }
            }
        } else if !AppPaths.isRunningAsBundle {
            latest[.notifications] = .unsupported // paketlenmemiş çalıştırmada UserNotifications kullanılamaz
        }
        publish(latest)
        refreshAutomationPermissions()
    }

    /// İzni iste veya ilgili Sistem Ayarları bölmesini aç.
    func resolve(_ kind: Kind, reminders: RemindersService, calendar: CalendarService) {
        guard !isStopped else { return }
        switch kind {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            open(.accessibility)
        case .screenCapture:
            // Only this explicit user action requests capture access; hover never prompts.
            if !CGRequestScreenCaptureAccess() { open(.screenCapture) }
            refresh()
        case .camera:
            if state(of: .camera) == .askOnUse {
                AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
                }
            } else {
                open(.camera)
            }
        case .calendar:
            state(of: .calendar) == .askOnUse ? calendar.requestAccess() : open(.calendars)
        case .reminders:
            state(of: .reminders) == .askOnUse ? reminders.requestAccess() : open(.reminders)
        case .spotify, .music:
            guard let bundleID = Self.automationTargets[kind] else { return }
            queryAutomation(kind, bundleID: bundleID, ask: true)
        case .clipboard:
            open(.pasteboard)
        case .notifications:
            Notifier.requestAuthorization()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
        }
    }

    /// Coalesce repeated Settings activation/appearance events; an explicit request wins over a read.
    func refreshAutomationPermissions() {
        for (kind, bundleID) in Self.automationTargets { queryAutomation(kind, bundleID: bundleID, ask: false) }
    }

    private func queryAutomation(_ kind: Kind, bundleID: String, ask: Bool) {
        guard !isStopped else { return }
        if automationTasks[kind] != nil {
            guard ask, !requestingAutomation.contains(kind) else { return }
            automationTasks[kind]?.cancel()
        }
        automationGenerations[kind, default: 0] &+= 1
        let generation = automationGenerations[kind]!
        if ask { requestingAutomation.insert(kind) }
        let read = readAutomation
        let launch = launchAutomationTarget
        automationTasks[kind] = Task { [weak self] in
            let state: State
            if ask, !(await launch(bundleID)) {
                state = .unsupported
            } else {
                guard !Task.isCancelled else { return }
                state = await read(bundleID, ask)
            }
            guard !Task.isCancelled, let self, self.automationGenerations[kind] == generation else { return }
            self.automationTasks[kind] = nil
            self.requestingAutomation.remove(kind)
            self.setState(state, for: kind)
            if ask, state == .notGranted { self.open(.automation) }
        }
    }

    /// Only an explicit permission action launches the target; passive refresh never opens an app.
    private static func ensureAutomationTargetRunning(_ bundleID: String) async -> Bool {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { !$0.isTerminated }) {
            return true
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                continuation.resume(returning: app != nil && error == nil)
            }
        }
    }

    func open(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }

    private static func eventKitState(_ type: EKEntityType) -> State {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: .granted
        case .notDetermined: .askOnUse
        default: .notGranted
        }
    }

    /// Apple Events izni. `ask: true` ise ve karar verilmemişse sistem diyaloğu gösterilir.
    /// Engelleyici bir çağrı olduğundan ana iş parçacığı dışında çalıştırılır.
    nonisolated static func automationState(bundleID: String, ask: Bool) async -> State {
        await automationState(ask: ask, readResult: {
            await Task.detached(priority: .userInitiated) {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                guard let descriptor = target.aeDesc else { return OSStatus(-50) }
                return AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, ask)
            }.value
        })
    }

    /// Cold launches may not yet accept Apple Events. Retry only an explicit request, for <1.3 seconds;
    /// passive Settings reads never wait, launch, or poll. Denial/consent results are never retried.
    nonisolated static func automationState(
        ask: Bool, readResult: @escaping @Sendable () async -> OSStatus,
        wait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> State {
        let delays: [Duration] = [.milliseconds(150), .milliseconds(350), .milliseconds(750)]
        var attempt = 0
        while !Task.isCancelled {
            let result = await readResult()
            guard !Task.isCancelled else { return .unavailable }
            switch Int(result) {
            case Int(noErr): return .granted
            case -1743: return .notGranted
            case -1744: return .askOnUse
            case -600, -609:
                guard ask else { return .askOnUse }
                guard attempt < delays.count else { return .unavailable }
                do { try await wait(delays[attempt]) } catch { return .unavailable }
                attempt += 1
            default: return .unavailable
            }
        }
        return .unavailable
    }

    private static func title(_ kind: Kind) -> String {
        switch kind {
        case .accessibility: "Erişilebilirlik"
        case .screenCapture: "Ekran erişimi: Dock önizlemeleri"
        case .camera: "Kamera"
        case .calendar: "Takvimler"
        case .reminders: "Anımsatıcılar"
        case .spotify: "Otomasyon: Spotify"
        case .music: "Otomasyon: Müzik"
        case .clipboard: "Pano"
        case .notifications: "Bildirimler"
        }
    }

    private static func reason(_ kind: Kind) -> String {
        switch kind {
        case .accessibility: "Dock simgelerini ve pencerelerini tanımak, kırmızı düğmeden çıkış ve ⌘C/⌘X pano olayları için."
        case .screenCapture: "Dock'ta yalnızca gösterilen pencerelerin küçük, tek karelik önizlemeleri için. Ses, video veya dosya kaydı yapılmaz."
        case .camera: "Ayna önizlemesi için. Görüntü kaydedilmez; sekme kapanınca kamera kapanır."
        case .calendar: "Yaklaşan etkinlikler ve toplantı hatırlatması için."
        case .reminders: "Bugünkü anımsatıcıları gösterip tamamlamak ve yenisini eklemek için."
        case .spotify: "Spotify'da çalan parça ve kontroller için. Spotify'ın kendi bildirimi izinsiz de çalışır."
        case .music: "Müzik uygulamasında çalan parça ve kontroller için."
        case .clipboard: "Pano geçmişi için. macOS içerik okumayı ayrıca sorabilir."
        case .notifications: "Pomodoro bittiğinde sistem bildirimi için. Ada bildirimi izinsiz de çalışır."
        }
    }
}
