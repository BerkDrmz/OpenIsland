import Foundation
import Testing
@testable import IslandCore

@Suite("YouTube: biçim süzgeci, DASH süresi, motor paketi")
struct YouTubeEngineRulesTests {
    private func f(_ id: String, ext: String = "mp4", v: String? = "none", a: String? = "none", w: Int? = nil, h: Int? = nil,
                   proto: String? = "https", lang: Int? = -1, channels: Int? = nil, drm: Bool? = false, tbr: Double = 100) -> MediaFormat {
        MediaFormat(id: id, ext: ext, vcodec: v, acodec: a, width: w, height: h, tbr: tbr, protocolName: proto,
                    languagePreference: lang, audioChannels: channels, hasDRM: drm)
    }

    @Test func keepsDirectDRMFreeStereoOriginalStreams() {
        let formats = [
            f("140", ext: "m4a", a: "mp4a.40.2", channels: 2), f("140-drc", ext: "m4a", a: "mp4a.40.2", channels: 2),
            f("258", ext: "m4a", a: "mp4a.40.2", channels: 6, tbr: 384), f("299", v: "avc1.64002A", w: 1920, h: 1080),
            f("hls", v: "avc1", a: "mp4a.40.2", w: 1280, h: 720, proto: "m3u8_native"), f("sb0", ext: "mhtml", w: 160, h: 90, proto: "mhtml"),
            f("drm", v: "avc1", w: 1280, h: 720, drm: true),
        ]
        #expect(YouTubeFormats.usable(formats).map(\.id) == ["140", "299"])
    }

    @Test func multipleLanguagesKeepOnlyTheOriginalAudio() {
        let formats = [f("140-0", ext: "m4a", a: "mp4a.40.2", lang: 10, channels: 2), f("140-1", ext: "m4a", a: "mp4a.40.2", lang: -1, channels: 2),
                       f("299", v: "avc1", w: 1920, h: 1080, lang: nil)]
        #expect(YouTubeFormats.usable(formats).map(\.id) == ["140-0", "299"])
    }

    @Test func decodesEngineFieldsAndLiveStatus() throws {
        let json = #"{"title":"t","duration":634.6,"live_status":"is_live","formats":[{"format_id":"140","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","protocol":"https","language_preference":-1,"audio_channels":2,"has_drm":false},{"format_id":"x","ext":"mp4","has_drm":"maybe"}]}"#
        let info = try JSONDecoder().decode(MediaInfo.self, from: Data(json.utf8))
        #expect(info.isLive && info.formats.map(\.id) == ["140"]) // "maybe" DRM'li biçim düşer
        #expect(info.formats[0].protocolName == "https" && info.formats[0].audioChannels == 2 && info.formats[0].hasDRM == false)
        let past = try JSONDecoder().decode(MediaInfo.self, from: Data(#"{"live_status":"was_live","formats":[]}"#.utf8))
        #expect(!past.isLive)
    }

    // MARK: - Parçalı MP4

    private func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let size = UInt32(8 + body.count)
        return [UInt8(size >> 24), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)] + Array(type.utf8) + body
    }
    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    private func mvhd0(scale: UInt32, duration: UInt32) -> [UInt8] { box("mvhd", [0, 0, 0, 0] + be32(1) + be32(2) + be32(scale) + be32(duration) + [UInt8](repeating: 0, count: 80)) }

    @Test func readsTheDeclaredDurationOfAFragmentedFile() {
        // YouTube 140.m4a: mvhd 44100 / 27986944 = 634,6 sn, mvex var.
        let fragmented = box("ftyp", Array("dash".utf8) + be32(0)) + box("moov", mvhd0(scale: 44100, duration: 27_986_944) + box("mvex", box("trex", [UInt8](repeating: 0, count: 24))))
            + box("sidx", [UInt8](repeating: 0, count: 16)) + box("moof", [])
        let seconds = FragmentedMP4.declaredDuration(Data(fragmented))
        #expect(seconds != nil && abs(seconds! - 634.6) < 0.05)
        // Parçalı olmayan (mvex yok) dosyada süre düzeltmesi yapılmaz.
        let plain = box("ftyp", Array("isom".utf8) + be32(0)) + box("moov", mvhd0(scale: 1000, duration: 5000))
        #expect(FragmentedMP4.declaredDuration(Data(plain)) == nil)
        // 64 bit mvhd.
        let v1 = box("mvhd", [1, 0, 0, 0] + [UInt8](repeating: 0, count: 16) + be32(90000) + be32(0) + be32(900_000) + [UInt8](repeating: 0, count: 80))
        let wide = box("ftyp", Array("dash".utf8) + be32(0)) + box("moov", v1 + box("mvex", []))
        #expect(FragmentedMP4.declaredDuration(Data(wide)) == 10)
        #expect(FragmentedMP4.declaredDuration(Data([0, 0, 0, 1, 0x66])) == nil)
        #expect(FragmentedMP4.declaredDuration(Data()) == nil)
    }

    // MARK: - Evrensel Mach-O

    @Test func slicesOnlyTheRequestedArchitectureFromAFatFile() {
        let x86 = [UInt8](repeating: 0x11, count: 16), arm = [UInt8](repeating: 0x22, count: 24)
        var fat = be32(0xCAFE_BABE) + be32(2)
        fat += be32(UInt32(bitPattern: MachOFat.x86_64)) + be32(3) + be32(64) + be32(UInt32(x86.count)) + be32(4)
        fat += be32(UInt32(bitPattern: MachOFat.arm64)) + be32(0) + be32(96) + be32(UInt32(arm.count)) + be32(4)
        fat += [UInt8](repeating: 0, count: 64 - fat.count) + x86 + [UInt8](repeating: 0, count: 96 - 64 - x86.count) + arm
        let data = Data(fat)
        #expect(MachOFat.isFat(data))
        #expect(MachOFat.slice(data, cpuType: MachOFat.arm64) == Data(arm))
        #expect(MachOFat.slice(data, cpuType: MachOFat.x86_64) == Data(x86))
        #expect(MachOFat.slice(data, cpuType: 12) == nil)
        // Dilim dosyanın dışına taşıyorsa reddedilir.
        var broken = fat; broken.removeLast(4)
        #expect(MachOFat.slice(Data(broken), cpuType: MachOFat.arm64) == nil)
        // Java sınıf dosyası (0xCAFEBABE + sürüm 52) evrensel Mach-O sayılmaz; ince Mach-O da.
        #expect(!MachOFat.isFat(Data(be32(0xCAFE_BABE) + be32(52))))
        #expect(!MachOFat.isFat(Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0, 0, 1])))
    }

    // MARK: - Sürüm bilgisi

    private func release(name: String = "yt-dlp_macos.zip", url: String = "https://github.com/yt-dlp/yt-dlp/releases/download/2026.11.01/yt-dlp_macos.zip",
                         digest: String? = "sha256:" + String(repeating: "ab", count: 32), prerelease: Bool = false) -> Data {
        let d = digest.map { #","digest":"\#($0)""# } ?? ""
        return Data(#"{"tag_name":"2026.11.01","prerelease":\#(prerelease),"assets":[{"name":"\#(name)","browser_download_url":"\#(url)","size":54000000\#(d)}]}"#.utf8)
    }

    @Test func acceptsOnlyGitHubReleaseAssetsWithADigest() {
        let ok = EngineRelease.component(fromLatest: release(), asset: "yt-dlp_macos.zip", repository: "yt-dlp/yt-dlp")
        #expect(ok?.version == "2026.11.01" && ok?.sha256 == String(repeating: "ab", count: 32) && ok?.size == 54_000_000)
        #expect(EngineRelease.component(fromLatest: release(digest: nil), asset: "yt-dlp_macos.zip", repository: "yt-dlp/yt-dlp") == nil)
        #expect(EngineRelease.component(fromLatest: release(digest: "md5:abc"), asset: "yt-dlp_macos.zip", repository: "yt-dlp/yt-dlp") == nil)
        #expect(EngineRelease.component(fromLatest: release(prerelease: true), asset: "yt-dlp_macos.zip", repository: "yt-dlp/yt-dlp") == nil)
        #expect(EngineRelease.component(fromLatest: release(url: "https://evil.test/yt-dlp/yt-dlp/releases/download/x/yt-dlp_macos.zip"),
                                        asset: "yt-dlp_macos.zip", repository: "yt-dlp/yt-dlp") == nil)
        #expect(EngineRelease.component(fromLatest: release(url: "https://github.com/someone/fork/releases/download/x/yt-dlp_macos.zip"),
                                        asset: "yt-dlp_macos.zip", repository: "yt-dlp/yt-dlp") == nil)
        #expect(EngineRelease.component(fromLatest: release(), asset: "yt-dlp_linux", repository: "yt-dlp/yt-dlp") == nil)
        #expect(EngineRelease.component(fromLatest: Data("{}".utf8), asset: "yt-dlp_macos.zip", repository: "yt-dlp/yt-dlp") == nil)
    }

    @Test func pinnedComponentsAreWellFormed() throws {
        for c in [YouTubeEnginePin.downloader, YouTubeEnginePin.quickJS] {
            #expect(EngineRelease.isSHA256(c.sha256) && c.url.scheme == "https" && c.url.host == "github.com" && c.size > 0)
        }
        let manifest = YouTubeEngineManifest(downloader: YouTubeEnginePin.downloader, quickJS: YouTubeEnginePin.quickJS, installedAt: Date(timeIntervalSince1970: 1))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(YouTubeEngineManifest.self, from: encoder.encode(manifest)) == manifest)
    }
}
