import Foundation

/// Kaynaktan bağımsız "şu an çalan" modeli.
struct NowPlayingInfo: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    /// `timestamp` anındaki geçen süre.
    var elapsed: TimeInterval
    var timestamp: Date
    var playbackRate: Double
    var isPlaying: Bool
    var artworkData: Data?
    var bundleIdentifier: String?

    /// Oynatma devam ederken geçen süreyi, son güncellemeden bu yana geçen zamanla ekstrapole eder.
    /// Böylece kaynaktan saniyede bir güncelleme istemek gerekmez.
    func elapsed(at date: Date) -> TimeInterval {
        guard isPlaying else { return elapsed }
        let rate = playbackRate > 0 ? playbackRate : 1
        let value = elapsed + date.timeIntervalSince(timestamp) * rate
        return duration > 0 ? min(value, duration) : value
    }

    var trackKey: String { "\(title)|\(artist)|\(album)" }
}

/// MediaRemote komut kimlikleriyle birebir (MRMediaRemoteCommand).
enum MediaCommand: UInt32, Sendable {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
}

/// Tüm medya kaynaklarının uyduğu protokol (MediaRemote, adapter, AppleScript).
@MainActor
protocol MediaSource: AnyObject {
    var id: String { get }
    /// Sistem genelindeki kaynaklar (web oynatıcılar dahil) uygulamaya özel olanlardan önceliklidir.
    var isSystemWide: Bool { get }
    var onUpdate: ((NowPlayingInfo?) -> Void)? { get set }
    func start()
    func stop()
    func perform(_ command: MediaCommand)
    /// Arka uç seek'i destekliyor mu (desteklemiyorsa süre çubuğu salt okunur gösterilir).
    var supportsSeeking: Bool { get }
    /// Konumu değiştirir; arka uç komutu kabul ettiyse `true`. Kabul etmediyse arayüz sahte bir
    /// başarı göstermez, kaydırıcı gerçek konuma döner.
    func seek(to time: TimeInterval) async -> Bool
    /// Uyanma sonrası: sağlık durumunu sıfırlayıp gerekiyorsa yeniden başla (varsayılan: bir şey yapma).
    func recover()
}

extension MediaSource {
    var supportsSeeking: Bool { true }
    func recover() {}
}
