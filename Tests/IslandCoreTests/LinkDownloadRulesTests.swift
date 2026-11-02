import Foundation
import Testing
@testable import IslandCore

@Suite("Bağlantıdan indir: saf kurallar")
struct LinkDownloadRulesTests {
    private func video(_ id: String, _ w: Int, _ h: Int, ext: String = "mp4", vcodec: String = "avc1.640028", acodec: String? = "none", tbr: Double = 1000, size: Int64? = nil) -> MediaFormat {
        MediaFormat(id: id, ext: ext, vcodec: vcodec, acodec: acodec, width: w, height: h, filesize: size, tbr: tbr)
    }
    private func audio(_ id: String, ext: String = "m4a", acodec: String = "mp4a.40.2", tbr: Double = 128, size: Int64? = nil) -> MediaFormat {
        MediaFormat(id: id, ext: ext, vcodec: "none", acodec: acodec, filesize: size, tbr: tbr)
    }

    @Test func acceptsOnlySupportedPlatformLinks() {
        let ok = ["https://www.facebook.com/watch/?v=1", "https://fb.watch/abc/", "https://m.facebook.com/reel/1",
                  "https://x.com/u/status/1", "https://twitter.com/u/status/1", "https://mobile.twitter.com/u/status/1",
                  "https://www.tiktok.com/@u/video/1", "https://vm.tiktok.com/ZM1/", " https://x.com/u/status/1\n",
                  "http://x.com/u/status/1", "https://x.com:443/u/status/1"]
        for text in ok {
            guard case .valid = LinkDownloadRules.validate(text) else { Issue.record("rejected \(text)"); continue }
        }
        if case .valid(_, let platform) = LinkDownloadRules.validate("https://vt.tiktok.com/x") { #expect(platform == .tiktok) }
        if case .valid(_, let platform) = LinkDownloadRules.validate("https://twitter.com/a/status/2") { #expect(platform == .x) }
        for text in ["https://www.youtube.com/watch?v=1", "https://youtu.be/abc", "https://m.youtube.com/shorts/abc",
                     "https://music.youtube.com/watch?v=1"] {
            guard case .valid(_, let platform) = LinkDownloadRules.validate(text) else { Issue.record("rejected \(text)"); continue }
            #expect(platform == .youtube && platform.needsEngine)
        }
        #expect(!LinkPlatform.x.needsEngine && !LinkPlatform.tiktok.needsEngine && !LinkPlatform.facebook.needsEngine)
        #expect(LinkDownloadRules.validate("https://youtube.com.evil.test/watch?v=1") == .unsupportedPlatform)
        #expect(LinkDownloadRules.validate("https://notyoutube.com/watch?v=1") == .unsupportedPlatform)
        #expect(LinkDownloadRules.validate("https://notx.com/u/status/1") == .unsupportedPlatform)
        #expect(LinkDownloadRules.validate("https://x.com.evil.test/u") == .unsupportedPlatform)
        #expect(LinkDownloadRules.validate("https://evilfacebook.com/v") == .unsupportedPlatform)
    }

    @Test func rejectsLocalFilesOtherProtocolsAndInjection() {
        for text in ["", "x.com/u/status/1", "file:///etc/passwd", "ftp://x.com/a", "javascript:alert(1)",
                     "https://u:p@x.com/a", "https://x.com:8080/a", "-o /tmp/x https://x.com/a", "--exec=rm https://x.com/a",
                     "https://x.com/a b", "https://localhost/a", "https:///x", "data:text/plain,x",
                     "https://x.com/" + String(repeating: "a", count: 2100)] {
            #expect(LinkDownloadRules.validate(text) == .invalid, "accepted \(text)")
        }
    }

    @Test func qualityUsesTheShortSideSoPortraitVideoIsNotMislabelled() {
        #expect(QualityTier(shortSide: min(1080, 1920)) == .p1080)
        #expect(QualityTier(shortSide: min(2160, 3840)) == .p2160)
        #expect(QualityTier(shortSide: min(4096, 2160)) == .p2160)
        #expect(QualityTier(shortSide: 1600) == .p1440)  // 2560×1600 4K değildir
        #expect(QualityTier(shortSide: 240) == .low)
        #expect(QualityTier(shortSide: 720) == .p720)
        #expect(QualityTier(shortSide: 704) == .p720)
        #expect(QualityTier(shortSide: 576) == .p480)
        #expect(QualityTier.p2160.label == "4K")
        // Dikey 1080×1920: yalnız yüksekliğe bakılsaydı 1440p+ görünürdü.
        let options = DownloadPlanner.videoOptions([video("v", 1080, 1920, acodec: "mp4a.40.2")])
        #expect(options.map(\.tier) == [.p1080])
    }

    @Test func listsOnlyTiersTheSourceReallyHas() {
        let formats = [video("v720", 1280, 720), video("v1080", 1920, 1080), video("v4k", 3840, 2160), audio("a")]
        let options = DownloadPlanner.videoOptions(formats)
        #expect(options.map(\.tier) == [.p2160, .p1080, .p720])
        #expect(options.allSatisfy { $0.isAvailable })
        if case .merge(let v, let a) = options[0].plan?.kind { #expect(v.id == "v4k" && a.id == "a") } else { Issue.record("4K not merged") }
        #expect(options[0].plan?.outputExtension == "mp4")
        // Yalnız 720p sunan kaynakta 1080p/4K hiç listelenmez (büyütme yok).
        let low = DownloadPlanner.videoOptions([video("m", 1280, 720, acodec: "mp4a.40.2")])
        #expect(low.map(\.tier) == [.p720])
    }

    @Test func nonMP4HighTierIsShownDisabledNotSilentlyDowngraded() {
        let formats = [video("vp9", 3840, 2160, ext: "webm", vcodec: "vp09.00.50.08"), video("h264", 1920, 1080), audio("a")]
        let options = DownloadPlanner.videoOptions(formats)
        #expect(options.map(\.tier) == [.p2160, .p1080])
        #expect(!options[0].isAvailable && options[0].reason != nil)
        #expect(options[1].isAvailable)
    }

    @Test func prefersMuxedMP4AndKeepsItsRealContainer() {
        let muxed = video("b", 1280, 720, acodec: "mp4a.40.2", tbr: 900)
        let options = DownloadPlanner.videoOptions([muxed, audio("a")])
        #expect(options.first?.plan?.kind == .single(muxed))
        let webmMuxed = video("w", 1280, 720, ext: "webm", vcodec: "vp9", acodec: "opus")
        #expect(DownloadPlanner.videoOptions([webmMuxed]).first?.plan?.outputExtension == "webm")
    }

    @Test func audioOnlyKeepsTheSourceFormatAndIsUnavailableWithoutSound() {
        let formats = [video("v", 1920, 1080), audio("opus", ext: "webm", acodec: "opus", tbr: 160), audio("aac", tbr: 128)]
        let plan = DownloadPlanner.audioPlan(formats)
        if case .single(let f) = plan?.kind { #expect(f.id == "aac" && plan?.outputExtension == "m4a") } else { Issue.record("no audio") }
        let opusOnly = DownloadPlanner.audioPlan([audio("opus", ext: "webm", acodec: "opus")])
        #expect(opusOnly?.outputExtension == "webm")  // MP3'e dönüştürülmez
        let muxedOnly = DownloadPlanner.audioPlan([video("m", 1280, 720, acodec: "mp4a.40.2")])
        if case .extractAudio = muxedOnly?.kind { #expect(muxedOnly?.outputExtension == "m4a") } else { Issue.record("no extraction plan") }
        let silent = [video("v", 1920, 1080), video("w", 1280, 720)]
        #expect(DownloadPlanner.audioPlan(silent) == nil)
        #expect(!DownloadPlanner.hasAudio(silent))
        // Sessiz kaynakta görüntü yine indirilebilir.
        #expect(DownloadPlanner.videoOptions(silent).allSatisfy { $0.isAvailable })
    }

    @Test func tierWithoutAudioIsDisabledWhenSoundExistsOnlyElsewhere() {
        let formats = [video("v1080", 1920, 1080), video("m720", 1280, 720, acodec: "mp4a.40.2")]
        let options = DownloadPlanner.videoOptions(formats)
        #expect(options.map(\.tier) == [.p1080, .p720])
        #expect(!options[0].isAvailable && options[1].isAvailable)
    }

    @Test func decodesEngineJSONAndRejectsPlaylists() throws {
        let json = #"{"title":"Örnek / video","_type":"video","duration":12.5,"formats":[{"format_id":"1","ext":"mp4","vcodec":"avc1","acodec":"none","width":1920,"height":1080,"tbr":2000},{"format_id":"bad","ext":5},{"format_id":"a","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","filesize_approx":1000}]}"#
        let info = try JSONDecoder().decode(MediaInfo.self, from: Data(json.utf8))
        #expect(info.isSingleVideo && info.formats.count == 2 && info.title == "Örnek / video")
        let list = try JSONDecoder().decode(MediaInfo.self, from: Data(#"{"_type":"playlist","entries":[]}"#.utf8))
        #expect(!list.isSingleVideo && list.formats.isEmpty)
    }

    @Test func parsesAndCoalescesProgress() {
        #expect(DownloadProgressParser.fraction("OIPROG 50 100 NA") == 0.5)
        #expect(DownloadProgressParser.fraction("OIPROG 50 NA 200") == 0.25)
        #expect(DownloadProgressParser.fraction("OIPROG 50 NA NA") == nil)
        #expect(DownloadProgressParser.fraction("[download] 50%") == nil)
        #expect(DownloadProgressParser.fraction("OIPROG 150 100 NA") == 1)
        #expect(DownloadProgressParser.shouldPublish(0.1, last: nil, elapsedSinceLast: 0))
        #expect(!DownloadProgressParser.shouldPublish(0.105, last: 0.1, elapsedSinceLast: 0.1))
        #expect(DownloadProgressParser.shouldPublish(0.105, last: 0.1, elapsedSinceLast: 0.3))
        #expect(!DownloadProgressParser.shouldPublish(0.1, last: 0.1, elapsedSinceLast: 5))
        #expect(DownloadProgressParser.shouldPublish(1, last: 0.999, elapsedSinceLast: 0))
        #expect(!DownloadProgressParser.shouldPublish(1, last: 1, elapsedSinceLast: 9))
    }

    @Test func fileNamesAreSafeAndNeverOverwrite() {
        #expect(DownloadFileNaming.baseName(title: "a/b:c\\d\n e") == "a b c d e")
        #expect(DownloadFileNaming.baseName(title: "..gizli") == "gizli")
        #expect(DownloadFileNaming.baseName(title: "   ") == "İndirilen video")
        #expect(DownloadFileNaming.baseName(title: nil) == "İndirilen video")
        #expect(DownloadFileNaming.baseName(title: String(repeating: "ğ", count: 300)).count == 120)
        let taken: Set = ["Ad.mp4", "Ad (2).mp4"]
        #expect(DownloadFileNaming.uniqueName(base: "Ad", ext: "mp4") { taken.contains($0) } == "Ad (3).mp4")
        #expect(DownloadFileNaming.uniqueName(base: "Ad", ext: "webm") { taken.contains($0) } == "Ad.webm")
        #expect(DownloadFileNaming.uniqueName(base: "Ad", ext: "mp4") { _ in true } == nil)
    }

    @Test func classifiesEngineErrorsWithoutEchoingThem() {
        #expect(DownloadFailure.classify("ERROR: [TikTok] 1: This post may not be comfortable for some audiences. Log in for access") == .loginRequired)
        #expect(DownloadFailure.classify("ERROR: [facebook] Cannot parse data; Use --cookies-from-browser") == .loginRequired)
        #expect(DownloadFailure.classify("ERROR: The uploader has not made this video available in your country") == .unavailableInRegion)
        #expect(DownloadFailure.classify("ERROR: Unsupported URL: https://x.com/home") == .unsupported)
        #expect(DownloadFailure.classify("ERROR: [twitter] 1: No video could be found in this tweet") == .unsupported)
        #expect(DownloadFailure.classify("ERROR: HTTP Error 404: Not Found") == .removed)
        #expect(DownloadFailure.classify("ERROR: Requested format is not available") == .formatGone)
        #expect(DownloadFailure.classify("ERROR: unable to download video data: <urlopen error [Errno 51] Network is unreachable>") == .network)
        #expect(DownloadFailure.classify("ERROR: Read timed out.") == .timedOut)
        #expect(DownloadFailure.classify("OSError: [Errno 28] No space left on device") == .diskFull)
        #expect(DownloadFailure.classify("ERROR: unable to open for writing: [Errno 13] Permission denied") == .writePermission)
        #expect(DownloadFailure.classify("something odd") == .other)
        #expect(!DownloadFailure.other.message.contains("http"))
        #expect(DownloadFailure.classify("ERROR: [youtube] abc: Sign in to confirm you’re not a bot. Use --cookies-from-browser") == .botCheck)
        #expect(DownloadFailure.classify("ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate") == .loginRequired)
        #expect(DownloadFailure.classify("ERROR: [youtube] abc: This live event will begin in 3 hours.") == .live)
        #expect(DownloadFailure.classify("ERROR: [youtube] abc: Video unavailable. This video has been removed by the uploader") == .removed)
        #expect(DownloadFailure.classify("ERROR: unable to download video data: HTTP Error 403: Forbidden") == .formatGone)
    }

    @Test func generationRejectsLateResults() {
        var g = DownloadGeneration()
        let first = g.next(); let second = g.next()
        #expect(!g.accepts(first) && g.accepts(second))
        #expect(LinkDownloadPhase.downloading.isBusy && !LinkDownloadPhase.ready.isBusy && !LinkDownloadPhase.cancelled.isBusy)
        #expect(LinkDownloadPhase.installingEngine.isBusy && !LinkDownloadPhase.needsEngine.isBusy)
    }

    // MARK: - Yalnız video

    @Test func videoOnlyPrefersTheSeparateVideoStreamAndKeepsItsTier() {
        let formats = [video("v1080", 1920, 1080, tbr: 3000), video("m360", 640, 360, acodec: "mp4a.40.2", tbr: 400),
                       video("v360", 640, 360, tbr: 230), audio("a")]
        let options = DownloadPlanner.videoOnlyOptions(formats)
        #expect(options.map(\.tier) == [.p1080, .p360])
        #expect(options[0].plan?.kind == .single(formats[0]) && options[0].plan?.outputExtension == "mp4")
        // 360p'de ayrı görüntü akışı var: birleşik akış (daha çok veri) indirilmez.
        #expect(options[1].plan?.kind == .single(formats[2]))
    }

    @Test func videoOnlyStripsSoundFromMuxedOnlySources() {
        let muxed = video("m", 1280, 720, acodec: "mp4a.40.2", size: 9_000)
        let options = DownloadPlanner.videoOnlyOptions([muxed])
        #expect(options.map(\.tier) == [.p720])
        #expect(options[0].plan?.kind == .extractVideo(from: muxed))
        #expect(options[0].plan?.outputExtension == "mp4" && options[0].plan?.estimatedBytes == 9_000)
        // MP4 dışı birleşik akıştan ses yeniden kodlamadan ayrılamaz: basamak nedeniyle devre dışı.
        let webm = video("w", 1280, 720, ext: "webm", vcodec: "vp9", acodec: "opus")
        let disabled = DownloadPlanner.videoOnlyOptions([webm])
        #expect(!disabled[0].isAvailable && disabled[0].reason != nil)
        // Kaynakta hiç ses yoksa görüntü olduğu gibi indirilir.
        #expect(DownloadPlanner.videoOnlyOptions([video("s", 1280, 720, ext: "webm", vcodec: "vp9")])[0].plan?.outputExtension == "webm")
    }

    @Test func av1IsPassthroughOnlyWhenTheMacDecodesIt() {
        let av1 = video("401", 3840, 2160, vcodec: "av01.0.13M.08"), h264 = video("299", 1920, 1080), sound = audio("140")
        #expect(!av1.isMP4Video && av1.isPassthroughVideo(av1: true) && !av1.isPassthroughVideo(av1: false))
        #expect(!video("vp9", 3840, 2160, ext: "webm", vcodec: "vp9").isPassthroughVideo(av1: true))
        let without = DownloadPlanner.videoOptions([av1, h264, sound], av1: false)
        #expect(without.map(\.tier) == [.p2160, .p1080] && !without[0].isAvailable && without[1].isAvailable)
        let with = DownloadPlanner.videoOptions([av1, h264, sound], av1: true)
        if case .merge(let v, let a) = with[0].plan?.kind { #expect(v.id == "401" && a.id == "140") } else { Issue.record("4K AV1 not merged") }
        #expect(DownloadPlanner.videoOnlyOptions([av1, sound], av1: true)[0].plan?.kind == .single(av1))
    }

    @Test func modesHaveTurkishTitlesAndQualityUse() {
        #expect(DownloadMode.allCases.map(\.title) == ["Video + ses", "Yalnız video", "Yalnız ses"])
        #expect(DownloadMode.videoOnly.usesQuality && DownloadMode.videoWithAudio.usesQuality && !DownloadMode.audioOnly.usesQuality)
    }
}
