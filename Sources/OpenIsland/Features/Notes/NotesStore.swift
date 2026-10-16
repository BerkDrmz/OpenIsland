import AppKit
import UniformTypeIdentifiers

/// Quick Notes: tek bir Markdown dosyası, yazma durduktan 0,6 sn sonra atomik kaydedilir.
@MainActor
@Observable
final class NotesStore {
    var text: String {
        didSet { scheduleSave() }
    }

    @ObservationIgnored private let fileURL = AppPaths.support.appendingPathComponent("QuickNotes.md")
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSavedText: String

    init() {
        let initialText = (try? String(contentsOf: AppPaths.support.appendingPathComponent("QuickNotes.md"), encoding: .utf8)) ?? ""
        text = initialText
        lastSavedText = initialText
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard text != lastSavedText else { return }
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            lastSavedText = text
        } catch { /* Keep unsaved text available for the next flush. */ }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}

struct LauncherItem: Identifiable, Codable, Hashable {
    enum Kind: Codable, Hashable {
        case app(path: String)
        case shortcut(name: String)
        case link(url: String)
    }

    var id = UUID()
    var kind: Kind

    var title: String {
        switch kind {
        case .app(let path): FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        case .shortcut(let name): name
        case .link(let url): URL(string: url)?.host(percentEncoded: false) ?? url
        }
    }
}

/// Uygulama, web bağlantısı ve Apple Shortcuts başlatıcı. Kısayollar `/usr/bin/shortcuts` CLI ile
/// listelenir ve çalıştırılır (public, izin gerektirmez).
@MainActor
@Observable
final class LauncherStore {
    private(set) var items: [LauncherItem] = []
    private(set) var availableShortcuts: [String] = []
    /// Dosya seçici / bağlantı penceresi açıkken adanın kapanmaması için.
    @ObservationIgnored var hold: IslandHold?
    @ObservationIgnored private var shortcutsLoadedAt: Date?
    @ObservationIgnored private var inFlightFetch: Task<ShortcutsListResult, Never>?
    @ObservationIgnored private var activeRequest: ShortcutsListRequest?
    @ObservationIgnored private var fetchGeneration: UInt64 = 0
    @ObservationIgnored private var failedAt: Date?
    @ObservationIgnored private let fetchOverride: (@Sendable () async -> ShortcutsListResult)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var iconCache: [UUID: NSImage] = [:]
    /// Uygulama öğesinin başlığı dosya sistemi/LaunchServices sorgusudur (`displayName`); her Notlar açılışında kutucuk
    /// başına iki kez (ipucu + erişilebilirlik) yeniden hesaplanıyordu. Simge önbelleğiyle aynı ömür: öğe kaldırılınca silinir.
    @ObservationIgnored private var titleCache: [UUID: String] = [:]

    @ObservationIgnored private let storeURL = AppPaths.support.appendingPathComponent("launcher.json")

    init(fetchShortcuts: (@Sendable () async -> ShortcutsListResult)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.fetchOverride = fetchShortcuts
        self.now = now
        load()
        if items.isEmpty {
            items = ["/System/Applications/Calendar.app", "/System/Applications/Notes.app", "/Applications/Safari.app", "/System/Applications/Utilities/Terminal.app"]
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { LauncherItem(kind: .app(path: $0)) }
        }
    }

    func icon(for item: LauncherItem) -> NSImage {
        if let cached = iconCache[item.id] { return cached }
        let image: NSImage
        switch item.kind {
        case .app(let path): image = NSWorkspace.shared.icon(forFile: path)
        case .shortcut: image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil) ?? NSImage()
        case .link(let string):
            // Favicon için ağ isteği yapılmaz (gizlilik): bağlantıyı açacak tarayıcının simgesi.
            if let url = URL(string: string), let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
                image = NSWorkspace.shared.icon(forFile: app.path)
            } else {
                image = NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage()
            }
        }
        iconCache[item.id] = image
        return image
    }

    func title(for item: LauncherItem) -> String {
        if let cached = titleCache[item.id] { return cached }
        let title = item.title
        titleCache[item.id] = title
        return title
    }

    func launch(_ item: LauncherItem) {
        switch item.kind {
        case .app(let path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
        case .shortcut(let name):
            Self.runProcess(arguments: ["run", name])
        case .link(let string):
            if let url = URL(string: string) { NSWorkspace.shared.open(url) }
        }
    }

    func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard hold?.during({ panel.runModal() }) ?? panel.runModal() == .OK else { return }
        for url in panel.urls where !items.contains(where: { $0.kind == .app(path: url.path) }) {
            items.append(LauncherItem(kind: .app(path: url.path)))
        }
        save()
    }

    /// Bağlantı ekleme penceresi; panoda geçerli bir bağlantı varsa önceden doldurulur.
    func addLink() {
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "https://"
        if let clip = NSPasteboard.general.string(forType: .string), Self.normalizedURL(clip) != nil {
            field.stringValue = clip
        }
        let alert = NSAlert()
        alert.messageText = "Bağlantı sabitle"
        alert.informativeText = "Adadan tek tıkla açmak istediğiniz web adresi."
        alert.accessoryView = field
        alert.addButton(withTitle: "Ekle")
        alert.addButton(withTitle: "Vazgeç")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        let response = hold?.during({ alert.runModal() }) ?? alert.runModal()
        guard response == .alertFirstButtonReturn, let url = Self.normalizedURL(field.stringValue) else { return }
        guard !items.contains(where: { $0.kind == .link(url: url.absoluteString) }) else { return }
        items.append(LauncherItem(kind: .link(url: url.absoluteString)))
        save()
    }

    /// "apple.com" → "https://apple.com"; yalnızca http(s) kabul edilir.
    static func normalizedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let scheme = url.scheme, ["http", "https"].contains(scheme),
              let host = url.host(), host.contains(".") else { return nil }
        return url
    }

    func pinShortcut(_ name: String) {
        guard !items.contains(where: { $0.kind == .shortcut(name: name) }) else { return }
        items.append(LauncherItem(kind: .shortcut(name: name)))
        save()
    }

    func remove(_ item: LauncherItem) {
        items.removeAll { $0.id == item.id }
        iconCache[item.id] = nil
        titleCache[item.id] = nil
        save()
    }

    /// Cache successful results only. A real failure gets bounded, event-triggered backoff;
    /// closing/reopening the panel keeps the same store-owned request alive.
    func refreshShortcutsIfNeeded() async {
        if let loaded = shortcutsLoadedAt, now().timeIntervalSince(loaded) < 300 { return }
        if inFlightFetch == nil, let failedAt, now().timeIntervalSince(failedAt) < 10 { return }
        await refreshShortcuts()
    }

    func refreshShortcuts() async {
        if let inFlight = inFlightFetch {
            _ = await inFlight.value
            return // The owner publishes once; joining callers never overwrite newer results.
        }
        fetchGeneration &+= 1
        let generation = fetchGeneration
        let fetchTask: Task<ShortcutsListResult, Never>
        if let fetchOverride {
            fetchTask = Task { await fetchOverride() }
        } else {
            let request = ShortcutsListRequest()
            activeRequest = request
            fetchTask = Task.detached(priority: .utility) { request.run() }
        }
        inFlightFetch = fetchTask
        let result = await fetchTask.value
        guard generation == fetchGeneration else { return }
        inFlightFetch = nil
        activeRequest = nil
        switch result {
        case .success(let names):
            shortcutsLoadedAt = now()
            failedAt = nil
            if names != availableShortcuts { availableShortcuts = names }
        case .failure:
            failedAt = now() // Retain last good list; failure is not a successful empty listing.
        }
    }

    func shutdown() {
        fetchGeneration &+= 1
        activeRequest?.cancel(immediately: true)
        activeRequest = nil
        inFlightFetch?.cancel()
        inFlightFetch = nil
    }

    @discardableResult
    nonisolated private static func runProcess(arguments: [String], captureOutput: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = captureOutput ? pipe : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        guard captureOutput else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([LauncherItem].self, from: data) else { return }
        items = saved
    }
}

enum ShortcutsListFailure: Error, Sendable, Equatable {
    case launch, exit(Int32), cancelled, timedOut, decoding, reading
}
typealias ShortcutsListResult = Result<[String], ShortcutsListFailure>

/// Store-owned single flight survives tab changes. A one-shot deadline bounds a stalled CLI;
/// shutdown invalidates its result and terminates only this listing subprocess.
final class ShortcutsListRequest: @unchecked Sendable {
    private let lock = NSCondition()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private var output = Data()
    private var outputFinished = false
    private var outputFailed = false
    private var outputReader: DispatchSourceRead?
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    init(executable: URL = URL(fileURLWithPath: "/usr/bin/shortcuts"),
         arguments: [String] = ["list"], timeout: TimeInterval = 10) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
    }
    func run() -> ShortcutsListResult {
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        lock.lock()
        guard !cancelled else { lock.unlock(); return .failure(.cancelled) }
        process = task
        do { try task.run() } catch { process = nil; lock.unlock(); return .failure(.launch) }
        lock.unlock()
        try? pipe.fileHandleForWriting.close()
        let handle = pipe.fileHandleForReading
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let queue = DispatchQueue(label: "OpenIsland.shortcuts.output", qos: .utility)
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        lock.lock(); outputReader = reader; lock.unlock()
        reader.setEventHandler { [weak self] in self?.drain(fd) }
        reader.setCancelHandler { try? handle.close() }
        reader.resume()
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler { [weak self] in self?.expire() }
        deadline.resume()
        defer {
            deadline.cancel(); reader.cancel()
            lock.lock(); outputReader = nil; lock.unlock()
        }
        lock.lock()
        while !outputFinished && !cancelled && !timedOut { lock.wait() }
        lock.unlock()
        task.waitUntilExit()
        lock.lock()
        process = nil
        let result: ShortcutsListResult
        if cancelled { result = .failure(.cancelled) }
        else if timedOut { result = .failure(.timedOut) }
        else if outputFailed { result = .failure(.reading) }
        else if task.terminationStatus != 0 { result = .failure(.exit(task.terminationStatus)) }
        else if let text = String(data: output, encoding: .utf8) {
            result = .success(text.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
        } else { result = .failure(.decoding) }
        lock.unlock()
        return result
    }
    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            lock.lock()
            let shouldStop = cancelled || timedOut
            let readerToCancel = shouldStop ? outputReader : nil
            lock.unlock()
            if shouldStop { readerToCancel?.cancel(); return }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            let error = errno
            lock.lock()
            if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 { outputFinished = true; lock.broadcast() }
            else if error != EAGAIN && error != EINTR { outputFailed = true; outputFinished = true; lock.broadcast() }
            let finishedReader = outputFinished ? outputReader : nil
            lock.unlock()
            finishedReader?.cancel() // EOF must not keep a ready source waking while the CLI exits.
            if count <= 0 { return }
        }
    }
    private static func terminateOwned(_ task: Process?) {
        guard let task, task.isRunning else { return }
        task.terminate()
        // Bounded escalation applies to cancellation as well as timeout, only for this subprocess.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
    }
    private func expire() {
        lock.lock()
        timedOut = true // A descendant may keep stdout open even after the parent has exited.
        let task = process
        lock.broadcast()
        lock.unlock()
        Self.terminateOwned(task)
    }
    func cancel(immediately: Bool = false) {
        lock.lock()
        cancelled = true
        let task = process
        lock.broadcast()
        lock.unlock()
        // At app shutdown no future dispatch closure is guaranteed to execute.
        if immediately, let task, task.isRunning { kill(task.processIdentifier, SIGKILL) }
        else { Self.terminateOwned(task) }
    }
}
