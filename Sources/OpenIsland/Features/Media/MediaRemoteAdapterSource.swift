import Foundation

/// macOS 15.4+ için web oynatıcı dahil sistem geneli "Şimdi Çalıyor" kaynağı.
///
/// [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3) Apple imzalı
/// `/usr/bin/perl` (bundle ID `com.apple.perl*`) içinde küçük bir framework yükler; MediaRemote bu
/// süreci yetkili sayar. Adapter `stream` modunda satır başına bir JSON yazar:
/// `{"type":"data","diff":true,"payload":{...}}`. Paketleme: `Vendor/MediaRemoteAdapter/`
/// altına `mediaremote-adapter.pl` ve `MediaRemoteAdapter.framework` koyun (bkz. README).
@MainActor
final class MediaRemoteAdapterSource: MediaSource {
    struct Paths {
        let script: URL
        let framework: URL
    }

    let id = "mediaremote-adapter"
    let isSystemWide = true
    var onUpdate: ((NowPlayingInfo?) -> Void)?

    private let paths: Paths
    private var process: Process?
    private var buffer = Data()
    private var payload: [String: Any] = [:]
    private var isStopping = false
    private var restartAttempts = 0
    private var restartTask: Task<Void, Never>?
    private var streamHandle: FileHandle?
    private var generation: UInt64 = 0

    init(paths: Paths) {
        self.paths = paths
    }

    static func bundledPaths() -> Paths? {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter") else { return nil }
        let script = base.appendingPathComponent("mediaremote-adapter.pl")
        let framework = base.appendingPathComponent("MediaRemoteAdapter.framework")
        let fm = FileManager.default
        guard fm.fileExists(atPath: script.path), fm.fileExists(atPath: framework.path) else { return nil }
        return Paths(script: script, framework: framework)
    }

    func start() {
        guard process == nil else { return }
        isStopping = false
        restartTask?.cancel(); restartTask = nil
        generation &+= 1
        let token = generation
        let process = makeProcess(arguments: ["stream"])
        let pipe = Pipe()
        process.standardOutput = pipe
        streamHandle = pipe.fileHandleForReading
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            // DispatchQueue.main FIFO garantisi verir; JSON satırlarının sırası korunur.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.isStopping, self.generation == token else { return }
                    self.ingest(chunk)
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.processDidExit(token: token) }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            streamHandle?.readabilityHandler = nil
            streamHandle = nil
            process.terminationHandler = nil
            NSLog("[OpenIsland] mediaremote-adapter başlatılamadı: \(error)")
        }
    }

    func stop() {
        isStopping = true
        generation &+= 1
        restartTask?.cancel(); restartTask = nil
        streamHandle?.readabilityHandler = nil
        streamHandle = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        buffer.removeAll()
        payload.removeAll()
    }

    func perform(_ command: MediaCommand) {
        run(["send", String(command.rawValue)])
    }

    /// Adapter komutu çıkış koduyla bildirir; 0 dışı (desteklenmeyen oynatıcı, hata) başarısızdır.
    func seek(to time: TimeInterval) async -> Bool {
        await runAndWait(["seek", String(Int64(time * 1_000_000))]) // mikro saniye
    }

    // MARK: - Private

    private func makeProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script.path, paths.framework.path] + arguments
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        return process
    }

    private func run(_ arguments: [String]) {
        let process = makeProcess(arguments: arguments)
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
    }

    private func runAndWait(_ arguments: [String]) async -> Bool {
        let process = makeProcess(arguments: arguments)
        process.standardOutput = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }

    func recover() {
        restartAttempts = 0
        if process == nil, !isStopping { start() }
    }

    private func processDidExit(token: UInt64) {
        guard !isStopping, token == generation else { return }
        streamHandle?.readabilityHandler = nil
        streamHandle = nil
        buffer.removeAll()
        process = nil
        guard !isStopping, restartAttempts < 5 else { return }
        restartAttempts += 1
        let delay = Double(restartAttempts) * 2
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.isStopping, self.generation == token else { return }
            self.restartTask = nil
            self.start()
        }
    }

    private func ingest(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        restartAttempts = 0
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handleLine(Data(line))
        }
    }

    private func handleLine(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "data" else { return }

        guard let incoming = object["payload"] as? [String: Any] else {
            payload = [:] // `payload: null` → hiçbir şey çalmıyor
            onUpdate?(nil)
            return
        }
        if object["diff"] as? Bool == true {
            for (key, value) in incoming {
                if value is NSNull { payload.removeValue(forKey: key) } else { payload[key] = value }
            }
        } else {
            payload = incoming
        }
        onUpdate?(Self.parse(payload))
    }

    static func parse(_ payload: [String: Any]) -> NowPlayingInfo? {
        guard let title = payload["title"] as? String, !title.isEmpty else { return nil }
        let playing = payload["playing"] as? Bool ?? false
        return NowPlayingInfo(
            title: title,
            artist: payload["artist"] as? String ?? "",
            album: payload["album"] as? String ?? "",
            duration: payload["duration"] as? Double ?? 0,
            elapsed: payload["elapsedTime"] as? Double ?? 0,
            timestamp: parseDate(payload["timestamp"]) ?? Date(),
            playbackRate: payload["playbackRate"] as? Double ?? (playing ? 1 : 0),
            isPlaying: playing,
            artworkData: (payload["artworkData"] as? String).flatMap { Data(base64Encoded: $0) },
            // Web oynatıcılarda çalan süreç tarayıcının yardımcısı olabilir; öne getirilecek olan üst uygulamadır.
            bundleIdentifier: payload["parentApplicationBundleIdentifier"] as? String ?? payload["bundleIdentifier"] as? String
        )
    }

    /// Zaman damgası ISO-8601 metni veya epoch saniyesi olarak gelebilir.
    private static func parseDate(_ value: Any?) -> Date? {
        switch value {
        case let seconds as Double:
            return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
        case let text as String:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        default:
            return nil
        }
    }
}
