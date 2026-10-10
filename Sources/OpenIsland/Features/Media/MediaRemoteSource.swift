import Foundation

/// Private `MediaRemote.framework` köprüsü (dlopen/dlsym ile; link-time bağımlılık yok).
///
/// Kontrol Merkezi'ndeki "Şimdi Çalıyor" ile aynı veriyi sağlar: Spotify, Müzik, Safari/Chrome
/// (Media Session API), VLC, IINA vb. **macOS 15.4+**: Apple, bilgi okuma fonksiyonlarını
/// `com.apple.*` dışındaki süreçlere kapattı; bu sürümlerde bilgi `MediaRemoteAdapterSource`
/// üzerinden okunur. Komut gönderme (`MRMediaRemoteSendCommand`) hâlâ çalışır.
enum MediaRemote {
    private typealias SendCommandFn = @convention(c) (UInt32, NSDictionary?) -> Bool
    private typealias SetElapsedFn = @convention(c) (Double) -> Void
    fileprivate typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    fileprivate typealias RegisterFn = @convention(c) (DispatchQueue) -> Void

    // dlopen tanıtıcısı yalnızca okunur; süreç boyunca sabit kalır.
    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY
    )

    fileprivate static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    static var isAvailable: Bool { handle != nil }

    /// macOS 15.4 öncesinde bilgi okuma doğrudan çalışır.
    static var canReadNowPlayingDirectly: Bool {
        !ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 15, minorVersion: 4, patchVersion: 0))
    }

    @discardableResult
    static func send(_ command: MediaCommand) -> Bool {
        symbol("MRMediaRemoteSendCommand", as: SendCommandFn.self)?(command.rawValue, nil) ?? false
    }

    static var canSetElapsedTime: Bool { symbol("MRMediaRemoteSetElapsedTime", as: SetElapsedFn.self) != nil }

    /// Sembol yoksa `false` (özel API güvenliği: çağrı yapılmaz).
    @discardableResult
    static func setElapsedTime(_ time: TimeInterval) -> Bool {
        guard let setElapsed = symbol("MRMediaRemoteSetElapsedTime", as: SetElapsedFn.self) else { return false }
        setElapsed(time)
        return true
    }
}

@MainActor
final class MediaRemoteSource: MediaSource {
    let id = "mediaremote"
    let isSystemWide = true
    var onUpdate: ((NowPlayingInfo?) -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty,
              let register = MediaRemote.symbol("MRMediaRemoteRegisterForNowPlayingNotifications", as: MediaRemote.RegisterFn.self)
        else { return }
        register(.main)

        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fetch() }
            }
        }
        fetch()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func perform(_ command: MediaCommand) { MediaRemote.send(command) }
    var supportsSeeking: Bool { MediaRemote.canSetElapsedTime }
    func seek(to time: TimeInterval) async -> Bool { MediaRemote.setElapsedTime(time) }

    private func fetch() {
        guard let getInfo = MediaRemote.symbol("MRMediaRemoteGetNowPlayingInfo", as: MediaRemote.GetInfoFn.self) else { return }
        getInfo(.main) { [weak self] dictionary in
            let info = Self.parse(dictionary as? [String: Any] ?? [:])
            MainActor.assumeIsolated { self?.onUpdate?(info) }
        }
    }

    nonisolated static func parse(_ dictionary: [String: Any]) -> NowPlayingInfo? {
        func value<T>(_ key: String) -> T? { dictionary["kMRMediaRemoteNowPlayingInfo\(key)"] as? T }
        guard let title: String = value("Title"), !title.isEmpty else { return nil }
        let rate: Double = value("PlaybackRate") ?? 0
        return NowPlayingInfo(
            title: title,
            artist: value("Artist") ?? "",
            album: value("Album") ?? "",
            duration: value("Duration") ?? 0,
            elapsed: value("ElapsedTime") ?? 0,
            timestamp: value("Timestamp") ?? Date(),
            playbackRate: rate,
            isPlaying: rate > 0,
            artworkData: value("ArtworkData"),
            bundleIdentifier: nil
        )
    }
}
