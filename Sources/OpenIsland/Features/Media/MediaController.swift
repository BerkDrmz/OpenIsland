import AppKit
import IslandCore
import SwiftUI

/// Birden çok medya kaynağını birleştirir, en ilgili olanı seçer ve komutları ona yönlendirir.
///
/// Kaynak önceliği: (1) sistem geneli (MediaRemote / adapter — web oynatıcılar dahil),
/// (2) uygulamaya özel AppleScript kaynakları. Çalan kaynak her zaman duraklatılmış olana üstün gelir.
@MainActor
@Observable
final class MediaController {
    private(set) var nowPlaying: NowPlayingInfo?
    private(set) var artwork: NSImage?
    /// Albüm kapağının ortalama renginden türetilen vurgu rengi (süre çubuğu ve kapak gölgesi için).
    private(set) var accentColor: Color = .white
    /// Aynı rengin Core Animation katmanları (dalga biçimi, süre çubuğu) için AppKit karşılığı.
    private(set) var accentNSColor: NSColor = .white
    /// Albüm renginde nabız (`PulseTint`); gri tonlu kapakta veya kapak yokken `nil` (varsayılan amber).
    private(set) var pulseNSColor: NSColor?
    private(set) var activeSourceID: String?

    @ObservationIgnored var onPlaybackChange: ((Bool) -> Void)?
    /// Çalan/duraklatılmış parça kalmadı (oynatıcı durdu veya kapandı).
    @ObservationIgnored var onSessionEnd: (() -> Void)?
    /// Çalarken parça değiştiğinde (kısa "sneak peek" bildirimi için).
    @ObservationIgnored var onTrackChange: ((NowPlayingInfo) -> Void)?
    @ObservationIgnored private var sources: [MediaSource] = []
    @ObservationIgnored private var latest: [String: NowPlayingInfo] = [:]
    @ObservationIgnored private var artworkData: Data?
    @ObservationIgnored private var cachedApplicationID: String?
    @ObservationIgnored private var cachedApplication: NSRunningApplication?

    var isPlaying: Bool { nowPlaying?.isPlaying ?? false }

    func start() {
        guard sources.isEmpty else { return }
        if let paths = MediaRemoteAdapterSource.bundledPaths() {
            sources.append(MediaRemoteAdapterSource(paths: paths))
        } else if MediaRemote.canReadNowPlayingDirectly {
            sources.append(MediaRemoteSource())
        }
        sources.append(ScriptedPlayerSource(player: ScriptedPlayerSource.spotify))
        sources.append(ScriptedPlayerSource(player: ScriptedPlayerSource.music))

        for source in sources {
            let id = source.id
            source.onUpdate = { [weak self] info in self?.receive(info, from: id) }
            source.start()
        }
    }

    func stop() {
        sources.forEach { $0.stop() }
    }

    /// Uyanmada: kapanmış/geri çekilmiş arka uçlara (adaptör, AppleScript) yeni bir sınırlı hak.
    func recover() {
        sources.forEach { $0.recover() }
    }

    /// A granted permission resets only the matching player's denial backoff, then reads once.
    func recoverAutomation(for bundleID: String) {
        sources.first(where: { $0.id == bundleID })?.recover()
    }

    // MARK: - Komutlar

    func togglePlayPause() { send(.togglePlayPause) }
    func nextTrack() { send(.nextTrack) }
    func previousTrack() { send(.previousTrack) }

    /// Etkin kaynak konum değiştirebiliyor mu. Canlı yayınlarda (süre 0) veya desteklemeyen arka uçta
    /// süre çubuğu salt okunur olur; kullanıcıya çalışmayan bir kontrol sunulmaz.
    var canSeek: Bool {
        guard let info = nowPlaying, info.duration > 0, let activeSource else { return false }
        return activeSource.supportsSeeking
    }

    func seek(to time: TimeInterval) {
        guard canSeek, let source = activeSource, var info = nowPlaying else { return }
        let previous = info
        // İyimser güncelleme: kaynaktan yanıt gelene kadar kaydırıcı geri zıplamasın.
        info.elapsed = time
        info.timestamp = Date()
        nowPlaying = info
        Task { [weak self] in
            let accepted = await source.seek(to: time)
            // Arka uç reddettiyse sahte başarı gösterme: bu arada başka bir güncelleme gelmediyse eski konuma dön.
            guard !accepted, let self, self.nowPlaying == info else { return }
            self.nowPlaying = previous
        }
    }

    // MARK: - Kaynak uygulama

    /// Müziği çalan uygulama (çalışıyorsa). Web oynatıcılarda tarayıcının kendisi.
    /// Kaynak güvenilir şekilde bilinmiyorsa `nil`: yanlış bir uygulamayı öne getirmektense hiçbir şey yapılmaz.
    var sourceApplication: NSRunningApplication? {
        guard let bundleID = nowPlaying?.bundleIdentifier else { return nil }
        // Repeated body/layout evaluation must not repeatedly query LaunchServices for the same player.
        // A terminated instance is never reused; a missing player is queried again on the next UI access.
        if cachedApplicationID == bundleID, let cachedApplication, !cachedApplication.isTerminated,
           cachedApplication.activationPolicy == .regular {
            return cachedApplication
        }
        cachedApplicationID = bundleID
        cachedApplication = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.activationPolicy == .regular }
        return cachedApplication
    }

    /// Kaynak uygulamayı öne getirir. Kapalıysa başlatılmaz; çalışan örnek Dock'tan tıklanmış gibi etkinleşir
    /// (penceresi kapalıysa yeniden açar). Etkin olmayan bir paneldan etkinleştirme macOS 14+ işbirlikli
    /// etkinleştirme kuralına takılmasın diye LaunchServices üzerinden yapılır.
    func revealSourceApplication() {
        guard let application = sourceApplication else { return }
        AppHandoff.reveal(application)
    }

    private var activeSource: MediaSource? {
        sources.first { $0.id == activeSourceID }
    }

    private func send(_ command: MediaCommand) {
        if let activeSource {
            activeSource.perform(command)
        } else {
            // Bilgi okunamasa bile MediaRemote komutları (15.4+ dahil) herhangi bir oynatıcıya ulaşır.
            MediaRemote.send(command)
        }
    }

    // MARK: - Kaynak seçimi

    private func receive(_ info: NowPlayingInfo?, from id: String) {
        latest[id] = info
        let candidates = sources.compactMap { source in latest[source.id].map { (source.id, $0) } }
        let chosen = candidates.first { $0.1.isPlaying }
            ?? candidates.first { $0.0 == activeSourceID }
            ?? candidates.first

        let wasPlaying = isPlaying
        let hadSession = nowPlaying != nil
        let previousTrack = nowPlaying?.trackKey
        // Gözlemciler yalnızca gerçekten değişen değerde uyansın.
        if activeSourceID != chosen?.0 { activeSourceID = chosen?.0 }
        if nowPlaying != chosen?.1 { nowPlaying = chosen?.1 }
        updateArtwork(for: chosen?.1)
        if wasPlaying != isPlaying { onPlaybackChange?(isPlaying) }
        if hadSession, nowPlaying == nil { onSessionEnd?() }
        if let info = nowPlaying, info.isPlaying, let previousTrack, previousTrack != info.trackKey {
            onTrackChange?(info)
        }
    }

    private func updateArtwork(for info: NowPlayingInfo?) {
        let data = info?.artworkData
        // Track metadata can change while the album cover stays identical. Reuse the decoded
        // image and derived colors; equal byte counts alone do not identify equal artwork.
        guard data != artworkData else { return }
        artworkData = data
        guard let data, let image = NSImage(data: data) else {
            artwork = nil
            accentColor = .white
            accentNSColor = .white
            pulseNSColor = nil
            return
        }
        artwork = image
        let accent = image.averageColor ?? .white
        accentNSColor = accent
        accentColor = Color(nsColor: accent)
        // Parça başına bir kez: 24 × 24 pikselden baskın canlı ton (ortalama değil; bkz. `PulseTint`).
        pulseNSColor = PulseTint.albumTint(pixels: image.samplePixels(side: 24))
            .map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
    }
}

extension NSImage {
    /// Görseli `side` × `side` sRGB piksele küçültür (nabız rengi için; tek seferlik, küçük).
    func samplePixels(side: Int) -> [PulseTint.RGB] {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &buffer, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 0, to: buffer.count, by: 4).map {
            PulseTint.RGB(red: Double(buffer[$0]) / 255, green: Double(buffer[$0 + 1]) / 255, blue: Double(buffer[$0 + 2]) / 255)
        }
    }

    /// 1×1 piksele küçülterek ortalama rengi bulur; çok koyu renkler okunabilirlik için açılır.
    var averageColor: NSColor? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(
            srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255, alpha: 1
        )
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(hue: hue, saturation: min(saturation * 1.2, 0.85), brightness: max(brightness, 0.75), alpha: 1)
    }
}
