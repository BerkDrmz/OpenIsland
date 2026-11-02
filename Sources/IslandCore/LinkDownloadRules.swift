import Foundation

/// İsteğe bağlı "Bağlantıdan indir" özelliğinin saf kuralları: bağlantı doğrulama, motorun format listesinden gerçekten
/// sunulan kaliteleri çıkarma, indirme planı, dosya adı ve hata sınıflandırması. Ağ, süreç veya zamanlayıcı içermez.
public enum LinkPlatform: String, Sendable, CaseIterable {
    case youtube, facebook, x, tiktok

    public var displayName: String {
        switch self {
        case .youtube: "YouTube"
        case .facebook: "Facebook"
        case .x: "X"
        case .tiktok: "TikTok"
        }
    }

    /// YouTube uygulama içi çıkarıcıyla değil, kullanıcının onayıyla indirilen ayrı motorla (yt-dlp + QuickJS) çözülür.
    public var needsEngine: Bool { self == .youtube }

    /// Yalnız bu alan adları (ve alt alan adları) kabul edilir; CDN yönlendirmelerini motor kendisi izler.
    static let hosts: [(String, LinkPlatform)] = [
        ("youtube.com", .youtube), ("youtu.be", .youtube),
        ("facebook.com", .facebook), ("fb.watch", .facebook), ("fb.com", .facebook),
        ("x.com", .x), ("twitter.com", .x),
        ("tiktok.com", .tiktok),
    ]

    public static let supportedNames = "YouTube, Facebook, X veya TikTok"
}

public enum LinkValidation: Equatable, Sendable {
    case valid(URL, LinkPlatform)
    case invalid
    case unsupportedPlatform
}

public enum LinkDownloadRules {
    /// Elle yapıştırılan tek bir http(s) bağlantısı. Yerel dosya, başka protokol, kullanıcı adı/parola, alışılmadık
    /// port ve desteklenmeyen platform reddedilir. Bağlantı motora yalnız `--` sonrasında, tek argüman olarak verilir.
    public static func validate(_ text: String) -> LinkValidation {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.utf8.count <= 2048, !input.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: input, encodingInvalidCharacters: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty, host.contains("."),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 || components.port == 80,
              let url = components.url else { return .invalid }
        let bare = host.hasSuffix(".") ? String(host.dropLast()) : host
        for (domain, platform) in LinkPlatform.hosts where bare == domain || bare.hasSuffix("." + domain) {
            return .valid(url, platform)
        }
        return .unsupportedPlatform
    }
}

/// Motorun (yt-dlp `--dump-single-json`) bildirdiği tek bir format. Bilinmeyen alanlar yok sayılır.
public struct MediaFormat: Decodable, Equatable, Sendable {
    public var id: String
    public var ext: String
    public var vcodec: String?
    public var acodec: String?
    public var width: Int?
    public var height: Int?
    public var filesize: Int64?
    public var filesizeApprox: Int64?
    public var tbr: Double?
    /// Yalnız motor (yt-dlp) bildirir: indirme yolu (`https`, `m3u8_native`…), dil önceliği, ses kanalı sayısı, DRM.
    public var protocolName: String?
    public var languagePreference: Int?
    public var audioChannels: Int?
    public var hasDRM: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "format_id", ext, vcodec, acodec, width, height, filesize, tbr
        case filesizeApprox = "filesize_approx", protocolName = "protocol", languagePreference = "language_preference"
        case audioChannels = "audio_channels", hasDRM = "has_drm"
    }

    public init(id: String, ext: String, vcodec: String?, acodec: String?, width: Int? = nil, height: Int? = nil,
                filesize: Int64? = nil, filesizeApprox: Int64? = nil, tbr: Double? = nil, protocolName: String? = nil,
                languagePreference: Int? = nil, audioChannels: Int? = nil, hasDRM: Bool? = nil) {
        (self.id, self.ext, self.vcodec, self.acodec, self.width, self.height) = (id, ext, vcodec, acodec, width, height)
        (self.filesize, self.filesizeApprox, self.tbr) = (filesize, filesizeApprox, tbr)
        (self.protocolName, self.languagePreference, self.audioChannels, self.hasDRM) = (protocolName, languagePreference, audioChannels, hasDRM)
    }

    /// Codec bildirilmemişse (nil) yt-dlp gibi "var" sayılır; yalnız açık "none" yok demektir.
    public var hasVideo: Bool { vcodec?.lowercased() != "none" && (width ?? 0) > 0 && (height ?? 0) > 0 }
    public var hasAudio: Bool { acodec?.lowercased() != "none" && acodec != "" }
    public var size: Int64? { filesize ?? filesizeApprox }

    /// Kısa kenar: dikey 1080×1920 video "1080p"dir, yalnız yüksekliğe bakılmaz.
    public var shortSide: Int? { hasVideo ? min(width!, height!) : nil }

    /// AVFoundation ile yeniden kodlamadan MP4'e taşınabilir mi.
    public var isMP4Video: Bool { isPassthroughVideo(av1: false) }

    /// `av1`: bu Mac AV1'i donanımda çözüyorsa (M3 ve sonrası) MP4 içindeki AV1 de yeniden kodlamadan taşınır.
    public func isPassthroughVideo(av1: Bool) -> Bool {
        guard hasVideo, ["mp4", "m4v", "mov"].contains(ext.lowercased()) else { return false }
        let codec = (vcodec ?? "").lowercased()
        return ["avc1", "avc3", "h264", "hvc1", "hev1", "h265"].contains { codec.hasPrefix($0) } || (av1 && codec.hasPrefix("av01"))
    }
    public var isMP4Audio: Bool {
        let codec = (acodec ?? "").lowercased()
        return ["m4a", "mp4", "aac"].contains(ext.lowercased()) && (codec.hasPrefix("mp4a") || codec == "aac")
    }
}

/// `--dump-single-json` çıktısının kullanılan kısmı. Oynatma listesi/profil (`_type` playlist) kabul edilmez.
public struct MediaInfo: Decodable, Sendable {
    public var title: String?
    public var type: String?
    public var formats: [MediaFormat]
    public var duration: Double?
    /// `is_live`, `is_upcoming`, `post_live`, `was_live`, `not_live`; bilinmiyorsa nil.
    public var liveStatus: String?

    enum CodingKeys: String, CodingKey { case title, type = "_type", formats, duration, liveStatus = "live_status" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        liveStatus = try? c.decodeIfPresent(String.self, forKey: .liveStatus)
        // Tek bir bozuk format tüm incelemeyi düşürmesin.
        formats = ((try? c.decodeIfPresent([FailableFormat].self, forKey: .formats)) ?? []).compactMap(\.value)
    }

    public var isSingleVideo: Bool { type == nil || type == "video" }
    /// Süren veya başlamamış yayın: dosyası yoktur, indirilmez (biten yayının kaydı indirilebilir).
    public var isLive: Bool { ["is_live", "is_upcoming", "post_live"].contains(liveStatus ?? "") }

    private struct FailableFormat: Decodable {
        var value: MediaFormat?
        init(from decoder: Decoder) throws { value = try? MediaFormat(from: decoder) }
    }
}

/// Gerçek kısa kenara göre kalite basamağı. Büyütme yok: yalnız kaynakta bulunan basamaklar listelenir.
public enum QualityTier: Int, Comparable, Sendable, CaseIterable {
    case low = 0, p360 = 360, p480 = 480, p720 = 720, p1080 = 1080, p1440 = 1440, p2160 = 2160

    public init(shortSide: Int) {
        self = Self.allCases.last { $0 != .low && shortSide >= Int(Double($0.rawValue) * 0.95) } ?? .low
    }

    public var label: String {
        switch self {
        case .low: "360p altı"
        case .p2160: "4K"
        default: "\(rawValue)p"
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum DownloadMode: String, Sendable, CaseIterable {
    case videoWithAudio, videoOnly, audioOnly

    public var title: String {
        switch self {
        case .videoWithAudio: "Video + ses"
        case .videoOnly: "Yalnız video"
        case .audioOnly: "Yalnız ses"
        }
    }

    public var usesQuality: Bool { self != .audioOnly }
}

/// Kullanıcının seçebileceği somut indirme: tek akış ya da ayrı görüntü + ses (yeniden kodlamadan birleştirilir).
public struct DownloadPlan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Tek dosya olduğu gibi indirilir (kapsayıcı `ext`).
        case single(MediaFormat)
        /// Ayrı görüntü + ses akışı; AVFoundation passthrough ile MP4'e taşınır.
        case merge(video: MediaFormat, audio: MediaFormat)
        /// Yalnız birleşik akış var: indirilir, ses izi yeniden kodlamadan M4A'ya ayrılır.
        case extractAudio(from: MediaFormat)
        /// Yalnız birleşik akış var: indirilir, görüntü izi yeniden kodlamadan sessiz MP4'e ayrılır.
        case extractVideo(from: MediaFormat)
    }
    public var kind: Kind
    public var tier: QualityTier?
    /// Kullanıcıya gösterilen gerçek dosya biçimi.
    public var outputExtension: String
    public var estimatedBytes: Int64?
}

/// Bir kalite basamağının durumu: seçilebilir ya da neden seçilemediği.
public struct QualityOption: Equatable, Sendable {
    public var tier: QualityTier
    public var plan: DownloadPlan?
    public var reason: String?
    public var isAvailable: Bool { plan != nil }
}

public enum DownloadPlanner {
    /// Kaynakta gerçekten bulunan görüntü basamakları (yüksekten düşüğe). Birleştirilemeyen bir basamak, nedeniyle
    /// birlikte devre dışı gösterilir; sessizce başka basamağa düşülmez.
    public static func videoOptions(_ formats: [MediaFormat], av1: Bool = false) -> [QualityOption] {
        let videos = formats.filter(\.hasVideo)
        let audio = bestAudioOnly(formats, mp4Only: true)
        return tiers(videos).map { tier in
            let atTier = videos.filter { QualityTier(shortSide: $0.shortSide!) == tier }
            let passthrough = atTier.filter { $0.isPassthroughVideo(av1: av1) }
            if let muxed = best(passthrough.filter(\.hasAudio)) ?? best(atTier.filter(\.hasAudio)) {
                if let audio, let video = best(passthrough.filter { !$0.hasAudio }), rank(video) > rank(muxed) {
                    return QualityOption(tier: tier, plan: mergePlan(video, audio, tier))
                }
                return QualityOption(tier: tier, plan: DownloadPlan(kind: .single(muxed), tier: tier, outputExtension: muxed.ext, estimatedBytes: muxed.size))
            }
            guard hasAudio(formats) else {
                // Kaynakta hiç ses yok: görüntü olduğu gibi (sessiz) indirilir.
                let video = best(atTier)!
                return QualityOption(tier: tier, plan: DownloadPlan(kind: .single(video), tier: tier, outputExtension: video.ext, estimatedBytes: video.size))
            }
            guard formats.contains(where: { !$0.hasVideo && $0.hasAudio }) else {
                return QualityOption(tier: tier, plan: nil, reason: "Bu kalite sesli sunulmuyor")
            }
            guard let video = best(passthrough) else {
                return QualityOption(tier: tier, plan: nil, reason: "Bu kalite yalnız MP4 dışı biçimde sunuluyor")
            }
            guard let audio else { return QualityOption(tier: tier, plan: nil, reason: "Uyumlu ses akışı yok") }
            return QualityOption(tier: tier, plan: mergePlan(video, audio, tier))
        }
    }

    /// Yalnız görüntü (sessiz): o basamakta ayrı görüntü akışı varsa yalnız o indirilir (daha az veri); yoksa birleşik
    /// akış indirilip görüntü izi yeniden kodlamadan ayrılır. Kaynakta hiç ses yoksa görüntü olduğu gibi indirilir.
    public static func videoOnlyOptions(_ formats: [MediaFormat], av1: Bool = false) -> [QualityOption] {
        let videos = formats.filter(\.hasVideo)
        let silentSource = !hasAudio(formats)
        return tiers(videos).map { tier in
            let atTier = videos.filter { QualityTier(shortSide: $0.shortSide!) == tier }
            if silentSource, let video = best(atTier) {
                return QualityOption(tier: tier, plan: DownloadPlan(kind: .single(video), tier: tier, outputExtension: video.ext, estimatedBytes: video.size))
            }
            let passthrough = atTier.filter { $0.isPassthroughVideo(av1: av1) }
            if let video = best(passthrough.filter { !$0.hasAudio }) {
                return QualityOption(tier: tier, plan: DownloadPlan(kind: .single(video), tier: tier, outputExtension: video.ext, estimatedBytes: video.size))
            }
            if let muxed = best(passthrough) {
                return QualityOption(tier: tier, plan: DownloadPlan(kind: .extractVideo(from: muxed), tier: tier, outputExtension: "mp4", estimatedBytes: muxed.size))
            }
            return QualityOption(tier: tier, plan: nil, reason: "Bu kalite yalnız MP4 dışı biçimde sunuluyor")
        }
    }

    static func tiers(_ videos: [MediaFormat]) -> [QualityTier] {
        Set(videos.compactMap { $0.shortSide.map(QualityTier.init(shortSide:)) }).sorted(by: >)
    }

    /// Yalnız ses: ayrı ses akışı varsa yalnız o indirilir (kaynağın biçimi korunur); yoksa birleşik akıştan ses izi
    /// ayrılır. Kaynakta ses yoksa nil.
    public static func audioPlan(_ formats: [MediaFormat], av1: Bool = false) -> DownloadPlan? {
        if let audio = bestAudioOnly(formats, mp4Only: false) {
            return DownloadPlan(kind: .single(audio), tier: nil, outputExtension: audio.ext, estimatedBytes: audio.size)
        }
        let muxed = formats.filter { $0.hasVideo && $0.hasAudio && $0.isPassthroughVideo(av1: av1) }
        guard let source = muxed.min(by: { rank($0) < rank($1) }) else { return nil }
        return DownloadPlan(kind: .extractAudio(from: source), tier: nil, outputExtension: "m4a", estimatedBytes: source.size)
    }

    public static func hasAudio(_ formats: [MediaFormat]) -> Bool { formats.contains(where: \.hasAudio) }

    static func mergePlan(_ video: MediaFormat, _ audio: MediaFormat, _ tier: QualityTier) -> DownloadPlan {
        let bytes = video.size.flatMap { v in audio.size.map { v + $0 } }
        return DownloadPlan(kind: .merge(video: video, audio: audio), tier: tier, outputExtension: "mp4", estimatedBytes: bytes)
    }

    static func bestAudioOnly(_ formats: [MediaFormat], mp4Only: Bool) -> MediaFormat? {
        let audio = formats.filter { !$0.hasVideo && $0.hasAudio }
        let preferred = audio.filter(\.isMP4Audio)
        return best(preferred) ?? (mp4Only ? nil : best(audio))
    }

    static func best(_ formats: [MediaFormat]) -> MediaFormat? { formats.max { rank($0) < rank($1) } }
    static func rank(_ f: MediaFormat) -> Double { Double(f.shortSide ?? 0) * 1_000_000 + (f.tbr ?? 0) }
}

/// Motor çıktısındaki ilerleme satırı: `OIPROG <indirilen> <toplam|NA> <tahmini|NA>`.
public enum DownloadProgressParser {
    public static func fraction(_ line: Substring) -> Double? {
        let parts = line.split(separator: " ")
        guard parts.count == 4, parts[0] == "OIPROG", let done = Double(parts[1]) else { return nil }
        guard let total = Double(parts[2]) ?? Double(parts[3]), total > 0 else { return nil }
        return min(max(done / total, 0), 1)
    }

    /// İlerleme yayını birleştirilir: en az yüzde bir değişim ya da 0,25 sn; tamamlanma her zaman yayınlanır.
    public static func shouldPublish(_ value: Double, last: Double?, elapsedSinceLast: TimeInterval) -> Bool {
        guard let last else { return true }
        if value >= 1 { return last < 1 }
        return value - last >= 0.01 || (value != last && elapsedSinceLast >= 0.25)
    }
}

public enum DownloadFileNaming {
    /// Başlıktan güvenli dosya adı: yol ayırıcı, denetim karakteri ve baştaki nokta kalkar; en çok 120 karakter.
    public static func baseName(title: String?, fallback: String = "İndirilen video") -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters).union(.newlines)
        var name = String(String.UnicodeScalarView((title ?? "").unicodeScalars.map { forbidden.contains($0) ? " " : $0 }))
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(120)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? fallback : name
    }

    /// Var olan dosyayı ezmeden ilk boş ad: "Ad.mp4", "Ad (2).mp4", … Uzantı motorun bildirdiği gerçek biçimdir.
    public static func uniqueName(base: String, ext: String, exists: (String) -> Bool) -> String? {
        let suffix = ext.isEmpty ? "" : "." + ext
        if !exists(base + suffix) { return base + suffix }
        for n in 2...999 where !exists("\(base) (\(n))\(suffix)") { return "\(base) (\(n))\(suffix)" }
        return nil
    }
}

public enum DownloadFailure: Error, Equatable, Sendable {
    case loginRequired, unavailableInRegion, removed, unsupported, network, timedOut, formatGone
    case diskFull, writePermission, engineMissing, mergeFailed, other
    case live, botCheck, engineInvalid

    public var message: String {
        switch self {
        case .live: "Canlı veya başlamamış yayın indirilemez."
        case .botCheck: "YouTube bu bağlantı için doğrulama istiyor; biraz sonra yeniden deneyin."
        case .engineInvalid: "YouTube motoru doğrulanamadı; yeniden indirin."
        case .loginRequired: "Bu içerik giriş gerektiriyor veya gizli; indirilemez."
        case .unavailableInRegion: "İçerik bu bölgede erişilebilir değil."
        case .removed: "İçerik kaldırılmış veya bulunamadı."
        case .unsupported: "Bu bağlantı desteklenmiyor ya da video içermiyor."
        case .network: "Ağ hatası. Bağlantınızı denetleyip yeniden deneyin."
        case .timedOut: "Yanıt alınamadı (zaman aşımı)."
        case .formatGone: "Seçilen kalite artık sunulmuyor; bağlantıyı yeniden inceleyin."
        case .diskFull: "Diskte yeterli alan yok."
        case .writePermission: "Seçilen klasöre yazılamıyor."
        case .engineMissing: "YouTube motoru kurulu değil."
        case .mergeFailed: "Görüntü ve ses birleştirilemedi."
        case .other: "İndirme başarısız oldu. Platform değişmiş olabilir."
        }
    }

    /// Motorun hata çıktısından sınıf. Metin kullanıcıya veya günlüğe aynen aktarılmaz (bağlantı içerebilir).
    public static func classify(_ stderr: String) -> DownloadFailure {
        let text = stderr.lowercased()
        func any(_ needles: [String]) -> Bool { needles.contains { text.contains($0) } }
        // Süresi dolmuş (YouTube ~6 sa) veya geri çekilmiş akış adresi: başka kaliteye sessizce geçilmez, yeniden incelenir.
        if any(["requested format is not available", "requested format not available", "http error 403"]) { return .formatGone }
        if any(["no space left"]) { return .diskFull }
        if any(["permission denied", "operation not permitted", "read-only file system"]) { return .writePermission }
        if any(["not a bot", "confirm you're not", "confirm you’re not"]) { return .botCheck }
        if any(["live event will begin", "is live", "premieres in", "this live event"]) { return .live }
        if any(["login", "log in", "cookies", "private", "sign in", "authentication", "age-restricted", "age restricted"]) { return .loginRequired }
        if any(["available in your country", "geo restrict", "geo-restrict", "your region", "your location"]) { return .unavailableInRegion }
        if any(["unsupported url", "no video formats", "no video could be found", "there's no video", "not a video"]) { return .unsupported }
        if any(["removed", "deleted", "does not exist", "no longer available", "http error 404", "content isn't available", "video unavailable"]) { return .removed }
        if any(["timed out", "timeout"]) { return .timedOut }
        if any(["network is unreachable", "connection", "name or service not known", "nodename nor servname", "temporary failure in name resolution", "ssl"]) { return .network }
        return .other
    }
}

/// İşlem yaşam döngüsü. Her inceleme/indirme yeni bir kuşak alır; eski kuşağın geç gelen sonucu yok sayılır.
/// `needsEngine`: YouTube bağlantısı için motorun indirilmesine onay bekleniyor; `installingEngine`: motor indirilip
/// doğrulanıyor (ilk kurulum ya da kullanıcının başlattığı güncelleme).
public enum LinkDownloadPhase: Equatable, Sendable {
    case idle, inspecting, ready, downloading, finalizing, finished, cancelled, failed, needsEngine, installingEngine

    public var isBusy: Bool { [.inspecting, .downloading, .finalizing, .installingEngine].contains(self) }
}

public struct DownloadGeneration: Equatable, Sendable {
    public private(set) var value: UInt64 = 0
    public init() {}
    public mutating func next() -> UInt64 { value &+= 1; return value }
    public func accepts(_ generation: UInt64) -> Bool { generation == value }
}
