import AppKit
import IslandCore

/// Spotify ve Apple Music için AppleScript + Distributed Notification kaynağı.
///
/// MediaRemote'a erişilemediğinde (macOS 15.4+ ve adapter yoksa) güvenilir yedektir.
/// Olay güdümlüdür: uygulamalar durum değiştiğinde dağıtık bildirim yayınlar. Spotify'ın bildirimi
/// tüm durumu (konum dahil) taşır → Apple Event gönderilmez; yalnızca yeni parçada kapak URL'si
/// sorulur. Müzik'in bildiriminde konum olmadığından tek bir AppleScript sorgusu yapılır.
/// `tell application` hedef uygulamayı başlatacağından her sorgu öncesi çalışıp çalışmadığı kontrol edilir.
@MainActor
final class ScriptedPlayerSource: MediaSource {
    struct Player: Sendable {
        let bundleID: String
        let appName: String
        let notification: String
        /// Bildirim ve AppleScript'teki süre birimi → saniye çarpanı.
        let durationScale: Double
        let artwork: ArtworkQuery
    }

    enum ArtworkQuery: Sendable {
        case url(String)
        case rawData(String)
    }

    static let spotify = Player(
        bundleID: "com.spotify.client",
        appName: "Spotify",
        notification: "com.spotify.client.PlaybackStateChanged",
        durationScale: 0.001,
        artwork: .url("tell application \"Spotify\" to artwork url of current track")
    )

    static let music = Player(
        bundleID: "com.apple.Music",
        appName: "Music",
        notification: "com.apple.Music.playerInfo",
        durationScale: 1,
        artwork: .rawData("tell application \"Music\" to get raw data of artwork 1 of current track")
    )

    let player: Player
    var id: String { player.bundleID }
    let isSystemWide = false
    var onUpdate: ((NowPlayingInfo?) -> Void)?

    private let runningCheck: () -> Bool
    private var observer: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var current: NowPlayingInfo?
    /// Apple Event sağlığı: izin reddinde veya tekrarlayan hatada sınırlı geri çekilme.
    private var health = BackendHealth()
    private var artworkCache: (key: String, data: Data?)?

    init(player: Player, isRunning: (() -> Bool)? = nil) {
        self.player = player
        runningCheck = isRunning ?? {
            NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).contains { !$0.isTerminated }
        }
    }

    private var isRunning: Bool { runningCheck() }

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(player.notification), object: nil, queue: .main
        ) { [weak self] note in
            let snapshot = PlayerSnapshot(userInfo: note.userInfo)
            MainActor.assumeIsolated { self?.handle(snapshot) }
        }
        if isRunning { requestRefresh() }
    }

    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        refreshTask?.cancel(); refreshTask = nil
        artworkTask?.cancel(); artworkTask = nil
    }

    func recover() {
        prepareUserRetry()
        if observer != nil, isRunning { requestRefresh() }
    }

    /// Tek giriş noktası: sağlık izin vermiyorsa Apple Event hiç gönderilmez.
    private func script<T: Sendable>(_ source: String, cacheResult: Bool = true, transform: @escaping @Sendable (NSAppleEventDescriptor) -> T?) async -> T? {
        guard !Task.isCancelled, health.allows() else { return nil }
        let outcome = await ScriptRunner.shared.execute(source, cacheResult: cacheResult, transform: transform)
        switch outcome.errorCode {
        case nil: health.recordSuccess()
        case -600, -609: break // uygulama kapanıyor/çalışmıyor: arka ucun hatası değil
        case -1743: health.recordFailure(minimumDelay: 10 * 60) // Otomasyon izni yok: kullanıcıya zaman tanı
        default: health.recordFailure()
        }
        return outcome.value
    }

    private func prepareUserRetry() {
        health.reset()
        // A failed artwork request is not a permanent absence of artwork for this track.
        if artworkCache?.data == nil { artworkCache = nil }
    }

    private func fire(_ source: String) {
        Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.prepareUserRetry()
            _ = await self.script(source) { _ in true }
        }
    }

    func perform(_ command: MediaCommand) {
        guard isRunning else { return }
        let verb = switch command {
        case .play: "play"
        case .pause: "pause"
        case .togglePlayPause: "playpause"
        case .nextTrack: "next track"
        case .previousTrack: "previous track"
        }
        fire("tell application \"\(player.appName)\" to \(verb)")
    }

    /// Başarılıysa gerçek konum tek bir sorguyla doğrulanır (oynatıcılar seek'te bildirim göndermeyebilir).
    func seek(to time: TimeInterval) async -> Bool {
        guard isRunning else { return false }
        prepareUserRetry()
        let accepted = await script("tell application \"\(player.appName)\" to set player position to \(time)", cacheResult: false) { _ in true } ?? false
        if accepted { await refresh() }
        return accepted
    }

    // MARK: - Private

    /// Bildirim `userInfo`'sundan çıkarılan, aktörler arası güvenle taşınabilen özet.
    private struct PlayerSnapshot: Sendable {
        let state: String?
        let title: String?
        let artist: String?
        let album: String?
        /// Her iki uygulamada da milisaniye.
        let durationMilliseconds: Double?
        /// Yalnızca Spotify gönderir (saniye).
        let position: Double?

        init(userInfo: [AnyHashable: Any]?) {
            state = userInfo?["Player State"] as? String
            title = userInfo?["Name"] as? String
            artist = userInfo?["Artist"] as? String
            album = userInfo?["Album"] as? String
            durationMilliseconds = (userInfo?["Duration"] ?? userInfo?["Total Time"]) as? Double
            position = userInfo?["Playback Position"] as? Double
        }
    }

    private func requestRefresh() {
        refreshTask?.cancel()
        artworkTask?.cancel(); artworkTask = nil
        refreshTask = Task { [weak self] in
            await self?.refresh()
            guard !Task.isCancelled else { return }
            self?.refreshTask = nil
        }
    }

    private func handle(_ snapshot: PlayerSnapshot) {
        refreshTask?.cancel(); refreshTask = nil
        artworkTask?.cancel(); artworkTask = nil
        if snapshot.state == "Stopped" || !isRunning {
            current = nil
            onUpdate?(nil)
            return
        }
        guard let title = snapshot.title, let position = snapshot.position, let duration = snapshot.durationMilliseconds else {
            requestRefresh() // Müzik: konum için tek sorgu
            return
        }
        let isPlaying = snapshot.state == "Playing"
        var info = NowPlayingInfo(
            title: title, artist: snapshot.artist ?? "", album: snapshot.album ?? "",
            duration: duration / 1000, elapsed: position, timestamp: Date(),
            playbackRate: isPlaying ? 1 : 0, isPlaying: isPlaying,
            artworkData: nil, bundleIdentifier: player.bundleID
        )
        if let cache = artworkCache, cache.key == info.trackKey {
            info.artworkData = cache.data
            current = info
            onUpdate?(info)
            return
        }
        current = info
        onUpdate?(info) // metin anında; kapak geldiğinde ikinci güncelleme
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let data = await self.artwork(for: info.trackKey)
            guard !Task.isCancelled, self.observer != nil,
                  self.current?.trackKey == info.trackKey, var latest = self.current else { return }
            latest.artworkData = data
            self.artworkTask = nil
            self.current = latest
            self.onUpdate?(latest)
        }
    }

    /// Tek bir Apple Event ile tüm durumu alır: {ad, sanatçı, albüm, süre, konum, durum}.
    private func refresh() async {
        let app = player.appName
        let source = """
        tell application "\(app)"
            if player state is stopped then return {}
            return {name of current track, artist of current track, album of current track, ¬
                    duration of current track, player position, (player state as string)}
        end tell
        """
        let scale = player.durationScale
        let snapshot = await script(source) { descriptor -> NowPlayingInfo? in
            guard descriptor.numberOfItems >= 6 else { return nil }
            func string(_ index: Int) -> String { descriptor.atIndex(index)?.stringValue ?? "" }
            func double(_ index: Int) -> Double { descriptor.atIndex(index)?.doubleValue ?? 0 }
            let state = string(6)
            return NowPlayingInfo(
                title: string(1), artist: string(2), album: string(3),
                duration: double(4) * scale, elapsed: double(5), timestamp: Date(),
                playbackRate: state == "playing" ? 1 : 0, isPlaying: state == "playing",
                artworkData: nil, bundleIdentifier: nil
            )
        }
        guard !Task.isCancelled, observer != nil else { return }
        guard var info = snapshot, !info.title.isEmpty else {
            current = nil
            onUpdate?(nil)
            return
        }
        info.bundleIdentifier = player.bundleID
        info.artworkData = await artwork(for: info.trackKey)
        guard !Task.isCancelled, observer != nil else { return }
        current = info
        onUpdate?(info)
    }

    private func artwork(for key: String) async -> Data? {
        if let cache = artworkCache, cache.key == key { return cache.data }
        let data: Data?
        switch player.artwork {
        case .url(let source):
            let urlString = await script(source) { $0.stringValue }
            if let urlString, let url = URL(string: urlString) {
                data = try? await URLSession.shared.data(from: url).0
            } else {
                data = nil
            }
        case .rawData(let source):
            data = await script(source) { $0.data }
        }
        guard !Task.isCancelled else { return nil }
        artworkCache = (key, data)
        return data
    }
}
