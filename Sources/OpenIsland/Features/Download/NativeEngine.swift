import AVFoundation
import Foundation
import IslandCore

/// Uygulama içi indirme motoru: yardımcı süreç, Python veya paketlenmiş ikili yoktur. Her inceleme kendi geçici
/// (`ephemeral`) oturumunu açar: çerezler yalnız bellekte ve yalnız bu işe aittir (kullanıcının Safari/sistem çerezleri
/// okunmaz, yazılmaz). Oturum ancak inceleme→indirme sürecinde yaşar ve form sıfırlanınca kapatılır.
final class NativeEngine: @unchecked Sendable {
    private let session: URLSession
    private let platform: LinkPlatform
    private let testOrigin: URL?
    private static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// İnceleme toplam süresi ve indirmede veri gelmeden geçebilecek en uzun süre. Büyük indirme toplam süreyle kesilmez.
    /// Yalnız yalıtılmış geliştirici koşusu kısaltabilir (zaman aşımı testi).
    static let timeouts: (inspect: TimeInterval, stall: TimeInterval) = {
        let environment = ProcessInfo.processInfo.environment
        guard isolatedRun, let parts = environment["OPENISLAND_TEST_DOWNLOAD_TIMEOUTS"]?.split(separator: ",").compactMap({ Double($0) }),
              parts.count == 2 else { return (30, 30) }
        return (parts[0], parts[1])
    }()

    private static var isolatedRun: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["OPENISLAND_DIAGNOSTICS"] != nil && environment["OPENISLAND_TEST_ROOT"]?.hasPrefix("/") == true
    }

    init(platform: LinkPlatform) {
        self.platform = platform
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = Self.timeouts.stall
        configuration.timeoutIntervalForResource = 24 * 3600
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpAdditionalHeaders = ["Accept-Language": "en-US,en;q=0.9"]
        session = URLSession(configuration: configuration)
        // Yalnız yalıtılmış test koşusu: bütün istekler yerel fikstür sunucusuna yönlendirilir (ağ yok).
        let origin = ProcessInfo.processInfo.environment["OPENISLAND_TEST_DOWNLOAD_ORIGIN"]
        testOrigin = Self.isolatedRun ? origin.flatMap(URL.init(string:)).flatMap { $0.host == "127.0.0.1" ? $0 : nil } : nil
    }

    func invalidate() { session.invalidateAndCancel() }

    // MARK: - İnceleme

    func inspect(_ url: URL) async throws -> (media: ExtractedMedia, referer: URL?) {
        try await withThrowingTaskGroup(of: (ExtractedMedia, URL?).self) { group in
            group.addTask { try await self.extract(url) }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.timeouts.inspect))
                throw DownloadFailure.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func extract(_ url: URL) async throws -> (ExtractedMedia, URL?) {
        switch platform {
        case .youtube:
            throw DownloadFailure.unsupported // YouTube uygulama içinde çözülmez: isteğe bağlı motor (`YouTubeEngine`)
        case .x:
            guard let id = XExtractor.statusID(url), let api = XExtractor.syndicationURL(id: id) else { throw DownloadFailure.unsupported }
            let (data, status) = try await get(api, agent: "Googlebot")
            if status == 404 { throw DownloadFailure.removed }
            guard status == 200 else { throw DownloadFailure.other }
            var media = try XExtractor.parse(data, id: id).get()
            media.sources = await probeDimensions(media.sources)
            guard !media.sources.isEmpty else { throw DownloadFailure.other }
            return (media, nil)
        case .tiktok:
            var page = url
            if TikTokExtractor.isShortLink(url) { page = try await resolve(url) }
            guard let id = TikTokExtractor.videoID(page) else { throw DownloadFailure.unsupported }
            page = TikTokExtractor.pageURL(id: id)
            let (data, status) = try await get(page, agent: Self.browserAgent)
            if status == 404 { throw DownloadFailure.removed }
            guard status == 200 else { throw DownloadFailure.other }
            return (try TikTokExtractor.parse(html: String(decoding: data, as: UTF8.self)).get(), page)
        case .facebook:
            let page = FacebookExtractor.pageURL(url)
            let (data, status) = try await get(page, agent: Self.browserAgent)
            if status == 404 { throw DownloadFailure.removed }
            guard status == 200 else { throw DownloadFailure.other }
            var media = try FacebookExtractor.parse(html: String(decoding: data, as: UTF8.self)).get()
            // Sayfa boyut bildirmez: gerçek genişlik/yükseklik dosyanın kendisinden (yalnız başlık baytları) okunur.
            media.sources = await probeDimensions(media.sources)
            guard !media.sources.isEmpty else { throw DownloadFailure.other }
            return (media, page)
        }
    }

    private func get(_ url: URL, agent: String) async throws -> (Data, Int) {
        var request = URLRequest(url: route(url))
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= 16 << 20 else { throw DownloadFailure.other }
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError { throw Self.failure(error) }
    }

    /// Kısa bağlantının yönlendirdiği adres (gövde okunmaz).
    private func resolve(_ url: URL) async throws -> URL {
        var request = URLRequest(url: route(url))
        request.httpMethod = "HEAD"
        request.setValue("facebookexternalhit/1.1", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            return unroute(response.url ?? url)
        } catch let error as URLError { throw Self.failure(error) }
    }

    /// Boyutu bilinmeyen kaynakların gerçek genişlik/yüksekliği ve ses izi dosyanın başlığından okunur (Range istekleri);
    /// boyutu zaten bilinen kaynaklara dokunulmaz, okunamayan kaynak listelenmez.
    private func probeDimensions(_ sources: [DirectSource]) async -> [DirectSource] {
        await withTaskGroup(of: DirectSource?.self) { group in
            for source in sources {
                guard source.format.width == nil || source.format.height == nil else { group.addTask { source }; continue }
                group.addTask {
                    let asset = AVURLAsset(url: self.route(source.url))
                    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                          let size = try? await track.load(.naturalSize) else { return nil }
                    let transform = (try? await track.load(.preferredTransform)) ?? .identity
                    let shown = size.applying(transform)
                    var s = source
                    s.format.width = Int(abs(shown.width).rounded())
                    s.format.height = Int(abs(shown.height).rounded())
                    s.format.acodec = (try? await asset.loadTracks(withMediaType: .audio).isEmpty) == false ? "mp4a.40.2" : "none"
                    return s
                }
            }
            var out: [DirectSource] = []
            for await s in group { if let s { out.append(s) } }
            return sources.compactMap { original in out.first { $0.url == original.url } }
        }
    }

    // MARK: - İndirme

    /// Tek dosyayı hedefe indirir. İlerleme çağrısı arka planda ve birleştirilmiş olarak gelir; iptal görev iptalidir.
    func fetch(_ source: DirectSource, referer: URL?, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: route(source.url))
        request.setValue(platform == .x ? "Googlebot" : Self.browserAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        let box = DownloadBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: request) { location, response, error in
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if let error = error as? URLError {
                        return continuation.resume(throwing: error.code == .cancelled ? CancellationError() : Self.failure(error))
                    }
                    guard let location, (200...299).contains(status) else {
                        // Süresi dolmuş/kaldırılmış adres: başka kaliteye sessizce geçilmez.
                        return continuation.resume(throwing: [403, 404, 410].contains(status) ? DownloadFailure.formatGone : DownloadFailure.other)
                    }
                    do {
                        try? FileManager.default.removeItem(at: file)
                        try FileManager.default.moveItem(at: location, to: file)
                        continuation.resume()
                    } catch let error as CocoaError {
                        continuation.resume(throwing: error.code == .fileWriteOutOfSpace ? DownloadFailure.diskFull : DownloadFailure.writePermission)
                    } catch {
                        continuation.resume(throwing: DownloadFailure.other)
                    }
                }
                box.observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
        box.observation = nil
    }

    // MARK: - Yardımcılar

    private func route(_ url: URL) -> URL {
        guard let testOrigin, let host = url.host else { return url }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.scheme = testOrigin.scheme; c.host = testOrigin.host; c.port = testOrigin.port
        c.path = "/" + host + url.path
        return c.url ?? url
    }

    private func unroute(_ url: URL) -> URL {
        guard testOrigin != nil, url.host == "127.0.0.1" else { return url }
        let parts = url.path.split(separator: "/", maxSplits: 1)
        guard let host = parts.first else { return url }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.scheme = "https"; c.host = String(host); c.port = nil
        c.path = "/" + (parts.count > 1 ? String(parts[1]) : "")
        return c.url ?? url
    }

    static func failure(_ error: URLError) -> DownloadFailure {
        switch error.code {
        case .timedOut: .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed: .network
        case .cannotWriteToFile, .cannotCreateFile, .cannotMoveFile: .writePermission
        default: .other
        }
    }
}

private final class DownloadBox: @unchecked Sendable {
    var task: URLSessionDownloadTask?
    var observation: NSKeyValueObservation?
}
