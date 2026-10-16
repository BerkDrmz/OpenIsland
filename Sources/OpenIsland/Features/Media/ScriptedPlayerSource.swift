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
        case urlWithDuration(String)
        case rawData(String)
    }

    static let spotify = Player(
        bundleID: "com.spotify.client",
        appName: "Spotify",
        notification: "com.spotify.client.PlaybackStateChanged",
        durationScale: 0.001,
        artwork: .urlWithDuration("tell application \"Spotify\" to return {artwork url of current track, duration of current track, id of current track}")
    )

    static let music = Player(
        bundleID: "com.apple.Music",
        appName: "Music",
        notification: "com.apple.Music.playerInfo",
        durationScale: 1,
        artwork: .rawData("tell application \"Music\" to get raw data of artwork 1 of current track")
    )

    /// Bildirim taşımayan konum değişikliklerinin olay güdümlü eşitlenmesi.
    ///
    /// Spotify (1.3.x) kendi arayüzünden yapılan sarmada dağıtık bildirim göndermez. Model yalnız bildirimden
    /// ekstrapole ettiği için geri sarmada süreye erken ulaşıp (kırpılarak) "4:52 / −0:00, dolu çubuk" gösteriyordu.
    /// Bildirimler arasında model, oynatıcının konumuyla ±0,1 sn içinde kalır; bu yüzden çalma başlangıcında okuma
    /// yapılmaz. Sürekli yoklama yerine yalnızca şu anlarda tek bir hafif okuma yapılır: öngörülen parça sonunda
    /// bildirim gelmediyse (sınırlı), kullanıcı oynatıcıdan ayrıldığında ve medya paneli görünür olduğunda (çalarken,
    /// sınırlı sıklıkta). Panel görünür ve çalarken oynatıcının kendi penceresindeki sarma da (oynatıcı öndeyken
    /// fare bırakılınca) tek okumayla yakalanır; bu izleyici yalnızca o durumda kuruludur.
    struct PositionSyncTiming: Sendable {
        var endGrace: TimeInterval = 1.5
        /// Bu kadar sapma yoksa yeniden yayınlanmaz (çubuk animasyonu boşuna yeniden kurulmaz).
        var tolerance: TimeInterval = 0.75
        var visibleMinimumInterval: TimeInterval = 10
        var endChecks = 3
        /// Oynatıcıda fare bırakıldıktan sonra okuma: sarmanın uygulanmasına ve çift tıklamaya pay.
        var clickSettle: TimeInterval = 0.35
        /// Spotify yeni parçada önce bildirimdeki süreyi verir, ≈0,5 sn sonra gerçek süreyi bildirimsiz düzeltir
        /// (canlı ölçüm: 3/3 parçada 6,29 sn fark). Yeni parça çalarken bu kadar sonra tek doğrulama okuması.
        var trackSettle: TimeInterval = 1.5
        /// Uygulamanın kendi komutundan (ör. "önceki parça" = baştan başlat) sonra bildirim gelmezse tek okuma.
        var commandSettle: TimeInterval = 0.5
        static let standard = PositionSyncTiming()
    }

    let player: Player
    var id: String { player.bundleID }
    let isSystemWide = false
    var onUpdate: ((NowPlayingInfo?) -> Void)?

    private let runningCheck: () -> Bool
    private let frontmostCheck: () -> Bool
    private let downloadArtwork: @MainActor (URL) async -> Data?
    private var observer: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var current: NowPlayingInfo? {
        didSet { if oldValue?.isPlaying != current?.isPlaying { updateClickMonitor() } }
    }
    // Spotify identity stays source-local; NowPlayingInfo.trackKey remains unchanged for other users.
    private enum TrackIdentity: Equatable {
        case spotify(String)
        case display(String)
    }
    private struct ArtworkCache {
        let key: TrackIdentity
        var data: Data?
        var duration: TimeInterval?
        let url: URL?
        var isComplete: Bool
    }
    private var currentIdentity: TrackIdentity?
    private var generation: UInt64 = 0
    /// Apple Event sağlığı: izin reddinde veya tekrarlayan hatada sınırlı geri çekilme.
    private var health = BackendHealth()
    private var artworkCache: ArtworkCache?
    private let positionTiming: PositionSyncTiming
    private var positionTask: Task<Void, Never>?
    private var deactivationObserver: NSObjectProtocol?
    private var lastPositionSync = Date.distantPast
    private var endChecksLeft = 0
    /// Süre çubuğu görünür mü (MediaController bildirir). Tıklama izleyicisi yalnızca görünür + çalarken kurulur.
    private var isPositionWatched = false
    private var clickMonitor: Any?

    /// Await the existing event-driven task in checks; never starts or polls for work.
    var pendingUpdate: Task<Void, Never>? { artworkTask ?? refreshTask }
    /// Planlanmış veya süren konum eşitlemesi (yalnız denetimler için; yeni iş başlatmaz).
    var pendingPositionSync: Task<Void, Never>? { positionTask }
    /// Denetimler için: oynatıcı tıklama izleyicisi kurulu mu.
    var isWatchingPlayerClicks: Bool { clickMonitor != nil }

    init(player: Player, isRunning: (() -> Bool)? = nil,
         positionTiming: PositionSyncTiming = .standard,
         isFrontmost: (() -> Bool)? = nil,
         downloadArtwork: @escaping @MainActor (URL) async -> Data? = { url in
             try? await URLSession.shared.data(from: url).0
         }) {
        self.player = player
        self.positionTiming = positionTiming
        self.downloadArtwork = downloadArtwork
        runningCheck = isRunning ?? {
            NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).contains { !$0.isTerminated }
        }
        frontmostCheck = isFrontmost ?? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == player.bundleID }
    }

    private var isRunning: Bool { runningCheck() }

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(player.notification), object: nil, queue: .main
        ) { [weak self] note in
            let snapshot = PlayerSnapshot(userInfo: note.userInfo)
            MainActor.assumeIsolated {
                guard let self, self.observer != nil else { return }
                self.handle(snapshot)
            }
        }
        // Sarma oynatıcının kendi penceresinde yapılır: kullanıcı oradan ayrılınca konum bir kez okunur.
        deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, bundleID == self.player.bundleID else { return }
                self.requestPositionSync(minimumInterval: 0)
            }
        }
        if isRunning { requestRefresh() }
    }

    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        if let deactivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(deactivationObserver) }
        deactivationObserver = nil
        cancelPendingWork()
        updateClickMonitor()
    }

    /// Medya paneli göründüğünde (yalnız çalarken, sınırlı sıklıkta): bildirimsiz sarmayı yakalar.
    func synchronizePosition() {
        guard current?.isPlaying == true else { return }
        requestPositionSync(minimumInterval: positionTiming.visibleMinimumInterval)
    }

    /// Süre çubuğu göründü/kayboldu. Görünür ve çalarken oynatıcıdaki fare bırakması tek konum okuması tetikler;
    /// sistem geneli izleyici yalnızca tıklamada uyanır, fare hareketini veya tuşları dinlemez.
    func setPositionWatch(_ active: Bool) {
        guard active != isPositionWatched else { return }
        isPositionWatched = active
        updateClickMonitor()
    }

    /// Oynatıcıda fare bırakıldı (izleyici ve denetimler aynı yolu kullanır).
    func receivePlayerClick() {
        guard clickMonitor != nil, frontmostCheck() else { return }
        requestPositionSync(minimumInterval: 0, after: positionTiming.clickSettle)
    }

    private func updateClickMonitor() {
        let wanted = isPositionWatched && observer != nil && current?.isPlaying == true
        if wanted, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                MainActor.assumeIsolated { self?.receivePlayerClick() }
            }
        } else if !wanted, let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    func recover() {
        prepareUserRetry()
        if observer != nil, isRunning { requestRefresh() }
    }

    /// Tek giriş noktası: sağlık izin vermiyorsa Apple Event hiç gönderilmez.
    private func script<T: Sendable>(_ source: String, cacheResult: Bool = true, transform: @escaping @Sendable (NSAppleEventDescriptor) -> T?) async -> T? {
        guard !Task.isCancelled, health.allows() else { return nil }
        let expectedGeneration = generation
        let outcome = await ScriptRunner.shared.execute(source, cacheResult: cacheResult, transform: transform)
        guard !Task.isCancelled else { return nil }
        guard generation == expectedGeneration else { return outcome.value }
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
        // Retry failed artwork without discarding already verified Spotify metadata.
        if var cache = artworkCache, cache.data == nil, cache.isComplete {
            if cache.duration != nil {
                cache.isComplete = cache.url == nil
                artworkCache = cache
            } else {
                artworkCache = nil
            }
        }
    }

    private func fire(_ source: String) {
        // Oynatıcı bazı komutlarda (çalarken "önceki parça" parçayı baştan başlatır) bildirim göndermez.
        // Komuttan sonra bildirim gelirse `handle` kuşağı ilerletir ve aşağıdaki okuma yapılmaz.
        let expectedGeneration = generation
        Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.prepareUserRetry()
            _ = await self.script(source) { _ in true }
            try? await Task.sleep(for: .seconds(self.positionTiming.commandSettle))
            guard self.generation == expectedGeneration else { return }
            self.requestPositionSync(minimumInterval: 0)
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
        let trackID: String?
        /// Her iki uygulamada da milisaniye.
        let durationMilliseconds: Double?
        /// Yalnızca Spotify gönderir (saniye).
        let position: Double?

        init(userInfo: [AnyHashable: Any]?) {
            state = userInfo?["Player State"] as? String
            title = userInfo?["Name"] as? String
            artist = userInfo?["Artist"] as? String
            album = userInfo?["Album"] as? String
            trackID = userInfo?["Track ID"] as? String
            durationMilliseconds = (userInfo?["Duration"] ?? userInfo?["Total Time"]) as? Double
            position = userInfo?["Playback Position"] as? Double
        }
    }

    private func requestRefresh() {
        cancelPendingWork()
        refreshTask = Task { [weak self] in
            await self?.refresh()
            guard !Task.isCancelled else { return }
            self?.refreshTask = nil
        }
    }

    private var usesSpotifyIdentity: Bool {
        if case .urlWithDuration = player.artwork { return true }
        return false
    }

    private func identity(for info: NowPlayingInfo, trackID: String?) -> TrackIdentity {
        if usesSpotifyIdentity, let trackID, !trackID.isEmpty { return .spotify(trackID) }
        // Notifications lacking an ID can still refer to the authoritative initial-refresh track.
        if usesSpotifyIdentity, current?.trackKey == info.trackKey, let currentIdentity {
            return currentIdentity
        }
        return .display(info.trackKey)
    }

    private func cancelPendingWork() {
        generation &+= 1
        refreshTask?.cancel(); refreshTask = nil
        artworkTask?.cancel(); artworkTask = nil
        positionTask?.cancel(); positionTask = nil
    }

    private func isActive(_ expectedGeneration: UInt64) -> Bool {
        !Task.isCancelled && observer != nil && generation == expectedGeneration
    }

    // The distributed observer and deterministic checks use the same event path.
    func receivePlayerNotification(_ userInfo: [AnyHashable: Any]?) {
        guard observer != nil else { return }
        handle(PlayerSnapshot(userInfo: userInfo))
    }

    private func handle(_ snapshot: PlayerSnapshot) {
        cancelPendingWork()
        if snapshot.state == "Stopped" || !isRunning {
            current = nil
            currentIdentity = nil
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
        let key = identity(for: info, trackID: snapshot.trackID)
        let isNewTrack = currentIdentity != key
        currentIdentity = key
        if let cache = artworkCache, cache.key == key {
            info.artworkData = cache.data
            info.duration = cache.duration ?? info.duration
        }
        current = info
        onUpdate?(info) // metin anında; kapak geldiğinde ikinci güncelleme
        // Bildirim taze konumdur; yalnızca öngörülen parça sonunun doğrulaması planlanır.
        endChecksLeft = positionTiming.endChecks
        schedulePositionCheck(isNewTrack && usesSpotifyIdentity ? .trackSettle : .predictedEnd)
        guard artworkCache?.key != key || artworkCache?.isComplete != true else { return }
        let expectedGeneration = generation
        artworkTask = Task { [weak self] in
            guard let self, self.isActive(expectedGeneration) else { return }
            let data = await self.artwork(for: key, generation: expectedGeneration)
            guard self.isActive(expectedGeneration), var latest = self.current else { return }
            latest.artworkData = data
            if let cache = self.artworkCache, cache.key == self.currentIdentity {
                latest.duration = cache.duration ?? latest.duration
            }
            self.artworkTask = nil
            self.current = latest
            self.onUpdate?(latest)
        }
    }

    /// Tek bir Apple Event ile tüm durumu alır: {ad, sanatçı, albüm, süre, konum, durum}.
    private func refresh() async {
        let expectedGeneration = generation
        let app = player.appName
        let identityField = usesSpotifyIdentity ? ", id of current track" : ""
        let source = """
        tell application "\(app)"
            if player state is stopped then return {}
            return {name of current track, artist of current track, album of current track, ¬
                    duration of current track, player position, (player state as string)\(identityField)}
        end tell
        """
        let scale = player.durationScale
        let snapshot = await script(source) { descriptor -> (NowPlayingInfo, String?)? in
            guard descriptor.numberOfItems >= 6 else { return nil }
            func string(_ index: Int) -> String { descriptor.atIndex(index)?.stringValue ?? "" }
            func double(_ index: Int) -> Double { descriptor.atIndex(index)?.doubleValue ?? 0 }
            let state = string(6)
            let info = NowPlayingInfo(
                title: string(1), artist: string(2), album: string(3),
                duration: double(4) * scale, elapsed: double(5), timestamp: Date(),
                playbackRate: state == "playing" ? 1 : 0, isPlaying: state == "playing",
                artworkData: nil, bundleIdentifier: nil
            )
            return (info, descriptor.atIndex(7)?.stringValue)
        }
        guard isActive(expectedGeneration) else { return }
        guard let snapshot, !snapshot.0.title.isEmpty else {
            current = nil
            currentIdentity = nil
            onUpdate?(nil)
            schedulePositionCheck(.predictedEnd)
            return
        }
        var info = snapshot.0
        info.bundleIdentifier = player.bundleID
        let key = identity(for: info, trackID: snapshot.1)
        if var cache = artworkCache, cache.key == key {
            info.artworkData = cache.data
            // This is a fresh control-API reading, not a distributed notification.
            // Same-ID metadata can change; cached duration must not override newer truth.
            if usesSpotifyIdentity, info.duration.isFinite, info.duration > 0 {
                if cache.duration != info.duration {
                    cache.duration = info.duration
                    artworkCache = cache
                }
            } else { info.duration = cache.duration ?? info.duration }
        }
        if usesSpotifyIdentity {
            currentIdentity = key
            current = info
            onUpdate?(info)
        }
        let data = await artwork(for: key, generation: expectedGeneration)
        guard isActive(expectedGeneration) else { return }
        if usesSpotifyIdentity, let latest = current { info = latest }
        info.artworkData = data
        if !usesSpotifyIdentity { currentIdentity = key }
        current = info
        onUpdate?(info)
        // Kontrol API'sinden taze okuma: yalnızca öngörülen parça sonunun doğrulaması planlanır.
        endChecksLeft = positionTiming.endChecks
        schedulePositionCheck(.predictedEnd)
    }

    // MARK: - Konum eşitleme

    private enum PositionCheck { case predictedEnd, trackSettle, external }

    /// En fazla bir bekleyen görev; her yeni bildirim/okuma onu iptal eder. Çalmıyorsa hiçbir şey planlanmaz.
    private func schedulePositionCheck(_ kind: PositionCheck) {
        positionTask?.cancel(); positionTask = nil
        guard observer != nil, let info = current, info.isPlaying else { return }
        let delay: TimeInterval
        switch kind {
        case .predictedEnd:
            guard info.duration > 0, endChecksLeft > 0 else { return }
            delay = max(info.duration - info.elapsed(at: Date()), 0) + positionTiming.endGrace
        case .trackSettle:
            delay = positionTiming.trackSettle
        case .external:
            delay = 0
        }
        let expectedGeneration = generation
        positionTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, self.isActive(expectedGeneration) else { return }
            await self.synchronizePosition(kind, generation: expectedGeneration)
        }
    }

    private func requestPositionSync(minimumInterval: TimeInterval, after delay: TimeInterval = 0) {
        guard observer != nil, refreshTask == nil, current != nil, isRunning,
              Date().timeIntervalSince(lastPositionSync) >= minimumInterval else { return }
        positionTask?.cancel(); positionTask = nil
        let expectedGeneration = generation
        positionTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, self.isActive(expectedGeneration) else { return }
            await self.synchronizePosition(.external, generation: expectedGeneration)
        }
    }

    /// Tek Apple Event: {konum, durum, kimlik}. Aynı parçada sapma eşiği aşılırsa konum, okuma anına göre
    /// yeniden yayınlanır; parça farklıysa mevcut tam yenileme kullanılır. Kapak ve süre bu yoldan değişmez.
    private func synchronizePosition(_ kind: PositionCheck, generation expectedGeneration: UInt64) async {
        guard isRunning, current != nil else { return }
        let identityField = usesSpotifyIdentity ? "id of current track" : "name of current track"
        let source = """
        tell application "\(player.appName)"
            if player state is stopped then return {}
            return {player position, (player state as string), \(identityField), duration of current track}
        end tell
        """
        let scale = player.durationScale
        let sent = Date()
        let reading = await script(source) { descriptor -> (Double, String, String, Double?)? in
            guard descriptor.numberOfItems >= 3, let position = descriptor.atIndex(1)?.doubleValue else { return nil }
            let duration = descriptor.numberOfItems >= 4 ? descriptor.atIndex(4).map { $0.doubleValue * scale } : nil
            return (position, descriptor.atIndex(2)?.stringValue ?? "", descriptor.atIndex(3)?.stringValue ?? "", duration)
        }
        let received = Date()
        guard isActive(expectedGeneration), var info = current else { return }
        positionTask = nil
        lastPositionSync = received
        // Okunamadı: mevcut sağlık/geri çekilme kuralı geçerli, yeniden planlama yok.
        guard let reading, reading.0.isFinite, reading.0 >= 0 else { return }
        let sameTrack = usesSpotifyIdentity ? currentIdentity == .spotify(reading.2) : info.title == reading.2
        guard sameTrack else { requestRefresh(); return }
        let isPlaying = reading.1 == "playing"
        let instant = sent.addingTimeInterval(received.timeIntervalSince(sent) / 2)
        // Oynatıcının sonradan düzelttiği süre (yeni Spotify parçası): önbellek ve yayın aynı kimlikte güncellenir.
        var durationChanged = false
        if let duration = reading.3, duration.isFinite, duration > 0, abs(duration - info.duration) > 0.5 {
            info.duration = duration
            durationChanged = true
            if var cache = artworkCache, cache.key == currentIdentity {
                cache.duration = duration
                artworkCache = cache
            }
        }
        if durationChanged || isPlaying != info.isPlaying || abs(info.elapsed(at: instant) - reading.0) > positionTiming.tolerance {
            info.elapsed = reading.0
            info.timestamp = instant
            info.isPlaying = isPlaying
            info.playbackRate = isPlaying ? 1 : 0
            current = info
            onUpdate?(info)
            endChecksLeft = positionTiming.endChecks
        } else if kind == .predictedEnd {
            endChecksLeft -= 1
        }
        schedulePositionCheck(.predictedEnd)
    }

    private func artwork(for key: TrackIdentity, generation expectedGeneration: UInt64) async -> Data? {
        guard isActive(expectedGeneration) else { return nil }
        if var cache = artworkCache, cache.key == key {
            if cache.isComplete { return cache.data }
            let data = if let url = cache.url { await downloadArtwork(url) } else { nil as Data? }
            guard isActive(expectedGeneration) else { return nil }
            // A concurrent explicit refresh may have corrected the same-ID duration.
            if let latest = artworkCache, latest.key == key { cache.duration = latest.duration }
            cache.data = data
            cache.isComplete = true
            artworkCache = cache
            return data
        }
        let data: Data?
        switch player.artwork {
        case .url(let source):
            let urlString = await script(source) { $0.stringValue }
            guard isActive(expectedGeneration) else { return nil }
            if let urlString, let url = URL(string: urlString) {
                data = await downloadArtwork(url)
            } else {
                data = nil
            }
        case .urlWithDuration(let source):
            // Spotify's distributed notification can include a different duration than its
            // control API. Read URL, duration and identity in the existing single Apple Event.
            let scale = player.durationScale
            let metadata = await script(source) { descriptor -> (String, Double, String)? in
                guard descriptor.numberOfItems >= 3,
                      let trackID = descriptor.atIndex(3)?.stringValue, !trackID.isEmpty else { return nil }
                return (descriptor.atIndex(1)?.stringValue ?? "", (descriptor.atIndex(2)?.doubleValue ?? 0) * scale, trackID)
            }
            guard isActive(expectedGeneration) else { return nil }
            guard let metadata else { return nil }
            let authoritativeKey = TrackIdentity.spotify(metadata.2)
            if case .spotify = key, key != authoritativeKey { return nil }
            let duration = metadata.1.isFinite && metadata.1 > 0 ? metadata.1 : nil
            let url = URL(string: metadata.0).flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
            // Cache and publish canonical duration before the cancellable network suspension.
            var cache = ArtworkCache(key: authoritativeKey, data: nil, duration: duration, url: url, isComplete: url == nil)
            artworkCache = cache
            currentIdentity = authoritativeKey
            if let duration, var latest = current, latest.duration != duration {
                latest.duration = duration
                current = latest
                onUpdate?(latest)
            }
            guard isActive(expectedGeneration) else { return nil }
            data = if let url { await downloadArtwork(url) } else { nil }
            guard isActive(expectedGeneration) else { return nil }
            cache.data = data
            cache.isComplete = true
            artworkCache = cache
            return data
        case .rawData(let source):
            data = await script(source) { $0.data }
        }
        guard isActive(expectedGeneration) else { return nil }
        artworkCache = ArtworkCache(key: key, data: data, duration: nil, url: nil, isComplete: true)
        return data
    }
}
