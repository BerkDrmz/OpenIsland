import Foundation

/// Uygulama içi çıkarıcıların saf kısmı: bağlantıdan kimlik, istek adresi ve platform yanıtından (JSON/HTML) doğrudan
/// medya adresleri. Ağ yoktur; istekleri uygulama katmanı yapar. Mantık yt-dlp'nin (Unlicense) X, TikTok ve Facebook
/// çıkarıcılarından uyarlanmıştır; yalnız herkese açık, girişsiz içerik hedeflenir.
public struct DirectSource: Equatable, Sendable {
    public var format: MediaFormat
    public var url: URL
    public init(format: MediaFormat, url: URL) { self.format = format; self.url = url }
}

public struct ExtractedMedia: Equatable, Sendable {
    public var title: String?
    public var sources: [DirectSource]
    public init(title: String?, sources: [DirectSource]) { self.title = title; self.sources = sources }
    public var formats: [MediaFormat] { sources.map(\.format) }
}

public enum XExtractor {
    /// `…/<kullanıcı>/status/<id>`, `…/i/web/status/<id>`, `…/statuses/<id>`.
    public static func statusID(_ url: URL) -> String? {
        let parts = url.pathComponents
        for (i, p) in parts.enumerated() where (p == "status" || p == "statuses") && i + 1 < parts.count {
            let id = parts[i + 1]
            if !id.isEmpty, id.count <= 20, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) { return id }
        }
        return nil
    }

    /// Herkese açık gömme API'si (`cdn.syndication.twimg.com/tweet-result`): giriş ve konuk anahtarı gerektirmez.
    public static func syndicationURL(id: String) -> URL? {
        var c = URLComponents(string: "https://cdn.syndication.twimg.com/tweet-result")!
        c.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "lang", value: "en"),
                        URLQueryItem(name: "token", value: token(id))]
        return c.url
    }

    /// JS: `((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, '')`.
    public static func token(_ id: String) -> String {
        guard let n = Double(id) else { return "" }
        return JSNumber.string((n / 1e15) * Double.pi, radix: 36).filter { $0 != "0" && $0 != "." }
    }

    public static func parse(_ data: Data, id: String) -> Result<ExtractedMedia, DownloadFailure> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.other) }
        if root["__typename"] as? String == "TweetTombstone" {
            let text = (((root["tombstone"] as? [String: Any])?["text"] as? [String: Any])?["text"] as? String ?? "").lowercased()
            return .failure(text.contains("age") || text.contains("log in") ? .loginRequired : .removed)
        }
        var sources: [DirectSource] = []
        let media = (root["mediaDetails"] as? [[String: Any]]) ?? []
        for item in media {
            let type = item["type"] as? String
            guard type == "video" || type == "animated_gif",
                  let variants = (item["video_info"] as? [String: Any])?["variants"] as? [[String: Any]] else { continue }
            for v in variants {
                guard let s = v["url"] as? String, let url = URL(string: s), url.scheme == "https",
                      !s.contains(".m3u8"), (v["content_type"] as? String).map({ $0 == "video/mp4" }) ?? true else { continue }
                // Video varyant adresinde boyut vardır; GIF adresinde yoksa gönderinin özgün boyutu kullanılır.
                let original = item["original_info"] as? [String: Any]
                let size = Self.size(in: url.path) ?? jsonInt(original?["width"]).flatMap { w in jsonInt(original?["height"]).map { (w, $0) } }
                let kbps = (v["bitrate"] as? Int).map { $0 / 1000 }
                let id = "http-\(kbps ?? sources.count)"
                guard !sources.contains(where: { $0.format.id == id }) else { continue }
                // Hareketli GIF'ler sessizdir; video varyantları sesli MP4'tür.
                let format = MediaFormat(id: id, ext: "mp4", vcodec: "avc1", acodec: type == "animated_gif" ? "none" : "mp4a.40.2",
                                         width: size?.0, height: size?.1, tbr: kbps.map(Double.init))
                sources.append(DirectSource(format: format, url: url))
            }
        }
        guard !sources.isEmpty else { return .failure(media.isEmpty && root["text"] == nil ? .removed : .unsupported) }
        return .success(ExtractedMedia(title: title(from: root["text"] as? String, fallback: "X video \(id)"), sources: sources))
    }

    static func size(in path: String) -> (Int, Int)? {
        for part in path.split(separator: "/") {
            let wh = part.split(separator: "x")
            if wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]), w > 0, h > 0 { return (w, h) }
        }
        return nil
    }

    /// Gönderi metni (sondaki t.co bağlantısı atılır, en çok 100 karakter).
    static func title(from text: String?, fallback: String) -> String {
        let words = (text ?? "").split(whereSeparator: \.isWhitespace).filter { !$0.hasPrefix("https://t.co/") }
        let t = words.joined(separator: " ")
        return t.isEmpty ? fallback : String(t.prefix(100))
    }
}

public enum TikTokExtractor {
    /// `/@kullanıcı/video/<id>`, `/share/video/<id>`, `/embed/v2/<id>`; kısa bağlantılar (vm., vt., /t/) önce yönlendirilir.
    public static func videoID(_ url: URL) -> String? {
        let parts = url.pathComponents
        for (i, p) in parts.enumerated() where (p == "video" || p == "v2") && i + 1 < parts.count {
            let id = parts[i + 1]
            if !id.isEmpty, id.count <= 24, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) { return id }
        }
        return nil
    }

    public static func isShortLink(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.hasPrefix("vm.") || host.hasPrefix("vt.") || url.pathComponents.dropFirst().first == "t"
    }

    public static func pageURL(id: String) -> URL { URL(string: "https://www.tiktok.com/@_/video/\(id)")! }

    public static func parse(html: String) -> Result<ExtractedMedia, DownloadFailure> {
        guard let json = scriptJSON(html, id: "__UNIVERSAL_DATA_FOR_REHYDRATION__"),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let detail = (root["__DEFAULT_SCOPE__"] as? [String: Any])?["webapp.video-detail"] as? [String: Any] else {
            // Doğrulama sayfası (proof-of-work) veya yapı değişikliği: sessizce başka yola düşülmez.
            return .failure(.other)
        }
        let status = (detail["statusCode"] as? Int) ?? 0
        switch status {
        case 0: break
        case 10216, 10222: return .failure(.loginRequired)
        case 10204: return .failure(.unavailableInRegion)
        default: return .failure(.removed)
        }
        guard let item = (detail["itemInfo"] as? [String: Any])?["itemStruct"] as? [String: Any] else { return .failure(.removed) }
        guard let video = item["video"] as? [String: Any] else {
            return .failure(item["isContentClassified"] as? Bool == true ? .loginRequired : .unsupported)
        }
        let vw = jsonInt(video["width"]), vh = jsonInt(video["height"])
        var sources: [DirectSource] = []
        for info in (video["bitrateInfo"] as? [[String: Any]]) ?? [] {
            guard let play = info["PlayAddr"] as? [String: Any],
                  let first = (play["UrlList"] as? [String])?.first(where: { URL(string: $0)?.host != "www.tiktok.com" }),
                  let url = URL(string: first), url.scheme == "https" else { continue }
            let key = parseKey(play["UrlKey"] as? String)
            let codec = key?.codec ?? ((info["CodecType"] as? String) ?? "h264")
            guard codec != "bytevc2" else { continue } // oynatılamaz
            var w = jsonInt(play["Width"]), h = jsonInt(play["Height"])
            if w == nil || h == nil, let res = key?.res, let vw, let vh, vw > 0, vh > 0 {
                let short = res == 540 ? 576 : res
                (w, h) = vw <= vh ? (short, even(Double(short) * Double(vh) / Double(vw))) : (even(Double(short) * Double(vw) / Double(vh)), short)
            }
            let id = key?.id ?? "bitrate-\(sources.count)"
            guard !sources.contains(where: { $0.format.id == id }) else { continue }
            let format = MediaFormat(id: id, ext: "mp4", vcodec: ["bytevc1", "h265", "hevc"].contains(codec) ? "hvc1" : "avc1",
                                     acodec: "aac", width: w, height: h, filesize: jsonInt64(play["DataSize"]),
                                     tbr: (key?.kbps).map(Double.init) ?? jsonInt(info["Bitrate"]).map { Double($0) / 1000 })
            sources.append(DirectSource(format: format, url: url))
        }
        if sources.isEmpty, let s = video["playAddr"] as? String, let url = URL(string: s), url.scheme == "https", url.host != "www.tiktok.com" {
            sources.append(DirectSource(format: MediaFormat(id: "play", ext: "mp4", vcodec: "avc1", acodec: "aac", width: vw, height: vh), url: url))
        }
        guard !sources.isEmpty else { return .failure(.unsupported) }
        let desc = item["desc"] as? String
        return .success(ExtractedMedia(title: XExtractor.title(from: desc, fallback: "TikTok video \(item["id"] as? String ?? "")"), sources: sources))
    }

    static func parseKey(_ key: String?) -> (id: String, codec: String, res: Int, kbps: Int)? {
        // v[^_]+_(codec)_(res)p_(bitrate)
        guard let key else { return nil }
        let parts = key.split(separator: "_")
        guard parts.count >= 4, parts[0].hasPrefix("v"), let res = Int(parts[parts.count - 2].dropLast()),
              parts[parts.count - 2].hasSuffix("p"), let kbps = Int(parts[parts.count - 1]) else { return nil }
        let codec = parts[1..<(parts.count - 2)].joined(separator: "_")
        return ("\(codec)_\(res)p_\(kbps)", codec, res, kbps)
    }

    static func even(_ v: Double) -> Int { Int((v / 2).rounded()) * 2 }
}

public enum FacebookExtractor {
    /// Mobil/temel alt alan adları masaüstü sayfasına çevrilir; fb.watch ve paylaşım bağlantıları yönlendirmeyle çözülür.
    public static func pageURL(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host?.lowercased() else { return url }
        if host.hasSuffix("facebook.com") { c.host = "www.facebook.com" }
        c.scheme = "https"
        return c.url ?? url
    }

    public static func parse(html: String) -> Result<ExtractedMedia, DownloadFailure> {
        var sources: [DirectSource] = []
        for (key, label) in [("browser_native_hd_url", "hd"), ("playable_url_quality_hd", "hd"),
                             ("browser_native_sd_url", "sd"), ("playable_url", "sd")] {
            for raw in jsonStrings(html, key: key) {
                guard let url = URL(string: raw), url.scheme == "https", !url.path.hasSuffix(".mpd"),
                      !sources.contains(where: { $0.url == url }), !sources.contains(where: { $0.format.id == label }) else { continue }
                // Boyut sayfada güvenilir değil; uygulama katmanı dosyanın kendisinden okur.
                sources.append(DirectSource(format: MediaFormat(id: label, ext: "mp4", vcodec: "avc1", acodec: "mp4a.40.2"), url: url))
            }
        }
        if sources.isEmpty {
            if html.contains(">You must log in to continue") || html.contains("id=\"login_form\"") || html.contains("id=\"loginbutton\"") {
                return .failure(.loginRequired)
            }
            return .failure(html.contains("uiInterstitialContent") ? .removed : .unsupported)
        }
        var title = meta(html, property: "og:title") ?? "Facebook video"
        if title.hasSuffix(" | Facebook") { title.removeLast(" | Facebook".count) }
        return .success(ExtractedMedia(title: XExtractor.title(from: title, fallback: "Facebook video"), sources: sources))
    }

    /// `"anahtar":"…"` biçimindeki JSON dizelerinin çözülmüş değerleri.
    static func jsonStrings(_ html: String, key: String) -> [String] {
        var out: [String] = []
        var rest = html[...]
        let needle = "\"\(key)\":\""
        while let r = rest.range(of: needle) {
            var i = r.upperBound, escaped = false
            while i < rest.endIndex {
                let ch = rest[i]
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { break }
                i = rest.index(after: i)
            }
            guard i < rest.endIndex else { break }
            let literal = "\"" + rest[r.upperBound..<i] + "\""
            if let value = try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed) as? String { out.append(value) }
            rest = rest[i...]
        }
        return out
    }

    static func meta(_ html: String, property: String) -> String? {
        guard let r = html.range(of: "property=\"\(property)\" content=\"") else { return nil }
        guard let end = html[r.upperBound...].firstIndex(of: "\"") else { return nil }
        return decodeEntities(String(html[r.upperBound..<end]))
    }

    static func decodeEntities(_ s: String) -> String {
        var t = s
        for (e, c) in [("&quot;", "\""), ("&#039;", "'"), ("&#x27;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] { t = t.replacingOccurrences(of: e, with: c) }
        return t
    }
}

/// `<script … id="ID" …>…</script>` içeriği.
func scriptJSON(_ html: String, id: String) -> String? {
    guard let idRange = html.range(of: "id=\"\(id)\"") else { return nil }
    guard let open = html[..<idRange.lowerBound].range(of: "<script", options: .backwards),
          let start = html[open.upperBound...].firstIndex(of: ">") else { return nil }
    guard let end = html[html.index(after: start)...].range(of: "</script>") else { return nil }
    return String(html[html.index(after: start)..<end.lowerBound])
}

func jsonInt(_ v: Any?) -> Int? { (v as? Int) ?? (v as? String).flatMap { Int($0) } ?? (v as? Double).map { Int($0) } }
func jsonInt64(_ v: Any?) -> Int64? { (v as? Int64) ?? (v as? Int).map(Int64.init) ?? (v as? String).flatMap { Int64($0) } }

/// JavaScript `Number.prototype.toString(radix)` (V8 `DoubleToRadixCString`): en kısa, geri dönüşümlü kesir.
enum JSNumber {
    static func string(_ value: Double, radix: Int) -> String {
        let chars = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var integer = value.rounded(.down)
        var fraction = value - integer
        var delta = max(0.5 * (value.nextUp - value), Double.leastNonzeroMagnitude)
        var digits: [Character] = []
        if fraction >= delta {
            repeat {
                fraction *= Double(radix)
                delta *= Double(radix)
                let digit = Int(fraction)
                digits.append(chars[digit])
                fraction -= Double(digit)
                if fraction > 0.5 || (fraction == 0.5 && digit & 1 == 1), fraction + delta > 1 {
                    // Yukarı yuvarla (taşma kesirden tam kısma geçebilir).
                    while true {
                        guard let last = digits.popLast() else { integer += 1; break }
                        let d = chars.firstIndex(of: last)!
                        if d + 1 < radix { digits.append(chars[d + 1]); break }
                    }
                    break
                }
            } while fraction >= delta
        }
        var intDigits: [Character] = []
        var n = integer
        repeat {
            let r = n.truncatingRemainder(dividingBy: Double(radix))
            intDigits.insert(chars[Int(r)], at: 0)
            n = (n - r) / Double(radix)
        } while n >= 1
        return String(intDigits) + (digits.isEmpty ? "" : "." + String(digits))
    }
}
