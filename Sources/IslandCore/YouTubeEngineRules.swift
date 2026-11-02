import Foundation

/// YouTube indirmesinin saf kuralları: motorun bildirdiği biçimlerden kullanılabilenler, YouTube DASH dosyalarının
/// gerçek süresi, isteğe bağlı motor paketinin sabitlenmiş sürümleri, sürüm bilgisinin doğrulanması ve evrensel
/// (fat) Mach-O dosyasından tek mimari dilimi. Ağ, süreç veya dosya sistemi içermez.
public enum YouTubeFormats {
    /// Doğrudan `https` akışlar (HLS/DASH parça listesi, film şeridi yok), DRM'siz, "-drc" (dinamik aralık sıkıştırmalı)
    /// kopyası olmayan, en çok iki kanallı ses. Birden çok dil varsa yalnız en yüksek öncelikli (özgün) ses izi kalır.
    public static func usable(_ formats: [MediaFormat]) -> [MediaFormat] {
        let direct = formats.filter {
            $0.protocolName == "https" && $0.hasDRM != true && !$0.id.lowercased().hasSuffix("-drc") && ($0.hasVideo || $0.hasAudio)
        }
        let audio = direct.filter { !$0.hasVideo && $0.hasAudio }
        let topLanguage = audio.compactMap(\.languagePreference).max()
        return direct.filter { f in
            guard !f.hasVideo else { return true }
            if let channels = f.audioChannels, channels > 2 { return false }
            guard let topLanguage else { return true }
            return (f.languagePreference ?? topLanguage) == topLanguage
        }
    }
}

/// Parçalı (fragmented) MP4'ün başlıkta bildirdiği süre. YouTube DASH dosyaları `mvhd` süresini tam video olarak yazar
/// ve AVFoundation parçaları bunun üstüne ekleyip süreyi iki katı okur (ikinci yarı boştur). Yalnız `moov` içinde
/// `mvex` (parçalı dosya) varsa ve süre sıfırdan büyükse değer döner; sıradan MP4'te nil.
public enum FragmentedMP4 {
    public static func declaredDuration(_ header: Data) -> Double? {
        let bytes = [UInt8](header)
        var offset = 0
        while let box = box(bytes, at: offset, end: bytes.count) {
            if box.type == "moov" { return moovDuration(bytes, start: box.body, end: box.end) }
            if box.type == "moof" || box.type == "mdat" { return nil }
            offset = box.end
        }
        return nil
    }

    private static func moovDuration(_ b: [UInt8], start: Int, end: Int) -> Double? {
        var offset = start, duration: Double?, fragmented = false
        while let box = box(b, at: offset, end: end) {
            if box.type == "mvex" { fragmented = true }
            if box.type == "mvhd", box.body + 4 <= box.end {
                let version = b[box.body]
                if version == 1, box.body + 32 <= box.end {
                    let scale = UInt64(be32(b, box.body + 20)), length = be64(b, box.body + 24)
                    if scale > 0, length > 0 { duration = Double(length) / Double(scale) }
                } else if version == 0, box.body + 20 <= box.end {
                    let scale = UInt64(be32(b, box.body + 12)), length = UInt64(be32(b, box.body + 16))
                    if scale > 0, length > 0 { duration = Double(length) / Double(scale) }
                }
            }
            offset = box.end
        }
        return fragmented ? duration : nil
    }

    private static func box(_ b: [UInt8], at offset: Int, end: Int) -> (type: String, body: Int, end: Int)? {
        guard offset + 8 <= end else { return nil }
        var size = UInt64(be32(b, offset)), header = 8
        if size == 1 {
            guard offset + 16 <= end else { return nil }
            size = be64(b, offset + 8); header = 16
        } else if size == 0 {
            size = UInt64(end - offset)
        }
        guard size >= UInt64(header), let type = String(bytes: b[(offset + 4)..<(offset + 8)], encoding: .ascii) else { return nil }
        // Başlık okuması dosyanın tamamı değildir: sınırı aşan kutu yalnız `moov` aranırken atlanabilir değildir.
        let boxEnd = offset + Int(min(size, UInt64(Int.max - offset)))
        guard boxEnd <= end || type == "mdat" || type == "moof" else { return nil }
        return (type, offset + header, min(boxEnd, end))
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
    private static func be64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(be32(b, i)) << 32 | UInt64(be32(b, i + 4)) }
}

/// Evrensel Mach-O dosyasından yalnız bu Mac'in mimarisi. Dilimin kendi kod imzası dilimin içindedir; kesip almak
/// imzayı bozmaz (`lipo -thin` ile aynı çıktı). Evrensel olmayan dosyada nil.
public enum MachOFat {
    public static let arm64: Int32 = 0x0100_000C
    public static let x86_64: Int32 = 0x0100_0007

    public static func isFat(_ prefix: Data) -> Bool {
        guard prefix.count >= 8 else { return false }
        let b = [UInt8](prefix.prefix(8))
        let magic = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        let count = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        // Java sınıf dosyaları da 0xCAFEBABE ile başlar; onlarda bu alan sürüm numarasıdır (≥ 45).
        return (magic == 0xCAFE_BABE || magic == 0xCAFE_BABF) && count > 0 && count < 16
    }

    public static func slice(_ data: Data, cpuType: Int32) -> Data? {
        guard isFat(data) else { return nil }
        let b = [UInt8](data)
        func u32(_ i: Int) -> UInt64 { UInt64(b[i]) << 24 | UInt64(b[i + 1]) << 16 | UInt64(b[i + 2]) << 8 | UInt64(b[i + 3]) }
        let wide = u32(0) == 0xCAFE_BABF
        let count = Int(u32(4)), entry = wide ? 32 : 20
        guard 8 + count * entry <= b.count else { return nil }
        for i in 0..<count {
            let base = 8 + i * entry
            guard Int32(bitPattern: UInt32(u32(base))) == cpuType else { continue }
            let offset = wide ? (u32(base + 8) << 32 | u32(base + 12)) : u32(base + 8)
            let size = wide ? (u32(base + 16) << 32 | u32(base + 20)) : u32(base + 12)
            guard size > 0, offset <= UInt64(b.count), size <= UInt64(b.count) - offset else { return nil }
            return data.subdata(in: (data.startIndex + Int(offset))..<(data.startIndex + Int(offset + size)))
        }
        return nil
    }
}

/// İsteğe bağlı YouTube motorunun bir parçası: indirilecek dosya ve beklenen SHA-256 özeti.
public struct EngineComponent: Codable, Equatable, Sendable {
    public var version: String
    public var url: URL
    public var sha256: String
    public var size: Int64

    public init(version: String, url: URL, sha256: String, size: Int64) {
        (self.version, self.url, self.sha256, self.size) = (version, url, sha256, size)
    }
}

public enum YouTubeEnginePin {
    /// İlk kurulum: denenmiş sürümler ve GitHub sürüm sayfalarındaki özetler (2 Kasım 2026). Klasör (onedir) yt-dlp her
    /// açılışta kendini açmaz: tek dosyalı sürüm her çalıştırmada ~7 sn ve ~0,8 sn CPU harcıyordu, bu 0,2 sn'de başlar.
    public static let downloader = EngineComponent(
        version: "2026.10.26",
        url: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/yt-dlp_macos.zip")!,
        sha256: "20d98fa608998eff87d1d35a6e9fb65e4b874639a6cc89addc19da3becde3ef1", size: 54_165_284)
    public static let quickJS = EngineComponent(
        version: "v0.18.0",
        url: URL(string: "https://github.com/quickjs-ng/quickjs/releases/download/v0.18.0/qjs-darwin-arm64")!,
        sha256: "91fe89916d3b0a6c01c4dc8382a99c3c1fd91ecfc214aa81ca051902bcce590d", size: 1_360_336)

    public static let downloaderAsset = "yt-dlp_macos.zip"
    public static let quickJSAsset = "qjs-darwin-arm64"
    public static let downloaderRelease = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
    public static let quickJSRelease = URL(string: "https://api.github.com/repos/quickjs-ng/quickjs/releases/latest")!
}

/// GitHub "latest release" yanıtından tek bir dosya: yalnız `https://github.com/<sahip>/<depo>/releases/download/…`
/// adresi ve GitHub'ın bildirdiği `sha256:` özeti kabul edilir. Özet yoksa güncelleme yapılmaz.
public enum EngineRelease {
    public static func component(fromLatest json: Data, asset name: String, repository: String) -> EngineComponent? {
        struct Release: Decodable {
            struct Asset: Decodable { var name: String; var browser_download_url: URL; var digest: String?; var size: Int64 }
            var tag_name: String; var assets: [Asset]; var draft: Bool?; var prerelease: Bool?
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: json), release.draft != true, release.prerelease != true,
              let asset = release.assets.first(where: { $0.name == name }), let digest = asset.digest, digest.hasPrefix("sha256:") else { return nil }
        let hex = String(digest.dropFirst(7)).lowercased()
        let url = asset.browser_download_url
        guard isSHA256(hex), url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/" + repository + "/releases/download/"), url.lastPathComponent == name,
              asset.size > 0, asset.size < 512 << 20 else { return nil }
        return EngineComponent(version: release.tag_name, url: url, sha256: hex, size: asset.size)
    }

    public static func isSHA256(_ hex: String) -> Bool {
        hex.count == 64 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// Kurulu motorun kaydı (motor klasöründe `manifest.json`).
public struct YouTubeEngineManifest: Codable, Equatable, Sendable {
    public var downloader: EngineComponent
    public var quickJS: EngineComponent
    public var installedAt: Date

    public init(downloader: EngineComponent, quickJS: EngineComponent, installedAt: Date) {
        (self.downloader, self.quickJS, self.installedAt) = (downloader, quickJS, installedAt)
    }
}
