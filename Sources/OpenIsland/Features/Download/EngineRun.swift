import Darwin
import Foundation
import IslandCore

/// Tek bir motor çalıştırması (YouTube motoru, `YouTubeEngine`). Süreç kabuk olmadan, ayrı argümanlarla, kendi süreç
/// grubunda ve düşük öncelikte (utility QoS: arayüz iş parçacığıyla yarışmaz) başlar (`posix_spawn`);
/// uygulamanın diğer dosya tanımlayıcıları devralınmaz. Çıktılar arka planda, sınırlı tamponlarla tüketilir; süre ve
/// takılma denetimi yalnız süreç çalışırken vardır. Bitişte, iptalde ve zaman aşımında yalnız bu çalıştırmanın süreç
/// ağacı sonlandırılır (motorun bırakabileceği veya başka gruba aldığı alt süreçler dahil); genel `killall` yoktur.
final class EngineRun: @unchecked Sendable {
    struct Outcome: Sendable {
        var status: Int32
        var stdout: Data
        var stderrTail: String
        var timedOut: Bool
        var cancelled: Bool
        var stdoutOverflow: Bool
    }

    private let executable: URL
    private let arguments: [String]
    private let workingDirectory: URL
    private let environment: [String: String]
    private let queue = DispatchQueue(label: "openisland.link-download.engine")
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var exited = false
    private var stdout = Data()
    private var stderr = Data()
    private var pendingLine = Data()
    private var lastActivity = Date()
    private var cancelled = false
    private var timedOut = false
    private var overflow = false
    private let collectStdout: Bool
    private let onLine: (@Sendable (Substring) -> Void)?
    private static let stdoutLimit = 32 << 20
    private static let stderrLimit = 16 << 10

    init(executable: URL, arguments: [String], workingDirectory: URL, collectStdout: Bool,
         onLine: (@Sendable (Substring) -> Void)? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.collectStdout = collectStdout
        self.onLine = onLine
        let home = workingDirectory.appendingPathComponent(".home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Kullanıcının ~/.netrc, ~/.config/yt-dlp, çerez ve Python ayarları devralınmaz; ortam tamamen bu sözlüktür.
        environment = [
            "PATH": "/usr/bin:/bin", "HOME": home.path, "TMPDIR": workingDirectory.path + "/",
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path, "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path,
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
        ]
    }

    // Yalnız `queue` üzerinde erişilir.
    private var status: Int32 = -1
    private var openStreams = 0
    private var reported = false
    private var report: (@Sendable (Outcome) -> Void)?
    private var readers: [DispatchSourceRead] = []
    private var watchdog: DispatchSourceTimer?
    /// Görülen süreç ağacı (pid → başlangıç zamanı). Motor alt süreçlerini başka bir gruba alabilir (ör. Python
    /// başlatıcıları); bunlar da sonlandırılır. Başlangıç zamanı eşleşmeyen (numarası yeniden kullanılmış) süreç atlanır.
    private var known: [pid_t: ProcessStart] = [:]

    /// `timeout`: toplam süre (inceleme); `stallTimeout`: hiç çıktı gelmeden geçebilecek en uzun süre (indirme).
    func run(timeout: TimeInterval?, stallTimeout: TimeInterval?) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            queue.async { self.start(timeout: timeout, stallTimeout: stallTimeout) { continuation.resume(returning: $0) } }
        }
    }

    private func start(timeout: TimeInterval?, stallTimeout: TimeInterval?, done: @escaping @Sendable (Outcome) -> Void) {
        var out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { return done(outcome()) }
        guard pipe(&err) == 0 else { close(out[0]); close(out[1]); return done(outcome()) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)
        // Kendi süreç grubu (pgid = pid); yalnız 0/1/2 devralınır. Uygulamanın yok saydığı sinyaller (SIGTERM, SIGPIPE)
        // ve sinyal maskesi devralınmaz: motor iptalde SIGTERM ile kapanabilir.
        var defaults = sigset_t(), empty = sigset_t()
        sigfillset(&defaults); sigemptyset(&empty)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &empty)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_set_qos_class_np(&attributes, QOS_CLASS_UTILITY)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        var child: pid_t = 0
        let spawned = posix_spawn(&child, executable.path, &actions, &attributes, argv, envp)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        argv.forEach { free($0) }
        envp.forEach { free($0) }
        close(out[1]); close(err[1])
        guard spawned == 0 else { close(out[0]); close(err[0]); return done(outcome()) }
        report = done
        let alreadyCancelled = lock.withLock { pid = child; lastActivity = Date(); return cancelled }
        known = [:]
        track(child)
        if alreadyCancelled { signalKnown(SIGKILL) }

        openStreams = 2
        for (fd, isOut) in [(out[0], true), (err[0], false)] {
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                var buffer = [UInt8](repeating: 0, count: 65_536)
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    let data = Data(buffer[0..<n])
                    if isOut { self?.consumeStdout(data) } else { self?.consumeStderr(data) }
                } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                    source.cancel()
                }
            }
            source.setCancelHandler { [weak self] in
                close(fd)
                guard let self else { return }
                self.openStreams -= 1
                self.finishIfComplete()
            }
            readers.append(source)
            source.resume()
        }
        let exitSource = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        exitSource.setEventHandler { [weak self] in
            exitSource.cancel()
            guard let self else { return }
            var raw: Int32 = 0
            waitpid(child, &raw, 0)
            self.status = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : -1
            self.lock.withLock { self.exited = true }
            self.watchdog?.cancel(); self.watchdog = nil
            // Lider bitti: ağaçta kalan her şey (ör. motorun bıraktığı alt süreç) sonlandırılır; boruyu açık tutan
            // kaçak bir süreç olsa bile sonuç en çok 2 sn içinde bildirilir.
            self.track(child)
            let targets = self.signalKnown(SIGTERM)
            self.queue.asyncAfter(deadline: .now() + 1) { Self.signal(targets, SIGKILL) }
            self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.readers.forEach { $0.cancel() } }
            self.finishIfComplete()
        }
        exitSource.resume()
        // Zaman aşımı/takılma denetimi yalnız süreç çalışırken.
        guard timeout != nil || stallTimeout != nil else { return }
        let started = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.track(child)
            let idle = self.lock.withLock { Date().timeIntervalSince(self.lastActivity) }
            if let timeout, Date().timeIntervalSince(started) > timeout { self.stop(timedOut: true) }
            else if let stallTimeout, idle > stallTimeout { self.stop(timedOut: true) }
        }
        watchdog = timer
        timer.resume()
    }

    private func finishIfComplete() {
        guard !reported, openStreams == 0, lock.withLock({ exited }) else { return }
        reported = true
        readers.removeAll()
        report?(outcome())
        report = nil
    }

    private func outcome() -> Outcome {
        let code = status
        return lock.withLock {
            Outcome(status: code, stdout: stdout, stderrTail: String(decoding: stderr, as: UTF8.self),
                    timedOut: timedOut, cancelled: cancelled, stdoutOverflow: overflow)
        }
    }

    func cancel() { stop(timedOut: false) }

    /// Uygulama kapanırken: grup beklenerek sonlandırılır (en çok ~1 sn), arkada süreç kalmaz.
    func terminateSynchronously() {
        let leader = lock.withLock { () -> pid_t in cancelled = true; return pid }
        guard leader > 0 else { return }
        let targets = queue.sync { track(leader); return signalKnown(SIGTERM) }
        for _ in 0..<20 where targets.contains(where: { Self.start(of: $0.key) == $0.value }) { usleep(50_000) }
        Self.signal(targets, SIGKILL)
    }

    private func stop(timedOut: Bool) {
        let leader = lock.withLock { () -> pid_t in
            if timedOut { self.timedOut = true } else { cancelled = true }
            return pid
        }
        guard leader > 0 else { return }
        // Yalnız bu çalıştırmanın süreç grubu: önce SIGTERM, 3 sn sonra kalanlara SIGKILL.
        queue.async {
            self.watchdog?.cancel(); self.watchdog = nil
            self.track(leader)
            // Gecikmeli SIGKILL bu nesnenin ömründen bağımsızdır (iptalden sonra çalıştırma serbest kalabilir).
            let targets = self.signalKnown(SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { Self.signal(targets, SIGKILL) }
        }
    }

    // MARK: - Süreç ağacı (yalnız `queue` üzerinde)

    struct ProcessStart: Equatable { var seconds: UInt64; var microseconds: UInt64 }

    /// Liderin grubu ve alt süreç ağacı (alt süreçlerin kendi grupları dahil) kimlikleriyle kaydedilir.
    private func track(_ leader: pid_t) {
        var frontier = [leader] + Self.members(of: leader)
        var seen = Set<pid_t>()
        while let p = frontier.popLast() {
            guard p > 1, seen.insert(p).inserted, let start = Self.start(of: p) else { continue }
            if known[p] == nil { known[p] = start }
            frontier += Self.children(of: p)
            frontier += Self.members(of: p) // alt sürecin kendi grubu
        }
    }

    @discardableResult
    private func signalKnown(_ signal: Int32) -> [pid_t: ProcessStart] {
        known = known.filter { Self.start(of: $0.key) == $0.value }
        Self.signal(known, signal)
        return known
    }

    private static func signal(_ targets: [pid_t: ProcessStart], _ signal: Int32) {
        for (p, start) in targets where Self.start(of: p) == start { kill(p, signal) }
    }

    private static func start(of pid: pid_t) -> ProcessStart? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != 5 /* SZOMB */ else { return nil }
        return ProcessStart(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        return buffer.prefix(max(0, Int(count))).filter { $0 > 1 }
    }

    private static func members(of pgid: pid_t) -> [pid_t] {
        guard pgid > 1 else { return [] }
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listpgrppids(pgid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        return buffer.prefix(max(0, Int(count))).filter { $0 > 1 }
    }

    private func consumeStdout(_ data: Data) {
        var lines: [Substring] = []
        lock.withLock {
            lastActivity = Date()
            if collectStdout {
                if stdout.count + data.count <= Self.stdoutLimit { stdout.append(data) } else { overflow = true }
                return
            }
            pendingLine.append(data)
            while let nl = pendingLine.firstIndex(of: 0x0A) {
                lines.append(Substring(String(decoding: pendingLine[pendingLine.startIndex..<nl], as: UTF8.self)))
                pendingLine.removeSubrange(pendingLine.startIndex...nl)
            }
            if pendingLine.count > 4096 { pendingLine.removeAll() } // satır sonu olmayan uzun çıktı tutulmaz
        }
        lines.forEach { onLine?($0) }
    }

    private func consumeStderr(_ data: Data) {
        lock.withLock {
            lastActivity = Date()
            stderr.append(data)
            if stderr.count > Self.stderrLimit { stderr.removeFirst(stderr.count - Self.stderrLimit) }
        }
    }
}
