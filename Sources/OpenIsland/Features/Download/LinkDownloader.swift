import AppKit
import IslandCore
import VideoToolbox

/// "Bağlantıdan indir" koordinatörü. Yalnız kullanıcının "İncele"/"İndir" basışıyla çalışır; boştayken ağ isteği,
/// zamanlayıcı, pano izleme veya yardımcı süreç yoktur. Facebook, X ve TikTok uygulama içi çıkarıcıyla (`NativeEngine`),
/// YouTube kullanıcının onayıyla indirilen ayrı motorla (`YouTubeEngine`) çözülür; motor süreci yalnız inceleme/indirme
/// boyunca yaşar. Aynı anda tek iş vardır. Her iş yeni bir kuşak alır; iptal edilen
/// veya yerini yenisine bırakan işin geç gelen sonucu durumu değiştirmez. Panel kapanması işi iptal etmez.
@MainActor
@Observable
final class LinkDownloader {
    private(set) var phase: LinkDownloadPhase = .idle
    private(set) var platform: LinkPlatform?
    private(set) var title: String?
    private(set) var videoOptions: [QualityOption] = []
    private(set) var videoOnlyOptions: [QualityOption] = []
    private(set) var audioPlan: DownloadPlan?
    private(set) var hasAudio = false
    private(set) var mode: DownloadMode = .videoWithAudio
    var tier: QualityTier?
    /// YouTube motoru kurulu ve son YouTube işi başarısız: kullanıcı motoru güncelleyebilir.
    private(set) var canUpdateEngine = false
    private(set) var folder: URL
    /// 0…1; bilinmiyorsa nil.
    private(set) var progress: Double?
    private(set) var message: String?
    private(set) var savedFile: URL?

    @ObservationIgnored var hold: IslandHold?
    @ObservationIgnored var shelf: ShelfStore?
    @ObservationIgnored private var generation = DownloadGeneration()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var engine: NativeEngine?
    @ObservationIgnored private var sources: [String: DirectSource] = [:]
    @ObservationIgnored private var referer: URL?
    /// YouTube: kurulu motor, incelemenin JSON'u (indirme sayfayı yeniden çözmesin) ve çalışan motor süreci.
    @ObservationIgnored private var youtube: YouTubeEngine.Installation?
    @ObservationIgnored private var youtubeInfo: Data?
    @ObservationIgnored private var run: EngineRun?
    /// Motor onayı/kurulumu beklenirken incelenecek bağlantı.
    @ObservationIgnored private var pendingLink: String?
    /// M3 ve sonrası AV1'i donanımda çözer: MP4 içindeki AV1 (YouTube 1440p/4K) yeniden kodlamadan taşınır. İlk
    /// incelemede bir kez sorulur (açılışta değil).
    private static let av1: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    @ObservationIgnored private var remux: MediaRemuxer.Handle?
    @ObservationIgnored private var inspectedURL: URL?
    @ObservationIgnored private let folderKey = "linkDownloadFolder"

    @ObservationIgnored private let defaults: UserDefaults

    init() {
        // Yalıtılmış geliştirici koşusu: tercih ve varsayılan klasör fikstürdedir (Preferences ile aynı kural).
        let environment = ProcessInfo.processInfo.environment
        let isolated = environment["OPENISLAND_DIAGNOSTICS"] != nil
        defaults = isolated ? environment["OPENISLAND_TEST_DEFAULTS"].flatMap { UserDefaults(suiteName: $0) } ?? .standard : .standard
        var fallback: URL?
        if isolated, let root = environment["OPENISLAND_TEST_ROOT"], root.hasPrefix("/") {
            fallback = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("Downloads", isDirectory: true)
        }
        let saved = defaults.string(forKey: folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        folder = saved ?? fallback ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// İncelenmiş bir bağlantı var ve iş sürmüyor: seçimler ve "İndir" etkin.
    var canDownload: Bool { inspectedURL != nil && !phase.isBusy && selectedPlan != nil }
    var isInspected: Bool { inspectedURL != nil }

    /// Seçili moda göre indirilecek plan; seçim yoksa veya kullanılamıyorsa nil.
    var selectedPlan: DownloadPlan? {
        switch mode {
        case .audioOnly: audioPlan
        case .videoWithAudio, .videoOnly: options(for: mode).first { $0.tier == tier }?.plan
        }
    }

    func options(for mode: DownloadMode) -> [QualityOption] {
        switch mode {
        case .videoWithAudio: videoOptions
        case .videoOnly: videoOnlyOptions
        case .audioOnly: []
        }
    }

    func isAvailable(_ mode: DownloadMode) -> Bool {
        mode == .audioOnly ? audioPlan != nil : options(for: mode).contains(where: \.isAvailable)
    }

    /// Tür değişince seçili kalite o türde yoksa ilk kullanılabilir basamağa geçilir (büyütme yok).
    func select(_ mode: DownloadMode) {
        guard !phase.isBusy, isAvailable(mode) else { return }
        self.mode = mode
        let options = options(for: mode)
        if !options.contains(where: { $0.tier == tier && $0.isAvailable }) { tier = options.first(where: \.isAvailable)?.tier ?? tier }
    }

    // MARK: - İnceleme

    func inspect(_ text: String) {
        guard !phase.isBusy else { return } // art arda basış ikinci işi başlatmaz
        // Aynı bağlantı zaten incelenmişse yeni istek yapılmaz (hata sonrası yeniden inceleme serbesttir).
        if case .valid(let u, _) = LinkDownloadRules.validate(text), u == inspectedURL, phase == .ready || phase == .finished { return }
        inspectedURL = nil
        clearResult()
        let url: URL, platform: LinkPlatform
        switch LinkDownloadRules.validate(text) {
        case .invalid: return fail("Geçerli bir http(s) bağlantısı yapıştırın.")
        case .unsupportedPlatform: return fail("Yalnız \(LinkPlatform.supportedNames) video bağlantıları destekleniyor.")
        case .valid(let u, let p): url = u; platform = p
        }
        self.platform = platform
        canUpdateEngine = false
        if platform.needsEngine { return inspectWithEngine(url, text: text) }
        let gen = generation.next()
        let engine = NativeEngine(platform: platform)
        self.engine = engine
        phase = .inspecting
        message = nil
        work = Task { [weak self] in
            do {
                let (media, referer) = try await engine.inspect(url)
                self?.inspectedNative(gen, url: url, media: media, referer: referer)
            } catch is CancellationError {
                self?.finishCancelledIfCurrent(gen)
            } catch let failure as DownloadFailure {
                self?.finish(gen, failure: failure)
            } catch {
                self?.finish(gen, failure: .other)
            }
        }
    }

    private func inspectedNative(_ gen: UInt64, url: URL, media: ExtractedMedia, referer: URL?) {
        guard generation.accepts(gen) else { return }
        sources = Dictionary(media.sources.map { ($0.format.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.referer = referer
        inspected(gen, url: url, formats: media.formats, title: media.title)
    }

    private func inspected(_ gen: UInt64, url: URL, formats: [MediaFormat], title: String?) {
        guard generation.accepts(gen) else { return }
        work = nil
        videoOptions = DownloadPlanner.videoOptions(formats, av1: Self.av1)
        videoOnlyOptions = DownloadPlanner.videoOnlyOptions(formats, av1: Self.av1)
        audioPlan = DownloadPlanner.audioPlan(formats, av1: Self.av1)
        hasAudio = DownloadPlanner.hasAudio(formats)
        guard !videoOptions.isEmpty || audioPlan != nil else { return finish(gen, failure: .unsupported) }
        inspectedURL = url
        self.title = title
        // Seçilen tür bu kaynakta yoksa sırayla video + ses, yalnız video, yalnız ses.
        if !isAvailable(mode) { mode = DownloadMode.allCases.first(where: isAvailable) ?? .videoWithAudio }
        tier = options(for: mode).first(where: \.isAvailable)?.tier ?? videoOptions.first(where: \.isAvailable)?.tier
        phase = .ready
        message = hasAudio ? nil : "Bu videoda ses yok."
    }

    // MARK: - YouTube motoru

    /// Motor kuruluysa doğrudan incelenir; değilse onay istenir (indirme kullanıcı "Motoru indir" deyince başlar).
    private func inspectWithEngine(_ url: URL, text: String) {
        engine?.invalidate(); engine = nil // önceki Facebook/X/TikTok oturumu
        let gen = generation.next()
        phase = .inspecting
        message = nil
        work = Task { [weak self] in
            let installed = await Task.detached(priority: .utility) { YouTubeEngine.installed() }.value
            guard let self, self.generation.accepts(gen) else { return }
            guard let installed else {
                self.work = nil
                self.pendingLink = text
                self.phase = .needsEngine
                self.message = nil
                return
            }
            self.youtube = installed
            await self.runInspection(url, engine: installed, gen: gen)
        }
    }

    private func runInspection(_ url: URL, engine: YouTubeEngine.Installation, gen: UInt64) async {
        guard let directory = await Self.prepareJobDirectory() else { return finish(gen, failure: .writePermission) }
        defer { Self.discard(directory) }
        let run = YouTubeEngine.inspection(url, engine: engine, workingDirectory: directory)
        guard attach(run, gen) else { return }
        let outcome = await run.run(timeout: YouTubeEngine.timeouts.inspect, stallTimeout: nil)
        guard generation.accepts(gen) else { return }
        self.run = nil
        if outcome.cancelled { return finishCancelledIfCurrent(gen) }
        if outcome.timedOut { return failYouTube(gen, .timedOut) }
        guard outcome.status == 0, !outcome.stdoutOverflow else { return failYouTube(gen, DownloadFailure.classify(outcome.stderrTail)) }
        let data = outcome.stdout
        let parsed = await Task.detached(priority: .utility) { try? JSONDecoder().decode(MediaInfo.self, from: data) }.value
        guard generation.accepts(gen) else { return }
        guard let info = parsed, info.isSingleVideo else { return failYouTube(gen, .unsupported) }
        if info.isLive { return finish(gen, failure: .live) }
        youtubeInfo = data
        inspected(gen, url: url, formats: YouTubeFormats.usable(info.formats), title: info.title)
    }

    /// Kullanıcı onayı: sabitlenmiş sürümler indirilir, doğrulanır; ardından bekleyen bağlantı incelenir.
    func installEngine() {
        guard phase == .needsEngine else { return }
        startEngineInstall(update: false)
    }

    func declineEngine() {
        guard phase == .needsEngine else { return }
        pendingLink = nil
        phase = .idle
        message = "YouTube motoru indirilmedi; YouTube bağlantıları incelenemez."
    }

    /// Yalnız kullanıcı isteyince: GitHub'daki son sürümler (özetiyle) indirilip doğrulanır; eskisi ancak yenisi
    /// çalışırsa değişir.
    func updateEngine() {
        guard canUpdateEngine, !phase.isBusy else { return }
        pendingLink = inspectedURL?.absoluteString ?? pendingLink
        startEngineInstall(update: true)
    }

    private func startEngineInstall(update: Bool) {
        let gen = generation.next()
        canUpdateEngine = false
        phase = .installingEngine
        progress = 0
        message = nil
        let gate = ProgressGate()
        work = Task { [weak self] in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 30
            configuration.httpAdditionalHeaders = ["User-Agent": "OpenIsland"]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                let (downloader, quickJS) = update ? try await YouTubeEngine.latest(session: session) : (YouTubeEnginePin.downloader, YouTubeEnginePin.quickJS)
                if update, let current = self?.youtube?.manifest, current.downloader == downloader, current.quickJS == quickJS {
                    self?.engineReady(gen, nil, note: "YouTube motoru güncel (\(downloader.version)).")
                    return
                }
                let installed = try await YouTubeEngine.install(downloader: downloader, quickJS: quickJS, session: session) { fraction in
                    guard let value = gate.pass(fraction) else { return }
                    Task { @MainActor in self?.publishProgress(value, gen) }
                }
                self?.engineReady(gen, installed, note: update ? "YouTube motoru güncellendi (\(downloader.version))." : nil)
            } catch is CancellationError {
                self?.finishCancelledIfCurrent(gen)
            } catch let failure as DownloadFailure {
                self?.finish(gen, failure: failure)
            } catch YouTubeEngine.Failure.digest {
                self?.fail(gen, "Motor dosyası doğrulanamadı (SHA-256 eşleşmedi); kurulmadı.")
            } catch YouTubeEngine.Failure.download {
                self?.finish(gen, failure: .network)
            } catch {
                self?.fail(gen, "YouTube motoru kurulamadı; eski hâline dokunulmadı.")
            }
        }
    }

    private func engineReady(_ gen: UInt64, _ installed: YouTubeEngine.Installation?, note: String?) {
        guard generation.accepts(gen) else { return }
        work = nil
        if let installed { youtube = installed }
        progress = nil
        phase = .idle
        if let link = pendingLink {
            pendingLink = nil
            inspect(link)
            if note != nil, phase == .inspecting { return }
        }
        message = note
    }

    private func failYouTube(_ gen: UInt64, _ failure: DownloadFailure) {
        guard generation.accepts(gen) else { return }
        finishLocal(failure)
        // YouTube değişmiş olabilir: kurulu motor kullanıcı isteğiyle güncellenebilir.
        canUpdateEngine = youtube != nil && [.other, .unsupported, .formatGone, .botCheck, .timedOut].contains(failure)
    }

    private func attach(_ run: EngineRun, _ gen: UInt64) -> Bool {
        guard generation.accepts(gen) else { return false }
        self.run = run
        return true
    }

    // MARK: - İndirme

    func download() {
        guard phase == .ready || phase == .failed || phase == .cancelled || phase == .finished,
              inspectedURL != nil, let plan = selectedPlan, engine != nil || (youtube != nil && youtubeInfo != nil) else { return }
        let destination = folder
        guard FileManager.default.isWritableFile(atPath: destination.path) else { return finishLocal(.writePermission) }
        let gen = generation.next()
        let base = DownloadFileNaming.baseName(title: title)
        phase = .downloading
        progress = 0
        message = nil
        savedFile = nil
        work = Task { [weak self] in
            guard let directory = await Self.prepareJobDirectory() else { self?.finish(gen, failure: .writePermission); return }
            defer { Self.discard(directory) } // yalnız bu işin geçici klasörü
            if let need = plan.estimatedBytes, Self.availableBytes(directory) < need * 2 { self?.finish(gen, failure: .diskFull); return }
            do {
                let produced = try await self?.perform(plan, directory: directory, gen: gen)
                guard let produced, self?.publishFinalizing(gen) == true else { return }
                let saved = try await Task.detached(priority: .utility) { try Self.move(produced, to: destination, base: base) }.value
                self?.finished(gen, saved: saved)
            } catch let failure as DownloadFailure {
                if self?.platform == .youtube { self?.failYouTube(gen, failure) } else { self?.finish(gen, failure: failure) }
            } catch MediaRemuxer.Failure.cancelled {
                self?.finishCancelledIfCurrent(gen)
            } catch is CancellationError {
                self?.finishCancelledIfCurrent(gen)
            } catch {
                self?.finish(gen, failure: .mergeFailed)
            }
        }
    }

    /// Görüntü + ses ayrıysa iki indirme ve passthrough birleştirme; tek akışta indirme (parçalı DASH dosyası sıradan
    /// MP4/M4A'ya taşınır); birleşik akıştan ses ya da görüntü ayırma.
    private func perform(_ plan: DownloadPlan, directory: URL, gen: UInt64) async throws -> URL? {
        switch plan.kind {
        case .single(let f):
            guard let file = try await fetch(f, role: "media", span: 0...1, directory: directory, gen: gen) else { return nil }
            guard let type = await MediaRemuxer.normalizedType(file) else { return file }
            guard publishFinalizing(gen) else { return nil }
            let output = directory.appendingPathComponent("normalized." + (type == .m4a ? "m4a" : "mp4"))
            try await remux(gen) { try await MediaRemuxer.normalize(file, type: type, to: output, handle: $0) }
            return output
        case .merge(let video, let audio):
            let total = Double((video.size ?? 0) + (audio.size ?? 0))
            let split = total > 0 ? Double(video.size ?? 0) / total : 0.85
            guard let v = try await fetch(video, role: "video", span: 0...split, directory: directory, gen: gen),
                  let a = try await fetch(audio, role: "audio", span: split...1, directory: directory, gen: gen) else { return nil }
            guard publishFinalizing(gen) else { return nil }
            let output = directory.appendingPathComponent("merged.mp4")
            try await remux(gen) { try await MediaRemuxer.merge(video: v, audio: a, to: output, handle: $0) }
            return output
        case .extractAudio(let source):
            guard let m = try await fetch(source, role: "source", span: 0...1, directory: directory, gen: gen) else { return nil }
            guard publishFinalizing(gen) else { return nil }
            let output = directory.appendingPathComponent("audio.m4a")
            try await remux(gen) { try await MediaRemuxer.extractAudio(from: m, to: output, handle: $0) }
            return output
        case .extractVideo(let source):
            guard let m = try await fetch(source, role: "source", span: 0...1, directory: directory, gen: gen) else { return nil }
            guard publishFinalizing(gen) else { return nil }
            let output = directory.appendingPathComponent("video.mp4")
            try await remux(gen) { try await MediaRemuxer.extractVideo(from: m, to: output, handle: $0) }
            return output
        }
    }

    private func fetch(_ format: MediaFormat, role: String, span: ClosedRange<Double>, directory: URL, gen: UInt64) async throws -> URL? {
        if let youtube, let info = youtubeInfo {
            return try await fetchWithEngine(format, role: role, span: span, engine: youtube, info: info, directory: directory, gen: gen)
        }
        guard generation.accepts(gen), let engine, let source = sources[format.id] else { throw DownloadFailure.formatGone }
        let file = directory.appendingPathComponent(role + "." + format.ext)
        let gate = ProgressGate()
        try await engine.fetch(source, referer: referer, to: file) { [weak self] fraction in
            // Ana iş parçacığına yalnız yayınlanacak (birleştirilmiş) değerler gelir.
            guard let value = gate.pass(span.lowerBound + (span.upperBound - span.lowerBound) * fraction) else { return }
            Task { @MainActor in self?.publishProgress(value, gen) }
        }
        guard generation.accepts(gen) else { return nil }
        return file
    }

    /// YouTube: incelemenin JSON'undan yalnız bu biçim indirilir (sayfa ve JS sınaması yeniden çözülmez).
    private func fetchWithEngine(_ format: MediaFormat, role: String, span: ClosedRange<Double>, engine: YouTubeEngine.Installation,
                                 info: Data, directory: URL, gen: UInt64) async throws -> URL? {
        let infoFile = directory.appendingPathComponent("info.json")
        if !FileManager.default.fileExists(atPath: infoFile.path) {
            try await Task.detached(priority: .utility) { try info.write(to: infoFile) }.value
        }
        let gate = ProgressGate()
        let output = directory.appendingPathComponent(role + "." + format.ext)
        let run = YouTubeEngine.download(formatID: format.id, info: infoFile, output: output, engine: engine, workingDirectory: directory) { [weak self] line in
            guard let f = DownloadProgressParser.fraction(line), let value = gate.pass(span.lowerBound + (span.upperBound - span.lowerBound) * f) else { return }
            Task { @MainActor in self?.publishProgress(value, gen) }
        }
        guard attach(run, gen) else { return nil }
        let outcome = await run.run(timeout: nil, stallTimeout: YouTubeEngine.timeouts.stall)
        guard generation.accepts(gen) else { return nil }
        self.run = nil
        if outcome.cancelled { throw MediaRemuxer.Failure.cancelled }
        if outcome.timedOut { throw DownloadFailure.timedOut }
        guard outcome.status == 0 else { throw DownloadFailure.classify(outcome.stderrTail) }
        guard FileManager.default.fileExists(atPath: output.path) else { throw DownloadFailure.other }
        return output
    }

    private func remux(_ gen: UInt64, _ body: (MediaRemuxer.Handle) async throws -> Void) async throws {
        let handle = MediaRemuxer.Handle()
        guard generation.accepts(gen) else { throw MediaRemuxer.Failure.cancelled }
        remux = handle
        defer { if remux === handle { remux = nil } }
        try await body(handle)
    }

    // MARK: - Denetim

    /// Yalnız bu özelliğin istekleri/dışa aktarması durdurulur; geçici dosyalar işin kendi temizliğiyle silinir.
    func cancel() {
        guard phase.isBusy else { return }
        let inspecting = phase == .inspecting
        _ = generation.next() // geç gelen sonuçlar artık kabul edilmez
        work?.cancel(); work = nil
        remux?.cancel(); remux = nil
        run?.cancel(); run = nil
        if inspecting { engine?.invalidate(); engine = nil } // incelenmiş bağlantının oturumu indirme için korunur
        pendingLink = nil
        finishCancelled()
    }

    /// Uygulama kapanışı: çalışan istekler kesilir, bu özelliğin geçici klasörü silinir.
    func shutdown() {
        engine?.invalidate(); engine = nil
        guard phase.isBusy else { return }
        _ = generation.next()
        work?.cancel(); work = nil
        remux?.cancel(); remux = nil
        run?.terminateSynchronously(); run = nil // arkada motor süreci kalmaz
        if let root = Self.jobRoot() { try? FileManager.default.removeItem(at: root) }
    }

    /// Formu temizler (iş sürüyorsa önce iptal).
    func reset() {
        cancel()
        _ = generation.next()
        phase = .idle
        platform = nil
        inspectedURL = nil
        engine?.invalidate(); engine = nil
        pendingLink = nil
        canUpdateEngine = false
        clearResult()
        message = nil
    }

    func chooseFolder() {
        guard !phase.isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Seç"
        NSApp.activate()
        guard (hold?.during { panel.runModal() } ?? panel.runModal()) == .OK, let url = panel.url else { return }
        folder = url
        defaults.set(url.path, forKey: folderKey)
    }

    func revealSaved() {
        guard let savedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedFile])
    }

    /// Kullanıcı isterse indirilen dosya Raf'a başvuru olarak eklenir (kopya veya taşıma yok).
    func addSavedToShelf() {
        guard let savedFile, FileManager.default.fileExists(atPath: savedFile.path) else { return }
        shelf?.add(savedFile, temporary: false)
    }

    // MARK: - Durum geçişleri

    private func publishProgress(_ value: Double, _ gen: UInt64) {
        guard generation.accepts(gen), phase == .downloading || phase == .installingEngine, progress != value else { return }
        progress = value
    }

    @discardableResult
    private func publishFinalizing(_ gen: UInt64) -> Bool {
        guard generation.accepts(gen) else { return false }
        if phase != .finalizing { phase = .finalizing; progress = nil }
        return true
    }

    private func finished(_ gen: UInt64, saved: URL) {
        guard generation.accepts(gen) else { try? FileManager.default.removeItem(at: saved); return }
        work = nil
        phase = .finished
        progress = nil
        savedFile = saved
        message = "Kaydedildi: \(saved.lastPathComponent)"
    }

    private func finish(_ gen: UInt64, failure: DownloadFailure) {
        guard generation.accepts(gen) else { return }
        finishLocal(failure)
    }

    private func finishLocal(_ failure: DownloadFailure) {
        work = nil
        phase = .failed
        progress = nil
        message = failure.message
    }

    private func finishCancelledIfCurrent(_ gen: UInt64) {
        guard generation.accepts(gen) else { return }
        finishCancelled()
    }

    private func finishCancelled() {
        work = nil
        phase = .cancelled
        progress = nil
        message = "İptal edildi."
    }

    private func fail(_ text: String) {
        phase = .failed
        progress = nil
        message = text
    }

    private func fail(_ gen: UInt64, _ text: String) {
        guard generation.accepts(gen) else { return }
        work = nil
        fail(text)
    }

    private func clearResult() {
        title = nil
        videoOptions = []
        videoOnlyOptions = []
        audioPlan = nil
        hasAudio = false
        sources = [:]
        referer = nil
        youtubeInfo = nil
        tier = nil
        progress = nil
        savedFile = nil
    }

    // MARK: - Dosya sistemi (ana iş parçacığı dışında da çağrılabilir)

    nonisolated private static func prepareJobDirectory() async -> URL? {
        await Task.detached(priority: .utility) { makeJobDirectory() }.value
    }

    nonisolated private static func discard(_ directory: URL) {
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
    }

    /// Tek iş tasarımı: önceki (ör. çökmeyle yarım kalmış) iş klasörleri yalnız bu özelliğin kendi klasöründen silinir.
    nonisolated private static func jobRoot() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if environment["OPENISLAND_DIAGNOSTICS"] != nil, environment["OPENISLAND_TEST_SUPPORT"] != nil {
            return AppPaths.support.appendingPathComponent("LinkDownloads", isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent((Bundle.main.bundleIdentifier ?? "io.github.openisland") + "/LinkDownloads", isDirectory: true)
    }

    nonisolated private static func makeJobDirectory() -> URL? {
        guard let root = jobRoot() else { return nil }
        let fm = FileManager.default
        for stale in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: stale) }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) } catch { return nil }
        return directory
    }

    nonisolated private static func availableBytes(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
    }

    /// Hedefte var olan dosya ezilmez; uzantı üretilen dosyanın gerçek uzantısıdır.
    nonisolated private static func move(_ file: URL, to folder: URL, base: String) throws -> URL {
        let fm = FileManager.default
        guard let name = DownloadFileNaming.uniqueName(base: base, ext: file.pathExtension, exists: {
            fm.fileExists(atPath: folder.appendingPathComponent($0).path)
        }) else { throw DownloadFailure.writePermission }
        let target = folder.appendingPathComponent(name)
        do {
            try fm.moveItem(at: file, to: target)
        } catch let error as CocoaError {
            switch error.code {
            case .fileWriteOutOfSpace: throw DownloadFailure.diskFull
            case .fileWriteNoPermission, .fileWriteVolumeReadOnly: throw DownloadFailure.writePermission
            case .fileWriteFileExists: throw DownloadFailure.writePermission
            default: throw DownloadFailure.other
            }
        }
        return target
    }
}

/// Motor çıktısı iş parçacığında ilerleme birleştirme: ana iş parçacığına saniyede birkaç güncellemeden fazlası gitmez.
private final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last: (value: Double, at: Date)?

    func pass(_ value: Double) -> Double? {
        lock.withLock {
            let now = Date()
            guard DownloadProgressParser.shouldPublish(value, last: last?.value,
                                                       elapsedSinceLast: last.map { now.timeIntervalSince($0.at) } ?? .infinity) else { return nil }
            last = (value, now)
            return value
        }
    }
}
