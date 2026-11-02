import CryptoKit
import Darwin
import Foundation
import IslandCore
import Security

/// İsteğe bağlı YouTube motoru: yt-dlp (klasör sürümü, yalnız bu Mac'in mimarisi) + QuickJS (YouTube'un JS sınamasını
/// çözer). Uygulama paketinde yoktur; yalnız kullanıcı ilk YouTube bağlantısında onay verince GitHub sürüm sayfasından
/// indirilir ve SHA-256 özeti eşleşmeden kurulmaz. Yalnız İncele/İndir sırasında, ayrı süreçte çalışır; boştayken
/// süreç, zamanlayıcı veya ağ isteği yoktur. Güncelleme yalnız kullanıcı başlatınca yapılır.
enum YouTubeEngine {
    struct Installation: Sendable {
        var downloader: URL
        var quickJS: URL
        var manifest: YouTubeEngineManifest
    }

    enum Failure: Error { case download, digest, unpack, verify }

    /// `<destek>/Engines/YouTube`; yalıtılmış geliştirici koşusunda fikstürün destek klasörü (AppPaths kuralı).
    static var directory: URL { AppPaths.support.appendingPathComponent("Engines/YouTube", isDirectory: true) }
    private static var enginesRoot: URL { directory.deletingLastPathComponent() }

    /// İndirilecek (sıkıştırılmış) ve kurulunca diskte kaplayacak yaklaşık boyut; onay metninde gösterilir.
    static let downloadBytes: Int64 = YouTubeEnginePin.downloader.size + YouTubeEnginePin.quickJS.size
    static let installedBytes: Int64 = 72_000_000 // ölçülen: 71,5 MB (arm64, 2026.10.26)

    static let timeouts: (inspect: TimeInterval, stall: TimeInterval) = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENISLAND_DIAGNOSTICS"] != nil, environment["OPENISLAND_TEST_ROOT"] != nil,
              let parts = environment["OPENISLAND_TEST_DOWNLOAD_TIMEOUTS"]?.split(separator: ",").compactMap({ Double($0) }),
              parts.count == 2 else { return (90, 90) }
        return (parts[0], parts[1])
    }()

    #if arch(arm64)
    private static let hostCPU = MachOFat.arm64
    #else
    private static let hostCPU = MachOFat.x86_64
    #endif

    // MARK: - Kurulu motor

    /// Kurulu ve imzası geçerli motor; yoksa nil. Dosya sistemi ve imza denetimi yapar: ana iş parçacığında çağrılmaz.
    static func installed() -> Installation? {
        let root = directory
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let manifest = try? decoder.decode(YouTubeEngineManifest.self, from: data) else { return nil }
        let downloader = root.appendingPathComponent("yt-dlp/yt-dlp_macos"), quickJS = root.appendingPathComponent("qjs")
        guard [downloader, quickJS].allSatisfy({ isRegularExecutable($0.path) && hasValidSignature($0) }) else { return nil }
        return Installation(downloader: downloader, quickJS: quickJS, manifest: manifest)
    }

    // MARK: - Çalıştırma

    private static func common(_ engine: Installation) -> [String] {
        // Kullanıcının yt-dlp yapılandırması, önbelleği ve uzak bileşen indirmesi kullanılmaz; JS yalnız paketteki QuickJS.
        ["--ignore-config", "--no-playlist", "--no-cache-dir", "--no-update", "--no-warnings", "--no-remote-components",
         "--no-js-runtimes", "--js-runtimes", "quickjs:" + engine.quickJS.path,
         "--socket-timeout", "20", "--retries", "3", "--fragment-retries", "3", "--extractor-retries", "2"]
    }

    /// Tek inceleme: biçim listesi ve çözülmüş akış adresleri (JSON). Bağlantı `--` sonrasında tek argümandır.
    static func inspection(_ url: URL, engine: Installation, workingDirectory: URL) -> EngineRun {
        EngineRun(executable: engine.downloader, arguments: common(engine) + ["--skip-download", "--dump-single-json", "--", url.absoluteString],
                  workingDirectory: workingDirectory, collectStdout: true)
    }

    /// İncelemenin kaydedilmiş JSON'undan tek biçimin indirilmesi: YouTube sayfası ve JS sınaması yeniden çözülmez.
    static func download(formatID: String, info: URL, output: URL, engine: Installation, workingDirectory: URL,
                         onLine: @escaping @Sendable (Substring) -> Void) -> EngineRun {
        let template = "download:OIPROG %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s"
        let arguments = common(engine) + ["--newline", "--progress", "--progress-template", template, "--no-mtime",
                                          "--load-info-json", info.path, "-f", formatID, "-o", output.path]
        return EngineRun(executable: engine.downloader, arguments: arguments, workingDirectory: workingDirectory,
                         collectStdout: false, onLine: onLine)
    }

    // MARK: - Kurulum ve güncelleme

    /// GitHub'daki son sürümler (yalnız güncellemede, kullanıcı isteyince). Özet bildirmeyen sürüm kabul edilmez.
    static func latest(session: URLSession) async throws -> (EngineComponent, EngineComponent) {
        func fetch(_ url: URL, asset: String, repository: String) async throws -> EngineComponent {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4 << 20,
                  let component = EngineRelease.component(fromLatest: data, asset: asset, repository: repository) else { throw Failure.download }
            return component
        }
        async let downloader = fetch(YouTubeEnginePin.downloaderRelease, asset: YouTubeEnginePin.downloaderAsset, repository: "yt-dlp/yt-dlp")
        async let quickJS = fetch(YouTubeEnginePin.quickJSRelease, asset: YouTubeEnginePin.quickJSAsset, repository: "quickjs-ng/quickjs")
        return try await (downloader, quickJS)
    }

    /// İndir → özet → aç → yalnız bu mimari → imza → deneme çalıştırması → yerine koy. Bir adım başarısızsa kurulu motora
    /// dokunulmaz ve ara klasör silinir. İptal görev iptalidir. `progress` 0…1, arka planda çağrılır.
    static func install(downloader: EngineComponent, quickJS: EngineComponent, session: URLSession,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Installation {
        let fm = FileManager.default
        let root = enginesRoot
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for stale in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where stale.lastPathComponent.hasPrefix(".staging-") {
            try? fm.removeItem(at: stale) // yarım kalmış önceki kurulum
        }
        let stage = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        do {
            let total = Double(downloader.size + quickJS.size)
            let zip = stage.appendingPathComponent("yt-dlp.zip"), qjs = stage.appendingPathComponent("engine/qjs")
            try await fetch(downloader, to: zip, session: session) { progress(0.9 * $0 * Double(downloader.size) / total) }
            try fm.createDirectory(at: qjs.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await fetch(quickJS, to: qjs, session: session) { progress(0.9 * (Double(downloader.size) + $0 * Double(quickJS.size)) / total) }
            try Task.checkCancellation()
            let unpacked = stage.appendingPathComponent("engine/yt-dlp", isDirectory: true)
            try await unzip(zip, to: unpacked)
            try? fm.removeItem(at: zip)
            try await Task.detached(priority: .utility) { try thin(unpacked) }.value
            chmod(qjs.path, 0o755)
            let manifest = YouTubeEngineManifest(downloader: downloader, quickJS: quickJS, installedAt: Date())
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: stage.appendingPathComponent("engine/manifest.json"))
            let candidate = Installation(downloader: unpacked.appendingPathComponent("yt-dlp_macos"), quickJS: qjs, manifest: manifest)
            progress(0.95)
            // İlk çalıştırmada macOS yeni kodu tarar (~7 sn); bu, ilk incelemede değil kurulumda olur.
            try await verify(candidate, workingDirectory: stage)
            try Task.checkCancellation()
            let old = root.appendingPathComponent(".staging-old-" + UUID().uuidString)
            if fm.fileExists(atPath: directory.path) { try fm.moveItem(at: directory, to: old) }
            do { try fm.moveItem(at: stage.appendingPathComponent("engine"), to: directory) } catch {
                if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: directory) }
                throw Failure.unpack
            }
            try? fm.removeItem(at: old)
            try? fm.removeItem(at: stage)
            progress(1)
            guard let installed = installed() else { throw Failure.verify }
            return installed
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }
    }

    private static func fetch(_ component: EngineComponent, to file: URL, session: URLSession,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let box = TransferBox()
        let location: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: component.url) { location, response, error in
                    if let error = error as? URLError {
                        return continuation.resume(throwing: error.code == .cancelled ? CancellationError() : NativeEngine.failure(error))
                    }
                    guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else { return continuation.resume(throwing: Failure.download) }
                    // Geçici dosya bu blok bitince silinir: hemen ara klasöre alınır.
                    let kept = file.deletingLastPathComponent().appendingPathComponent(".download-" + UUID().uuidString)
                    do { try FileManager.default.moveItem(at: location, to: kept); continuation.resume(returning: kept) }
                    catch { continuation.resume(throwing: DownloadFailure.diskFull) }
                }
                box.observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
                box.task = task
                task.resume()
            }
        } onCancel: { box.task?.cancel() }
        box.observation = nil
        let digest = try await Task.detached(priority: .utility) { try sha256(of: location) }.value
        let size = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        guard digest == component.sha256, size == component.size else {
            try? FileManager.default.removeItem(at: location)
            throw Failure.digest
        }
        try FileManager.default.moveItem(at: location, to: file)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Sistem `ditto` aracı (her macOS'ta /usr/bin altında); zip içeriği yalnız hedef klasöre açılır.
    private static func unzip(_ zip: URL, to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let run = EngineRun(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", zip.path, folder.path],
                            workingDirectory: folder.deletingLastPathComponent(), collectStdout: false)
        let outcome = await run.run(timeout: 300, stallTimeout: nil)
        guard outcome.status == 0, !outcome.cancelled, !outcome.timedOut else { throw Failure.unpack }
        // Beklenen düzen: yt-dlp_macos + _internal/. Sembolik bağ ana çalıştırılabilir olamaz.
        guard isRegularExecutable(folder.appendingPathComponent("yt-dlp_macos").path) else { throw Failure.unpack }
    }

    /// Evrensel (x86_64 + arm64) Mach-O dosyalarında yalnız bu Mac'in dilimi kalır: 124 MB → ~65 MB. Dilim kendi imzasını
    /// taşır; sembolik bağlar ve evrensel olmayan dosyalar olduğu gibi kalır.
    private static func thin(_ folder: URL) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw Failure.unpack }
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let prefix = (try? handle.read(upToCount: 8)) ?? Data()
            try? handle.close()
            guard MachOFat.isFat(prefix) else { continue }
            guard let slice = MachOFat.slice(try Data(contentsOf: file), cpuType: hostCPU) else { throw Failure.unpack }
            let mode = ((try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber)?.int16Value ?? 0o644
            try slice.write(to: file, options: .atomic)
            chmod(file.path, mode_t(mode))
        }
    }

    /// İmza, sürüm ve QuickJS'in çalıştığı denenir.
    private static func verify(_ engine: Installation, workingDirectory: URL) async throws {
        guard [engine.downloader, engine.quickJS].allSatisfy({ isRegularExecutable($0.path) && hasValidSignature($0) }) else { throw Failure.verify }
        let version = EngineRun(executable: engine.downloader, arguments: ["--ignore-config", "--no-update", "--version"],
                                workingDirectory: workingDirectory, collectStdout: true)
        let v = await version.run(timeout: 120, stallTimeout: nil)
        let reported = String(decoding: v.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.status == 0, reported == engine.manifest.downloader.version else { throw Failure.verify }
        let js = EngineRun(executable: engine.quickJS, arguments: ["-e", "print(6*7)"], workingDirectory: workingDirectory, collectStdout: true)
        let j = await js.run(timeout: 30, stallTimeout: nil)
        guard j.status == 0, String(decoding: j.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "42" else { throw Failure.verify }
    }

    private static func isRegularExecutable(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false } // sembolik bağ değil
        return access(path, X_OK) == 0
    }

    private static func hasValidSignature(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
    }
}

private final class TransferBox: @unchecked Sendable {
    var task: URLSessionDownloadTask?
    var observation: NSKeyValueObservation?
}
