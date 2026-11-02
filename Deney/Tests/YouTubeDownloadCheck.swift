import AppKit
import AVFoundation
import IslandCore

/// Yalıtılmış, ağ kullanan YouTube indirme denetimi: onay → motor kurulumu (SHA-256, tek mimari, imza) → inceleme →
/// yalnız ses / yalnız video / video + ses indirmesi → süre ve izler → geride süreç kalmaması. Kullanıcının destek
/// klasörüne, tercihlerine veya İndirilenler klasörüne dokunmaz; motor ve dosyalar fikstür kökündedir.
@main @MainActor final class YouTubeDownloadCheck: NSObject, NSApplicationDelegate {
    static var retained: YouTubeDownloadCheck?
    static func main() {
        let e = ProcessInfo.processInfo.environment
        guard e["OPENISLAND_DIAGNOSTICS"] != nil, let root = e["OPENISLAND_TEST_ROOT"], root.hasPrefix("/"),
              let support = e["OPENISLAND_TEST_SUPPORT"], support.hasPrefix(root + "/"),
              e["OPENISLAND_TEST_DEFAULTS"]?.hasPrefix("io.github.openisland.") == true,
              Bundle.main.bundleIdentifier?.hasPrefix("io.github.openisland.validation.") == true else { exit(78) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let d = YouTubeDownloadCheck(); retained = d; app.delegate = d; app.run()
    }

    var failures: [String] = [], checks = 0, report: [String: Any] = [:]
    func check(_ ok: Bool, _ message: String) { checks += 1; if !ok { failures.append(message); print("FAIL: \(message)") } }
    func applicationDidFinishLaunching(_ note: Notification) { Task { await run() } }

    private func wait(_ d: LinkDownloader, seconds: Double, while busy: (LinkDownloadPhase) -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while busy(d.phase), Date() < end { try? await Task.sleep(for: .milliseconds(200)) }
    }

    private func probe(_ url: URL) async -> (duration: Double, video: Int, audio: Int, codec: String) {
        let asset = AVURLAsset(url: url)
        let v = (try? await asset.loadTracks(withMediaType: .video)) ?? [], a = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        var codec = ""
        if let fd = try? await v.first?.load(.formatDescriptions).first {
            let sub = CMFormatDescriptionGetMediaSubType(fd)
            codec = String(bytes: [24, 16, 8, 0].map { UInt8((sub >> $0) & 0xff) }, encoding: .ascii) ?? ""
        }
        return ((try? await asset.load(.duration).seconds) ?? 0, v.count, a.count, codec)
    }

    private func children() -> Int {
        var buffer = [pid_t](repeating: 0, count: 64)
        return Int(proc_listchildpids(getpid(), &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size)))
    }

    func run() async {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPENISLAND_TEST_ROOT"]!)
        let link = ProcessInfo.processInfo.environment["OPENISLAND_TEST_YOUTUBE_URL"] ?? "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        let d = LinkDownloader()
        let started = Date()

        // Panel: Pano içeriğinin gerçek genişliğinde öğeler üst üste binmez, tür seçicisi tam görünür.
        let metrics = NotchMetrics(notchSize: CGSize(width: 192, height: 33.5), style: .notch)
        let width = IslandLayoutEngine.contentSize(for: .clipboard, metrics: metrics).width
        let view = LinkDownloadView(downloader: d)
        view.frame = CGRect(x: 0, y: 0, width: width, height: 103)
        view.didShow()
        report["panelWidth"] = width

        // 1) Onay: motor yokken indirme başlamaz.
        check(YouTubeEngine.installed() == nil, "engine unexpectedly present before consent")
        d.inspect(link)
        await wait(d, seconds: 10) { $0 == .inspecting }
        check(d.phase == .needsEngine, "YouTube link without engine did not ask for consent (phase \(d.phase))")
        check(!FileManager.default.fileExists(atPath: YouTubeEngine.directory.path), "engine folder created before consent")
        view.layoutSubtreeIfNeeded()
        let consentTitles = Self.labels(in: view)
        check(consentTitles.contains("YouTube motorunu indir") && consentTitles.contains("Vazgeç"), "consent buttons missing: \(consentTitles)")
        snapshot(view, root, "1-consent")

        // 2) Kurulum
        let installStart = Date(), childCPU0 = Self.childCPU()
        d.installEngine()
        check(d.phase == .installingEngine, "install did not start")
        await wait(d, seconds: 600) { $0 == .installingEngine }
        report["installSeconds"] = Date().timeIntervalSince(installStart)
        report["installChildCPU"] = Self.childCPU() - childCPU0
        let engine = await Task.detached { YouTubeEngine.installed() }.value
        check(engine != nil, "engine not installed/verified: \(d.message ?? "-")")
        if let engine {
            let size = Self.folderSize(YouTubeEngine.directory)
            report["engineBytes"] = size
            check(size < 80 << 20, "engine folder larger than expected: \(size)")
            let archs = Self.archs(engine.downloader)
            check(archs == ["arm64"] || archs == ["x86_64"], "engine executable not thinned: \(archs)")
            check(engine.manifest.downloader == YouTubeEnginePin.downloader && engine.manifest.quickJS == YouTubeEnginePin.quickJS, "manifest differs from pins")
        }

        // 3) İnceleme (kurulumdan sonra bekleyen bağlantı kendiliğinden incelenir)
        let inspectStart = Date(), inspectCPU0 = Self.childCPU()
        await wait(d, seconds: 180) { $0 == .inspecting || $0 == .idle }
        report["inspectSeconds"] = Date().timeIntervalSince(inspectStart)
        report["inspectChildCPU"] = Self.childCPU() - inspectCPU0
        check(d.phase == .ready, "inspection did not reach ready: \(d.phase) \(d.message ?? "")")
        check(d.platform == .youtube && d.title?.isEmpty == false, "platform/title missing")
        report["videoTiers"] = d.videoOptions.map { "\($0.tier.label)\($0.isAvailable ? "" : "×")" }
        report["videoOnlyTiers"] = d.videoOnlyOptions.map { "\($0.tier.label)\($0.isAvailable ? "" : "×")" }
        check(d.videoOptions.contains { $0.tier == .p1080 && $0.isAvailable }, "1080p not offered")
        check(d.isAvailable(.videoOnly) && d.isAvailable(.audioOnly), "video-only or audio-only unavailable")
        check(children() == 0, "engine process left running after inspection")
        view.layoutSubtreeIfNeeded()
        check(Self.overlaps(in: view).isEmpty, "form controls overlap at \(width) pt: \(Self.overlaps(in: view))")
        snapshot(view, root, "2-ready")
        d.select(.videoOnly); view.layoutSubtreeIfNeeded(); snapshot(view, root, "3-video-only")
        d.select(.audioOnly); view.layoutSubtreeIfNeeded(); snapshot(view, root, "4-audio-only")

        // 4) İndirmeler: küçük basamaklarla (ağ yükü az), her birinde gerçek süre ve izler.
        let expected = 634.5
        for (mode, tier) in [(DownloadMode.audioOnly, nil), (.videoOnly, QualityTier.low), (.videoWithAudio, QualityTier.p480)] as [(DownloadMode, QualityTier?)] {
            d.select(mode)
            if let tier { d.tier = tier }
            check(d.mode == mode && d.canDownload, "\(mode) not selectable/downloadable")
            let t0 = Date(), cpu0 = Self.childCPU()
            d.download()
            await wait(d, seconds: 600) { $0.isBusy }
            let name = "\(mode.rawValue)"
            report[name + "Seconds"] = Date().timeIntervalSince(t0)
            report[name + "ChildCPU"] = Self.childCPU() - cpu0
            check(d.phase == .finished, "\(mode) download did not finish: \(d.phase) \(d.message ?? "")")
            guard let file = d.savedFile else { continue }
            let p = await probe(file)
            report[name + "File"] = ["name": file.lastPathComponent, "duration": p.duration, "video": p.video, "audio": p.audio, "codec": p.codec,
                                     "bytes": (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0]
            check(abs(p.duration - expected) < 2, "\(mode) duration \(p.duration) (DASH süresi düzeltilmedi mi?)")
            switch mode {
            case .audioOnly: check(p.video == 0 && p.audio == 1 && file.pathExtension == "m4a", "audio-only tracks wrong \(p)")
            case .videoOnly: check(p.video == 1 && p.audio == 0 && file.pathExtension == "mp4", "video-only tracks wrong \(p)")
            case .videoWithAudio: check(p.video == 1 && p.audio == 1 && file.pathExtension == "mp4", "video+audio tracks wrong \(p)")
            }
            check(children() == 0, "engine process left running after \(mode)")
            view.layoutSubtreeIfNeeded(); snapshot(view, root, "5-finished-\(mode.rawValue)")
        }

        // 5) Vazgeç yolu ve iptal: motor varken onay sorulmaz; iptal süreci bırakmaz.
        d.reset()
        d.inspect(link)
        try? await Task.sleep(for: .milliseconds(1500))
        d.cancel()
        try? await Task.sleep(for: .milliseconds(3500))
        check(d.phase == .cancelled && children() == 0, "cancelled inspection left a process or wrong phase \(d.phase)")
        let jobs = root.appendingPathComponent("support/LinkDownloads")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: jobs.path)) ?? [])
        check(leftovers.isEmpty, "temporary job folders left: \(leftovers)")

        view.didHide()
        report["totalSeconds"] = Date().timeIntervalSince(started)
        report["checks"] = checks; report["failures"] = failures
        let out = root.appendingPathComponent("youtube-check.json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out)
        print(String(decoding: (try? Data(contentsOf: out)) ?? Data(), as: UTF8.self))
        print(failures.isEmpty ? "PASS \(checks)" : "FAIL \(failures.count)/\(checks)")
        exit(failures.isEmpty ? 0 : 1)
    }

    /// Formun koyu zemin üzerinde 2x görüntüsü (gözle denetim için).
    func snapshot(_ view: NSView, _ root: URL, _ name: String) {
        let host = NSView(frame: view.frame.insetBy(dx: -12, dy: -12)); host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor; host.appearance = NSAppearance(named: .darkAqua)
        let parent = view.superview; view.removeFromSuperview(); view.frame.origin = CGPoint(x: 12, y: 12); host.addSubview(view)
        (view as? LinkDownloadView)?.update(); view.needsLayout = true; host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("shot-\(name).png"))
        }
        view.removeFromSuperview(); view.frame.origin = .zero; parent?.addSubview(view)
    }

    static func childCPU() -> Double {
        var usage = rusage(); getrusage(RUSAGE_CHILDREN, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    static func labels(in view: NSView) -> [String] {
        var out: [String] = []
        func walk(_ v: NSView) { if !v.isHidden { if let l = v.accessibilityLabel(), !l.isEmpty { out.append(l) }; v.subviews.forEach(walk) } }
        walk(view)
        return out
    }

    /// Görünür, etkileşimli doğrudan alt öğelerin çakışması.
    static func overlaps(in view: NSView) -> [String] {
        let items = view.subviews.filter { !$0.isHidden && $0.frame.width > 0 && ($0 is NSControl || $0 is RoundedView || $0 is PlainButton) }
        var out: [String] = []
        for (i, a) in items.enumerated() { for b in items[(i + 1)...] where a.frame.insetBy(dx: 0.5, dy: 0.5).intersects(b.frame.insetBy(dx: 0.5, dy: 0.5)) {
            if a.frame.contains(b.frame) || b.frame.contains(a.frame) { continue }
            out.append("\(type(of: a))\(a.frame) × \(type(of: b))\(b.frame)")
        } }
        return out
    }

    static func folderSize(_ url: URL) -> Int {
        var total = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
        while let f = walker?.nextObject() as? URL {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink != true { total += v?.totalFileAllocatedSize ?? 0 }
        }
        return total
    }

    static func archs(_ url: URL) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url), let head = try? h.read(upToCount: 8) else { return [] }
        try? h.close()
        if MachOFat.isFat(head) { return ["fat"] }
        let b = [UInt8](head)
        guard b.count == 8, b[0] == 0xCF, b[1] == 0xFA else { return ["?"] }
        let cpu = Int32(b[4]) | Int32(b[5]) << 8 | Int32(b[6]) << 16 | Int32(b[7]) << 24
        return [cpu == MachOFat.arm64 ? "arm64" : cpu == MachOFat.x86_64 ? "x86_64" : "\(cpu)"]
    }
}
