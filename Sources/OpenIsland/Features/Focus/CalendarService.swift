import AppKit
import EventKit

struct UpcomingEvent: Identifiable, Equatable, Sendable {
    let id: String
    /// Calendar uygulamasının etkinlik bağlantısı (`ical://ekevent/…`) bu kimliği kullanır.
    let calendarItemID: String
    let title: String
    let start: Date
    let end: Date
    let calendarColor: NSColor?
    /// Etkinlik URL'si veya notlarındaki Zoom/Meet/Teams bağlantısı.
    let meetingURL: URL?
    let isAllDay: Bool

    var isOngoing: Bool { start <= Date() && end > Date() }
}

/// Ayarlardaki takvim seçimi için.
struct CalendarInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let color: NSColor?
}

/// EventKit ile önümüzdeki 24 saatin etkinlikleri. macOS 14+ "tam erişim" API'si kullanılır.
@MainActor
@Observable
final class CalendarService {
    /// Önümüzdeki 24 saat (hatırlatmalar ve Odak sekmesi için).
    private(set) var events: [UpcomingEvent] = []
    /// Nook takvim widget'ında seçili gün (0 = bugün); ‹ › ile değişir.
    private(set) var dayOffset = 0
    private(set) var dayEvents: [UpcomingEvent] = []
    private(set) var calendars: [CalendarInfo] = []
    /// `nil` = tüm takvimler.
    @ObservationIgnored var enabledCalendarIDs: Set<String>? { didSet { reload() } }
    @ObservationIgnored var includesAllDayEvents = false { didSet { reload() } }
    private(set) var authorization: EKAuthorizationStatus
    private(set) var today: Date

    @ObservationIgnored private let provider: EventStoreProvider
    /// Store yalnızca izin verildikten sonra ilk kullanımda oluşturulur.
    private var store: EKEventStore { provider.store }
    @ObservationIgnored private let readAuthorization: () -> EKAuthorizationStatus
    @ObservationIgnored private let currentDate: () -> Date
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var generation: UInt64 = 0
    /// Toplantı yaklaşınca (varsayılan 5 dk önce) adada kısa bildirim.
    @ObservationIgnored var onMeetingSoon: ((_ title: String, _ minutes: Int) -> Void)?
    @ObservationIgnored var reminderLeadTime: TimeInterval = 5 * 60
    @ObservationIgnored private var reminderTask: Task<Void, Never>?
    @ObservationIgnored private var remindedEventIDs: Set<String> = []

    init(provider: EventStoreProvider,
         readAuthorization: @escaping () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) },
         currentDate: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.readAuthorization = readAuthorization
        self.currentDate = currentDate
        authorization = readAuthorization()
        today = Calendar.current.startOfDay(for: currentDate())
    }

    var hasAccess: Bool { authorization == .fullAccess }

    func stop() {
        isStarted = false
        generation &+= 1
        observers.forEach { center, token in center.removeObserver(token) }
        observers.removeAll()
        reminderTask?.cancel()
        reminderTask = nil
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        generation &+= 1
        authorization = readAuthorization()
        let center = NotificationCenter.default
        for name in [Notification.Name.EKEventStoreChanged, .NSCalendarDayChanged,
                     .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            observe(center, name: name) { service in
                service.authorization = service.readAuthorization()
                service.reload()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, name: NSWorkspace.didWakeNotification) { service in
            service.authorization = service.readAuthorization()
            service.reload()
        }
        observe(workspace, name: NSWorkspace.didActivateApplicationNotification) { service in
            let status = service.readAuthorization()
            guard status != service.authorization else { return }
            service.authorization = status
            service.reload()
        }
        reload()
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name,
                         handler: @escaping @MainActor (CalendarService) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isStarted else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    /// Karar verilmemişse sistem izin sorusunu gösterir. Reddedilmiş/kısıtlıysa soru bir daha çıkmaz; bu durumda
    /// Sistem Ayarları › Takvimler açılır (düğme sessizce hiçbir şey yapmasın diye).
    func requestAccess() {
        authorization = readAuthorization()
        guard authorization == .notDetermined else {
            AppHandoff.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"))
            return
        }
        let requestGeneration = generation
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isStarted, self.generation == requestGeneration else { return }
                    self.authorization = self.readAuthorization()
                    self.reload()
                }
            }
        }
    }

    func reload() {
        guard isStarted else { return }
        today = Calendar.current.startOfDay(for: currentDate())
        guard hasAccess else {
            reminderTask?.cancel()
            reminderTask = nil
            events = []
            dayEvents = []
            calendars = []
            return
        }
        calendars = store.calendars(for: .event).map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: $0.color) }
        let now = currentDate()
        events = fetch(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(24 * 3600))
            .filter { !$0.isAllDay && $0.end > now }
            .prefix(5)
            .map { $0 }
        remindedEventIDs.formIntersection(Set(events.map(\.id)))
        reloadDay()
        scheduleReminder()
    }

    func showDay(offset: Int) {
        dayOffset = min(max(offset, -7), 30)
        reloadDay()
    }

    func openInCalendarApp() {
        AppHandoff.openApplication(bundleID: AppHandoff.calendarBundleID)
    }

    /// Etkinliği Calendar'da gösterir. Biçim Calendar'ın kendi ikili dosyasında geçen
    /// `ical://ekevent/%@?method=show&options=more` ile aynıdır (belgelenmemiş; MeetingBar da kullanır).
    /// Bağlantı kurulamazsa en azından Calendar açılır. Toplantı bağlantısı "Katıl" düğmesinde kalır.
    func open(_ event: UpcomingEvent) {
        let identifier = event.calendarItemID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let url = identifier.isEmpty ? nil : URL(string: "ical://ekevent/\(identifier)?method=show&options=more")
        AppHandoff.open(url, fallbackBundleID: AppHandoff.calendarBundleID)
    }

    private func reloadDay() {
        guard isStarted, hasAccess else { dayEvents = []; return }
        let calendar = Calendar.current
        guard let start = calendar.date(byAdding: .day, value: dayOffset, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let now = currentDate()
        dayEvents = fetch(from: start, to: end)
            .filter { dayOffset != 0 || $0.end > now || $0.isAllDay }
            .filter { includesAllDayEvents || !$0.isAllDay }
    }

    private func fetch(from start: Date, to end: Date) -> [UpcomingEvent] {
        let selected = enabledCalendarIDs.map { ids in store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) } }
        if let selected, selected.isEmpty { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                UpcomingEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    calendarItemID: event.calendarItemIdentifier,
                    title: event.title ?? "Adsız etkinlik",
                    start: event.startDate,
                    end: event.endDate,
                    calendarColor: event.calendar?.color,
                    meetingURL: Self.meetingURL(in: event),
                    isAllDay: event.isAllDay
                )
            }
    }

    /// Yoklama yok: yalnızca **bir sonraki** etkinlik için, hatırlatma anına kadar uyuyan tek görev.
    /// Takvim değiştiğinde (`EKEventStoreChanged`) yeniden kurulur.
    private func scheduleReminder() {
        reminderTask?.cancel()
        reminderTask = nil
        guard isStarted, hasAccess else { return }
        let now = currentDate()
        guard let next = events.first(where: { $0.start > now && !remindedEventIDs.contains($0.id) }) else { return }
        let fireDate = next.start.addingTimeInterval(-reminderLeadTime)
        reminderTask = Task { [weak self] in
            let delay = fireDate.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, self.isStarted else { return }
            self.reminderTask = nil
            self.remindedEventIDs.insert(next.id)
            let minutes = max(Int((next.start.timeIntervalSinceNow / 60).rounded()), 1)
            self.onMeetingSoon?(next.title, minutes)
            self.scheduleReminder()
        }
    }

    private static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com"]

    private static func meetingURL(in event: EKEvent) -> URL? {
        if let url = event.url, meetingHosts.contains(where: { url.host?.contains($0) == true }) { return url }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        guard !text.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url)
            .first { url in meetingHosts.contains { url.host?.contains($0) == true } }
    }
}
