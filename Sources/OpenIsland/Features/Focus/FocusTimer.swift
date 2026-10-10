import IslandCore
import SwiftUI

/// Pomodoro zamanlayıcı. Bitiş anı `Date` olarak tutulur; uyanmada ve sistem saati
/// değiştiğinde bitiş görevi aynı tarihe yeniden hizalanır. Arka planda yalnızca bitiş anına kadar uyuyan tek bir görev vardır; halka Core
/// Animation ile akar, geri sayım metni yalnızca görünürken ve saniye sınırlarında güncellenir.
///
/// Oturum (faz, çalışıyor/duraklatıldı, tamamlanan odak sayısı) yalnızca durum değiştiğinde saklanır ve uygulama
/// yeniden açılınca sürdürülür (`FocusSessionRestore`). Önceden yalnızca süre ayarları saklanıyordu; duraklatılmış
/// oturum yeniden açılışta tam süreye dönüyordu.
@MainActor
@Observable
final class FocusTimer {
    enum Phase: String, CaseIterable {
        case focus, shortBreak, longBreak

        var title: String {
            switch self {
            case .focus: "Odak"
            case .shortBreak: "Kısa mola"
            case .longBreak: "Uzun mola"
            }
        }

        var tint: Color {
            switch self {
            case .focus: .orange
            case .shortBreak: .green
            case .longBreak: .teal
            }
        }
    }

    enum RunState: Equatable {
        case idle
        case running(end: Date)
        case paused(remaining: TimeInterval)
    }

    private(set) var phase: Phase = .focus
    private(set) var runState: RunState = .idle
    private(set) var completedFocusSessions = 0

    private(set) var focusMinutes: Double
    private(set) var shortBreakMinutes: Double
    private(set) var longBreakMinutes: Double
    var sessionsBeforeLongBreak = 4

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onRunningChange: ((Bool) -> Void)?
    /// Faz bittiğinde adada gösterilecek başlık.
    @ObservationIgnored var onPhaseFinished: ((String) -> Void)?
    @ObservationIgnored private var completionTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func load(_ phase: Phase, fallback: Double) -> Double {
            guard let value = defaults.object(forKey: Self.durationKey(phase)) as? Double,
                  value.isFinite else { return fallback }
            return min(max(value.rounded(), 1), 180)
        }
        focusMinutes = load(.focus, fallback: 25)
        shortBreakMinutes = load(.shortBreak, fallback: 5)
        longBreakMinutes = load(.longBreak, fallback: 15)
        restoreSession()
    }

    func minutes(for phase: Phase) -> Double {
        switch phase {
        case .focus: focusMinutes
        case .shortBreak: shortBreakMinutes
        case .longBreak: longBreakMinutes
        }
    }

    /// Çalışan oturum değişmez; duraklatılmış mevcut fazın süresi değiştirilirse yeni süreyle sıfırlanır.
    func setMinutes(_ minutes: Double, for phase: Phase) {
        guard !isRunning, minutes.isFinite else { return }
        let value = min(max(minutes.rounded(), 1), 180)
        guard self.minutes(for: phase) != value else { return }
        switch phase {
        case .focus: focusMinutes = value
        case .shortBreak: shortBreakMinutes = value
        case .longBreak: longBreakMinutes = value
        }
        defaults.set(value, forKey: Self.durationKey(phase))
        if self.phase == phase { reset() }
    }

    private static func durationKey(_ phase: Phase) -> String { "focusTimer.\(phase.rawValue)Minutes" }

    var isRunning: Bool {
        if case .running = runState { true } else { false }
    }

    var phaseDuration: TimeInterval {
        switch phase {
        case .focus: focusMinutes * 60
        case .shortBreak: shortBreakMinutes * 60
        case .longBreak: longBreakMinutes * 60
        }
    }

    func remaining(at date: Date) -> TimeInterval {
        switch runState {
        case .idle: phaseDuration
        case .running(let end): max(end.timeIntervalSince(date), 0)
        case .paused(let remaining): remaining
        }
    }

    /// Halka için sabit parametreler: çalışırken yalnızca durum değişiminde yeni animasyon kurulur.
    var progressTiming: TimeProgressView.Timing {
        let duration = phaseDuration
        switch runState {
        case .running(let end) where duration > 0:
            return .init(progress: 1, reference: end, rate: 1 / duration, isRunning: true)
        case .paused(let remaining) where duration > 0:
            return .init(progress: 1 - remaining / duration, reference: .distantPast, rate: 0, isRunning: false)
        default:
            return .init(progress: 0, reference: .distantPast, rate: 0, isRunning: false)
        }
    }

    func progress(at date: Date) -> Double {
        guard phaseDuration > 0 else { return 0 }
        return 1 - remaining(at: date) / phaseDuration
    }

    // MARK: - Kontroller

    func start() {
        let remaining = remaining(at: Date())
        setRunState(.running(end: Date().addingTimeInterval(remaining)))
        reconcileDeadline()
    }

    func pause() {
        guard case .running = runState else { return }
        completionTask?.cancel()
        setRunState(.paused(remaining: remaining(at: Date())))
    }

    func toggle() { isRunning ? pause() : start() }

    func reset() {
        completionTask?.cancel()
        setRunState(.idle)
    }

    func skip() {
        completionTask?.cancel()
        advancePhase(countSession: false)
    }

    // MARK: - Private

    private func setRunState(_ state: RunState) {
        let wasRunning = isRunning
        runState = state
        persistSession()
        if wasRunning != isRunning { onRunningChange?(isRunning) }
    }

    // MARK: - Oturumun saklanması

    private enum SessionKey {
        static let phase = "focusTimer.session.phase"
        static let state = "focusTimer.session.state"
        static let end = "focusTimer.session.end"
        static let remaining = "focusTimer.session.remaining"
        static let completed = "focusTimer.session.completed"
    }

    /// Her durum değişiminde (başlat, duraklat, sıfırla, atla, faz bitti) çağrılır; saniye başına yazma yok.
    private func persistSession() {
        defaults.set(phase.rawValue, forKey: SessionKey.phase)
        defaults.set(completedFocusSessions, forKey: SessionKey.completed)
        switch runState {
        case .idle:
            defaults.set("idle", forKey: SessionKey.state)
            defaults.removeObject(forKey: SessionKey.end)
            defaults.removeObject(forKey: SessionKey.remaining)
        case .running(let end):
            defaults.set("running", forKey: SessionKey.state)
            defaults.set(end.timeIntervalSince1970, forKey: SessionKey.end)
            defaults.removeObject(forKey: SessionKey.remaining)
        case .paused(let remaining):
            defaults.set("paused", forKey: SessionKey.state)
            defaults.set(remaining, forKey: SessionKey.remaining)
            defaults.removeObject(forKey: SessionKey.end)
        }
    }

    /// Açılışta bir kez. Geri çağrılar henüz bağlanmadığından durum doğrudan yazılır; koordinatör yeni adaları
    /// `isRunning` ile eşitler.
    private func restoreSession() {
        phase = defaults.string(forKey: SessionKey.phase).flatMap(Phase.init(rawValue:)) ?? .focus
        completedFocusSessions = max(defaults.integer(forKey: SessionKey.completed), 0)
        let end = (defaults.object(forKey: SessionKey.end) as? Double).map(Date.init(timeIntervalSince1970:))
        let restored = FocusSessionRestore.resolve(
            state: defaults.string(forKey: SessionKey.state), end: end,
            remaining: defaults.object(forKey: SessionKey.remaining) as? Double,
            phaseDuration: phaseDuration, now: Date()
        )
        switch restored {
        case .idle:
            runState = .idle
        case .running(let end):
            runState = .running(end: end)
            reconcileDeadline()
        case .paused(let remaining):
            runState = .paused(remaining: remaining)
        case .finishedWhileClosed:
            advancePhase(countSession: true)
        }
    }

    /// Stops runtime work without altering the persisted deadline/session.
    func shutdown() {
        completionTask?.cancel()
        completionTask = nil
    }

    /// Olay güdümlü: uyanma/saat değişimi dışında ek bir yoklama veya periyodik timer yok.
    func reconcileDeadline(at date: Date = Date()) {
        guard case .running(let end) = runState else { return }
        completionTask?.cancel()
        let remaining = end.timeIntervalSince(date)
        guard remaining > 0 else {
            complete()
            return
        }
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            // ContinuousClock ile Date farklı saatlerdir: erken uyanma/saat düzeltmesinde
            // fazı erken tamamlamak yerine hâlâ geçerli bitiş tarihini yeniden kontrol et.
            self?.reconcileDeadline()
        }
    }

    private func complete() {
        let finished = phase
        advancePhase(countSession: true)
        NSSound(named: "Glass")?.play()
        onPhaseFinished?(finished == .focus ? "Odak tamamlandı · \(phase.title) zamanı" : "Mola bitti")
        Notifier.post(
            title: finished == .focus ? "Odak oturumu tamamlandı" : "Mola bitti",
            body: finished == .focus ? "\(phase.title) zamanı." : "Yeni bir odak oturumuna hazır mısın?"
        )
    }

    private func advancePhase(countSession: Bool) {
        if phase == .focus {
            if countSession { completedFocusSessions += 1 }
            phase = completedFocusSessions > 0 && completedFocusSessions % sessionsBeforeLongBreak == 0 ? .longBreak : .shortBreak
        } else {
            phase = .focus
        }
        setRunState(.idle)
    }
}
