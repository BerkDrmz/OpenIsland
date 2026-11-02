import Foundation
import Testing
@testable import IslandCore

@Suite("Bağlantıdan indir: uygulama içi çıkarıcılar")
struct LinkExtractorTests {
    @Test func jsRadixMatchesV8() {
        // Beklenen değerler Node (V8) `Number.prototype.toString(36)` çıktısıdır.
        #expect(JSNumber.string(0.1, radix: 36) == "0.3lllllllllm")
        #expect(JSNumber.string(1.0 / 3.0, radix: 36) == "0.c")
        #expect(JSNumber.string(123.456, radix: 36) == "3f.gez4w97ry")
        #expect(JSNumber.string(5290.7, radix: 36) == "42y.p7777777")
        #expect(JSNumber.string(2.5, radix: 36) == "2.i")
        #expect(XExtractor.token("1683920951807971329") == "42y6zv7ufp")
        #expect(XExtractor.token("1234567890123456789") == "2zqic77uqyk")
        #expect(XExtractor.token("1858503417453797537") == "4i6ns8tn7h")
        #expect(XExtractor.token("999999999999999999") == "2f9lc2ug9mm")
    }

    @Test func xStatusIDAndSyndicationURL() {
        #expect(XExtractor.statusID(URL(string: "https://x.com/user/status/1683920951807971329?s=20")!) == "1683920951807971329")
        #expect(XExtractor.statusID(URL(string: "https://twitter.com/i/web/status/20")!) == "20")
        #expect(XExtractor.statusID(URL(string: "https://x.com/user/status/123/video/1")!) == "123")
        #expect(XExtractor.statusID(URL(string: "https://x.com/home")!) == nil)
        #expect(XExtractor.statusID(URL(string: "https://x.com/u/status/12ab")!) == nil)
        let url = XExtractor.syndicationURL(id: "1683920951807971329")!.absoluteString
        #expect(url == "https://cdn.syndication.twimg.com/tweet-result?id=1683920951807971329&lang=en&token=42y6zv7ufp")
    }

    @Test func xParsesMP4VariantsWithRealSizes() throws {
        let json = #"""
        {"__typename":"Tweet","text":"Örnek video https://t.co/abc","mediaDetails":[{"type":"video","video_info":{"variants":[
          {"content_type":"application/x-mpegURL","url":"https://video.twimg.com/ext_tw_video/1/pu/pl/x.m3u8"},
          {"bitrate":256000,"content_type":"video/mp4","url":"https://video.twimg.com/ext_tw_video/1/pu/vid/avc1/480x270/a.mp4?tag=12"},
          {"bitrate":2176000,"content_type":"video/mp4","url":"https://video.twimg.com/ext_tw_video/1/pu/vid/avc1/1920x1080/b.mp4?tag=12"},
          {"bitrate":832000,"content_type":"video/mp4","url":"http://insecure.example/vid/avc1/640x360/c.mp4"}]}}]}
        """#
        let media = try XExtractor.parse(Data(json.utf8), id: "1").get()
        #expect(media.title == "Örnek video")
        #expect(media.sources.map(\.format.id) == ["http-256", "http-2176"])
        #expect(media.sources[1].format.width == 1920 && media.sources[1].format.height == 1080 && media.sources[1].format.hasAudio)
        #expect(DownloadPlanner.videoOptions(media.formats).map(\.tier) == [.p1080, .low])
        // Dikey X videosu: 720x1280 → 720p.
        let portrait = #"{"text":"","mediaDetails":[{"type":"video","video_info":{"variants":[{"bitrate":1,"content_type":"video/mp4","url":"https://video.twimg.com/v/vid/avc1/720x1280/p.mp4"}]}}]}"#
        let p = try XExtractor.parse(Data(portrait.utf8), id: "9").get()
        #expect(p.title == "X video 9" && DownloadPlanner.videoOptions(p.formats).map(\.tier) == [.p720])
        let gif = #"{"text":"g","mediaDetails":[{"type":"animated_gif","video_info":{"variants":[{"bitrate":0,"content_type":"video/mp4","url":"https://video.twimg.com/tweet_video/g.mp4"}]}}]}"#
        let g = try XExtractor.parse(Data(gif.utf8), id: "2").get()
        #expect(!g.sources[0].format.hasAudio)
    }

    @Test func xErrors() {
        #expect(XExtractor.parse(Data(#"{"__typename":"TweetTombstone","tombstone":{"text":{"text":"Age-restricted adult content. Log in"}}}"#.utf8), id: "1") == .failure(.loginRequired))
        #expect(XExtractor.parse(Data(#"{"__typename":"TweetTombstone","tombstone":{"text":{"text":"This Post was deleted"}}}"#.utf8), id: "1") == .failure(.removed))
        #expect(XExtractor.parse(Data(#"{"text":"no video","mediaDetails":[{"type":"photo"}]}"#.utf8), id: "1") == .failure(.unsupported))
        #expect(XExtractor.parse(Data("<html>".utf8), id: "1") == .failure(.other))
    }

    private func tiktokPage(status: Int = 0, video: String? = nil, classified: Bool = false) -> String {
        let item = video.map { #","itemInfo":{"itemStruct":{"id":"7","desc":"Dans #fyp","video":\#($0)}}"# }
            ?? (classified ? #","itemInfo":{"itemStruct":{"id":"7","isContentClassified":true}}"# : "")
        return #"<html><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">{"__DEFAULT_SCOPE__":{"webapp.video-detail":{"statusCode":\#(status)\#(item)}}}</script></html>"#
    }

    @Test func tiktokParsesBitrateInfoAndDerivesPortraitSize() throws {
        let video = #"""
        {"width":576,"height":1024,"playAddr":"https://v16.tiktokcdn.com/play.mp4","bitrateInfo":[
          {"Bitrate":1500000,"PlayAddr":{"UrlKey":"v12044gd0000_h264_720p_1500000","UrlList":["https://www.tiktok.com/x","https://v16.tiktokcdn.com/a.mp4"],"DataSize":"4000000"}},
          {"Bitrate":900000,"PlayAddr":{"UrlKey":"v12044gd0000_bytevc1_540p_900000","UrlList":["https://v16.tiktokcdn.com/b.mp4"],"DataSize":2000000,"Width":576,"Height":1024}},
          {"Bitrate":700000,"PlayAddr":{"UrlKey":"v12044gd0000_bytevc2_540p_700000","UrlList":["https://v16.tiktokcdn.com/c.mp4"]}}]}
        """#
        let media = try TikTokExtractor.parse(html: tiktokPage(video: video)).get()
        #expect(media.title == "Dans #fyp")
        #expect(media.sources.count == 2) // bytevc2 oynatılamaz, atlanır
        let h264 = media.sources[0]
        #expect(h264.url.absoluteString == "https://v16.tiktokcdn.com/a.mp4") // www.tiktok.com adresi atlanır
        #expect(h264.format.width == 720 && h264.format.height == 1280 && h264.format.filesize == 4_000_000)
        #expect(media.sources[1].format.vcodec == "hvc1" && media.sources[1].format.width == 576)
        #expect(DownloadPlanner.videoOptions(media.formats).map(\.tier) == [.p720, .p480])
    }

    @Test func tiktokStatusCodesAndFallbacks() {
        #expect(TikTokExtractor.parse(html: tiktokPage(status: 10216)) == .failure(.loginRequired))
        #expect(TikTokExtractor.parse(html: tiktokPage(status: 10222)) == .failure(.loginRequired))
        #expect(TikTokExtractor.parse(html: tiktokPage(status: 10204)) == .failure(.unavailableInRegion))
        #expect(TikTokExtractor.parse(html: tiktokPage(status: 10101)) == .failure(.removed))
        #expect(TikTokExtractor.parse(html: tiktokPage(classified: true)) == .failure(.loginRequired))
        #expect(TikTokExtractor.parse(html: "<html><div id=\"cs\">challenge</div></html>") == .failure(.other))
        let play = try? TikTokExtractor.parse(html: tiktokPage(video: #"{"width":1080,"height":1920,"playAddr":"https://v16.tiktokcdn.com/p.mp4"}"#)).get()
        #expect(play?.sources.first?.format.id == "play" && play?.sources.first?.format.width == 1080)
    }

    @Test func tiktokIDsAndShortLinks() {
        #expect(TikTokExtractor.videoID(URL(string: "https://www.tiktok.com/@u.ser/video/7301234567890123456?lang=tr")!) == "7301234567890123456")
        #expect(TikTokExtractor.videoID(URL(string: "https://www.tiktok.com/embed/v2/7301")!) == "7301")
        #expect(TikTokExtractor.videoID(URL(string: "https://www.tiktok.com/@user")!) == nil)
        #expect(TikTokExtractor.isShortLink(URL(string: "https://vm.tiktok.com/ZM123/")!))
        #expect(TikTokExtractor.isShortLink(URL(string: "https://www.tiktok.com/t/ZT123/")!))
        #expect(!TikTokExtractor.isShortLink(URL(string: "https://www.tiktok.com/@u/video/1")!))
    }

    @Test func facebookParsesEscapedURLsTitleAndLoginWall() throws {
        let html = #"""
        <html><meta property="og:title" content="Kedi &amp; köpek | Facebook" />
        <script>{"browser_native_sd_url":"https:\/\/video.xx.fbcdn.net\/v\/sd.mp4?_nc=1&oh=2","browser_native_hd_url":"https:\/\/video.xx.fbcdn.net\/v\/hd.mp4?a=&1"}
        {"playable_url":"https:\/\/video.xx.fbcdn.net\/v\/sd.mp4?_nc=1&oh=2","dash_manifest_url":"https:\/\/x\/m.mpd"}</script></html>
        """#
        let media = try FacebookExtractor.parse(html: html).get()
        #expect(media.title == "Kedi & köpek")
        #expect(media.sources.map(\.format.id) == ["hd", "sd"])
        #expect(media.sources[0].url.absoluteString == "https://video.xx.fbcdn.net/v/hd.mp4?a=&1")
        #expect(FacebookExtractor.parse(html: "<form id=\"login_form\"></form>") == .failure(.loginRequired))
        #expect(FacebookExtractor.parse(html: "<div class=\"uiInterstitialContent\">gone</div>") == .failure(.removed))
        #expect(FacebookExtractor.parse(html: "<html>nothing</html>") == .failure(.unsupported))
        #expect(FacebookExtractor.pageURL(URL(string: "http://m.facebook.com/reel/1")!).absoluteString == "https://www.facebook.com/reel/1")
    }
}

@Suite("Bağlantıdan indir: X GIF boyutu")
struct XGifSizeTests {
    @Test func gifUsesOriginalInfoWhenURLHasNoSize() throws {
        let gif = #"{"text":"g","mediaDetails":[{"type":"animated_gif","original_info":{"width":498,"height":280},"video_info":{"variants":[{"bitrate":0,"content_type":"video/mp4","url":"https://video.twimg.com/tweet_video/g.mp4"}]}}]}"#
        let g = try XExtractor.parse(Data(gif.utf8), id: "2").get()
        #expect(g.sources[0].format.width == 498 && g.sources[0].format.height == 280)
    }
}
