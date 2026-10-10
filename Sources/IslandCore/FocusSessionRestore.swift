import Foundation

/// Odak oturumunun uygulama yeniden açıldığında nasıl sürdürüleceği (saf, testli).
///
/// Bitiş anı `Date` olarak saklandığı için çalışan oturum kapalıyken de "akar": yeniden açılışta aynı bitişe
/// hizalanır. Duraklatılmış oturum kalan süresiyle döner. Uygulama kapalıyken süresi dolan faz bir sonrakine
/// geçer; o an kullanıcı uyarılamadığı için ses/bildirim çalınmaz.
public enum FocusSessionRestore: Equatable, Sendable {
    case idle
    case running(end: Date)
    case paused(remaining: TimeInterval)
    case finishedWhileClosed

    public static func resolve(state: String?, end: Date?, remaining: TimeInterval?,
                               phaseDuration: TimeInterval, now: Date) -> FocusSessionRestore {
        switch state {
        case "running":
            guard let end, end.timeIntervalSince1970.isFinite else { return .idle }
            let left = end.timeIntervalSince(now)
            guard left > 0 else { return .finishedWhileClosed }
            // Sistem saati geri alındıysa bitiş, fazın kendi süresinden daha uzağa taşınmaz.
            return .running(end: left > phaseDuration ? now.addingTimeInterval(phaseDuration) : end)
        case "paused":
            guard let remaining, remaining.isFinite, remaining > 0 else { return .idle }
            return .paused(remaining: min(remaining, phaseDuration))
        default:
            return .idle
        }
    }
}
