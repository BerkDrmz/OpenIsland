import AppKit
import IslandCore

/// "Bağlantıdan indir" koordinatörü. Yalnız kullanıcının "İncele"/"İndir" basışıyla çalışır; boştayken süreç,
/// zamanlayıcı, pano izleme veya ağ isteği yoktur. Aynı anda tek iş vardır. Her iş yeni bir kuşak alır; iptal edilen
/// veya yerini yenisine bırakan işin geç gelen sonucu durumu değiştirmez. Panel kapanması işi iptal etmez.
@MainActor
@Observable
final class LinkDownloader {
    private(set) var phase: LinkDownloadPhase = .idle
    private(set) var platform: LinkPlatform?
    private(set) var title: String?
    private(set) var videoOptions: [QualityOption] = []
    private(set) var audioPlan: DownloadPlan?
    private(set) var hasAudio = false
    var mode: DownloadMode = .videoWithAudio
    var tier: QualityTier?
    private(set) var folder: URL
    /// 0…1; bilinmiyorsa nil.
    private(set) var progress: Double?
    private(set) var message: String?
    private(set) var savedFile: URL?

    @ObservationIgnored var hold: IslandHold?
    @ObservationIgnored var shelf: ShelfStore?
    @ObservationIgnored private var generation = DownloadGeneration()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var run: EngineRun?
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
        case .videoWithAudio: videoOptions.first { $0.tier == tier }?.plan
        }
    }

    // MARK: - İnceleme

    func inspect(_ text: String) {
        guard !phase.isBusy else { return } // art arda basış ikinci işi başlatmaz
        inspectedURL = nil
        clearResult()
        let url: URL
        switch LinkDownloadRules.validate(text) {
        case .invalid: return fail("Geçerli bir http(s) bağlantısı yapıştırın.")
        case .unsupportedPlatform: return fail("Yalnız Facebook, X ve TikTok video bağlantıları destekleniyor.")
        case .valid(let u, let p): url = u; platform = p
        }
        guard let engine = DownloadEngine.executable() else { return fail(DownloadFailure.engineMissing.message) }
        let gen = generation.next()
        phase = .inspecting
        message = nil
        work = Task { [weak self] in
            guard let directory = await Self.prepareJobDirectory() else { self?.finish(gen, failure: .writePermission); return }
            defer { Self.discard(directory) }
            let run = EngineRun(executable: engine, arguments: Self.common + ["--skip-download", "--dump-single-json", "--", url.absoluteString],
                                workingDirectory: directory, collectStdout: true)
            guard self?.attach(run, gen) == true else { return }
            let outcome = await run.run(timeout: DownloadEngine.timeouts.inspect, stallTimeout: nil)
            self?.inspected(gen, url: url, outcome: outcome)
        }
    }

    private func inspected(_ gen: UInt64, url: URL, outcome: EngineRun.Outcome) {
        guard generation.accepts(gen) else { return }
        run = nil; work = nil
        if outcome.cancelled { return finishCancelled() }
        if outcome.timedOut { return finish(gen, failure: .timedOut) }
        guard outcome.status == 0, !outcome.stdoutOverflow,
              let info = try? JSONDecoder().decode(MediaInfo.self, from: outcome.stdout) else {
            return finish(gen, failure: DownloadFailure.classify(outcome.stderrTail))
        }
        guard info.isSingleVideo else { return fail("Oynatma listesi ve profil indirmesi desteklenmiyor; tek bir video bağlantısı verin.") }
        videoOptions = DownloadPlanner.videoOptions(info.formats)
        audioPlan = DownloadPlanner.audioPlan(info.formats)
        hasAudio = DownloadPlanner.hasAudio(info.formats)
        guard !videoOptions.isEmpty || audioPlan != nil else { return finish(gen, failure: .unsupported) }
        inspectedURL = url
        title = info.title
        tier = videoOptions.first(where: \.isAvailable)?.tier
        if videoOptions.allSatisfy({ !$0.isAvailable }) { mode = .audioOnly } else if mode == .audioOnly && audioPlan == nil { mode = .videoWithAudio }
        phase = .ready
        message = hasAudio ? nil : "Bu videoda ses yok."
    }

    // MARK: - İndirme

    func download() {
        guard phase == .ready || phase == .failed || phase == .cancelled || phase == .finished,
              let url = inspectedURL, let plan = selectedPlan else { return }
        guard let engine = DownloadEngine.executable() else { return fail(DownloadFailure.engineMissing.message) }
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
                let produced = try await self?.perform(plan, url: url, engine: engine, directory: directory, gen: gen)
                guard let produced, self?.publishFinalizing(gen) == true else { return }
                let saved = try await Task.detached(priority: .utility) { try Self.move(produced, to: destination, base: base) }.value
                self?.finished(gen, saved: saved)
            } catch let failure as DownloadFailure {
                self?.finish(gen, failure: failure)
            } catch MediaRemuxer.Failure.cancelled {
                self?.finishCancelledIfCurrent(gen)
            } catch {
                self?.finish(gen, failure: .mergeFailed)
            }
        }
    }

    /// Görüntü + ses ayrıysa iki indirme ve passthrough birleştirme; tek akışta indirme; birleşik akıştan ses ayırma.
    private func perform(_ plan: DownloadPlan, url: URL, engine: URL, directory: URL, gen: UInt64) async throws -> URL? {
        switch plan.kind {
        case .single(let f):
            return try await fetch(f, role: "media", span: 0...1, url: url, engine: engine, directory: directory, gen: gen)
        case .merge(let video, let audio):
            let total = Double((video.size ?? 0) + (audio.size ?? 0))
            let split = total > 0 ? Double(video.size ?? 0) / total : 0.85
            guard let v = try await fetch(video, role: "video", span: 0...split, url: url, engine: engine, directory: directory, gen: gen),
                  let a = try await fetch(audio, role: "audio", span: split...1, url: url, engine: engine, directory: directory, gen: gen) else { return nil }
            guard publishFinalizing(gen) else { return nil }
            let output = directory.appendingPathComponent("merged.mp4")
            try await remux(gen) { try await MediaRemuxer.merge(video: v, audio: a, to: output, handle: $0) }
            return output
        case .extractAudio(let source):
            guard let m = try await fetch(source, role: "source", span: 0...1, url: url, engine: engine, directory: directory, gen: gen) else { return nil }
            guard publishFinalizing(gen) else { return nil }
            let output = directory.appendingPathComponent("audio.m4a")
            try await remux(gen) { try await MediaRemuxer.extractAudio(from: m, to: output, handle: $0) }
            return output
        }
    }

    private func fetch(_ format: MediaFormat, role: String, span: ClosedRange<Double>, url: URL, engine: URL,
                       directory: URL, gen: UInt64) async throws -> URL? {
        let template = "download:OIPROG %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s"
        let arguments = Self.common + ["--newline", "--progress", "--progress-template", template, "--no-mtime",
                                       "-f", format.id, "-o", directory.path + "/" + role + ".%(ext)s", "--", url.absoluteString]
        let gate = ProgressGate()
        let run = EngineRun(executable: engine, arguments: arguments, workingDirectory: directory, collectStdout: false) { [weak self] line in
            guard let f = DownloadProgressParser.fraction(line) else { return }
            // Birleştirme arka planda yapılır; ana iş parçacığına yalnız yayınlanacak değerler gelir.
            guard let value = gate.pass(span.lowerBound + (span.upperBound - span.lowerBound) * f) else { return }
            Task { @MainActor in self?.publishProgress(value, gen) }
        }
        guard attach(run, gen) else { return nil }
        let outcome = await run.run(timeout: nil, stallTimeout: DownloadEngine.timeouts.stall)
        guard generation.accepts(gen) else { return nil }
        self.run = nil
        if outcome.cancelled { throw MediaRemuxer.Failure.cancelled }
        if outcome.timedOut { throw DownloadFailure.timedOut }
        guard outcome.status == 0 else { throw DownloadFailure.classify(outcome.stderrTail) }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard let file = files.first(where: { $0.lastPathComponent.hasPrefix(role + ".") && !$0.lastPathComponent.hasSuffix(".part") }) else {
            throw DownloadFailure.other
        }
        return file
    }

    private func remux(_ gen: UInt64, _ body: (MediaRemuxer.Handle) async throws -> Void) async throws {
        let handle = MediaRemuxer.Handle()
        guard generation.accepts(gen) else { throw MediaRemuxer.Failure.cancelled }
        remux = handle
        defer { if remux === handle { remux = nil } }
        try await body(handle)
    }

    // MARK: - Denetim

    /// Yalnız bu özelliğin başlattığı süreç/dışa aktarma durdurulur; geçici dosyalar işin kendi temizliğiyle silinir.
    func cancel() {
        guard phase.isBusy else { return }
        _ = generation.next() // geç gelen sonuçlar artık kabul edilmez
        run?.cancel(); run = nil
        remux?.cancel(); remux = nil
        work = nil
        finishCancelled()
    }

    /// Uygulama kapanışı: çalışan motor beklenerek durdurulur, bu özelliğin geçici klasörü silinir.
    func shutdown() {
        guard phase.isBusy else { return }
        _ = generation.next()
        run?.terminateSynchronously(); run = nil
        remux?.cancel(); remux = nil
        work = nil
        if let root = Self.jobRoot() { try? FileManager.default.removeItem(at: root) }
    }

    /// Formu temizler (iş sürüyorsa önce iptal).
    func reset() {
        cancel()
        _ = generation.next()
        phase = .idle
        platform = nil
        inspectedURL = nil
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

    private func attach(_ run: EngineRun, _ gen: UInt64) -> Bool {
        guard generation.accepts(gen) else { return false }
        self.run = run
        return true
    }

    private func publishProgress(_ value: Double, _ gen: UInt64) {
        guard generation.accepts(gen), phase == .downloading, progress != value else { return }
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
        run = nil; work = nil
        phase = .failed
        progress = nil
        message = failure.message
    }

    private func finishCancelledIfCurrent(_ gen: UInt64) {
        guard generation.accepts(gen) else { return }
        finishCancelled()
    }

    private func finishCancelled() {
        run = nil; work = nil
        phase = .cancelled
        progress = nil
        message = "İptal edildi."
    }

    private func fail(_ text: String) {
        phase = .failed
        progress = nil
        message = text
    }

    private func clearResult() {
        title = nil
        videoOptions = []
        audioPlan = nil
        hasAudio = false
        tier = nil
        progress = nil
        savedFile = nil
    }

    // MARK: - Dosya sistemi (ana iş parçacığı dışında da çağrılabilir)

    nonisolated private static let common = [
        "--ignore-config", "--no-playlist", "--no-cache-dir", "--no-update", "--no-warnings",
        "--socket-timeout", "20", "--retries", "3", "--fragment-retries", "3", "--extractor-retries", "2",
    ]

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
