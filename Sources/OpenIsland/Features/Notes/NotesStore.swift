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
    @ObservationIgnored private var iconCache: [UUID: NSImage] = [:]

    @ObservationIgnored private let storeURL = AppPaths.support.appendingPathComponent("launcher.json")

    init() {
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
        save()
    }

    /// `shortcuts list` bir alt süreç başlatır; sekme her açıldığında değil, en fazla 5 dakikada bir.
    func refreshShortcutsIfNeeded() async {
        if let loaded = shortcutsLoadedAt, Date().timeIntervalSince(loaded) < 300 { return }
        shortcutsLoadedAt = Date()
        await refreshShortcuts()
    }

    func refreshShortcuts() async {
        let request = ShortcutsListRequest()
        let names = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) { request.run() }.value
        } onCancel: { request.cancel() }
        guard !Task.isCancelled else {
            shortcutsLoadedAt = nil
            return
        }
        if names != availableShortcuts { availableShortcuts = names }
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

/// Only a user-opened panel requests a listing; closing it terminates its list process.
private final class ShortcutsListRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func run() -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = ["list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        lock.lock()
        guard !cancelled else { lock.unlock(); return [] }
        process = task
        do { try task.run() } catch { process = nil; lock.unlock(); return [] }
        lock.unlock()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        lock.lock()
        process = nil
        let wasCancelled = cancelled
        lock.unlock()
        guard !wasCancelled, task.terminationStatus == 0 else { return [] }
        return String(data: data, encoding: .utf8)?.split(separator: "\n").map(String.init).filter { !$0.isEmpty } ?? []
    }
    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }
}
