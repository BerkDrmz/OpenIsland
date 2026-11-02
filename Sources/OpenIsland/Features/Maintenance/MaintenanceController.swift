import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class MaintenanceController: NSObject, NSWindowDelegate {
    enum Section: String, CaseIterable, Identifiable {
        case uninstaller = "Kaldırıcı", cleaner = "Önbellek temizleyici"
        var id: Self { self }
        var symbol: String {
            switch self { case .uninstaller: "trash"; case .cleaner: "sparkles" }
        }
    }

    private(set) var section = Section.uninstaller
    private(set) var applications: [ManagedApplication] = []
    var applicationID: String?
    private(set) var files: [MaintenanceFile] = []
    var selectedFiles: Set<String> = []
    private(set) var busy = false
    private(set) var status = ""
    private(set) var runningBundleIDs: Set<String> = []
    @ObservationIgnored private let worker: MaintenanceWorker
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var runningNames: Set<String> = []

    init(worker: MaintenanceWorker = MaintenanceWorker()) {
        self.worker = worker
        super.init()
    }

    var selectedApplication: ManagedApplication? { applications.first { $0.id == applicationID } }
    var observerCount: Int { workspaceObservers.count }
    var hasActiveTask: Bool { task != nil }
    var isPresented: Bool { window != nil }
    var selectableCacheCount: Int { files.filter { !blocked($0) }.count }
    var selectedBytes: Int64 { files.filter { selectedFiles.contains($0.id) }.reduce(0) { $0 + $1.bytes } }

    func open() {
        if let window { NSApp.activate(); window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 590),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "OpenIsland — Araçlar"
        window.identifier = NSUserInterfaceItemIdentifier("OpenIslandMaintenance")
        window.minSize = NSSize(width: 780, height: 540)
        window.isReleasedWhenClosed = false
        window.delegate = self
        #if OPENISLAND_DENEY
        // AppKit deneyi: aynı denetleyiciyle AppKit görünümü (Deney/Sources/Tools/MaintenanceWindowView.swift). Başlık
        // çubuğu saydam; kenar çubuğu onun altına uzanır (Ayarlar penceresiyle aynı düzen).
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = MaintenanceWindowView(controller: self)
        #else
        let hosting = NSHostingView(rootView: MaintenanceView(controller: self))
        // AppKit owns this resizable window's size; SwiftUI's ideal List height must not
        // resize it to fit every installed app or change its size when switching tools.
        hosting.sizingOptions = []
        window.contentView = hosting
        #endif
        window.setContentSize(NSSize(width: 880, height: 590))
        window.center()
        self.window = window
        observeRunningApps()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        loadApplications()
    }

    func windowWillClose(_ notification: Notification) {
        cancel()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        window?.contentView = nil
        window = nil
        // Release potentially large snapshots, icons and selections; reopen scans the inventory once.
        files = []; selectedFiles = []; applications = []; applicationID = nil
    }

    func shutdown() { window?.close(); cancel() }

    func cancel() {
        task?.cancel(); task = nil; generation = UUID()
        if busy { status = "İşlem durduruldu. Tamamlanan taşımalara Çöp Sepeti'nden ulaşabilirsin." }
        busy = false
    }

    func select(_ section: Section) {
        guard self.section != section else { return }
        cancel(); self.section = section; files = []; selectedFiles = []; status = ""
    }

    func choose(_ app: ManagedApplication) {
        guard !busy else { return }
        applicationID = app.id; files = []; selectedFiles = []
        if !busy { status = "" }
    }

    func loadApplications() {
        cancel(); busy = true; status = "Uygulama listesi okunuyor…"
        let token = generation, worker = worker
        task = Task(priority: .utility) { [weak self] in
            do {
                let apps = try await worker.applications()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.applications = apps
                if !apps.contains(where: { $0.id == self.applicationID }) { self.applicationID = apps.first?.id }
                self.files = []; self.selectedFiles = []
                self.finish("\(apps.count) uygulama bulundu. Arka planda tarama yapılmaz.")
            } catch { self?.failed(error, token: token) }
        }
    }

    func scan() {
        guard !busy else { return }
        guard section == .cleaner || selectedApplication != nil else { return }
        let app = section == .uninstaller ? selectedApplication : nil
        if let app, isRunning(app) { status = "Önce \(app.name) uygulamasını tamamen kapat; açık uygulamanın verileri kaldırılmaz."; return }
        files = []; selectedFiles = []; busy = true; status = "Dosyalar ve boyutları taranıyor…"
        generation = UUID()
        let token = generation, worker = worker
        task = Task(priority: .utility) { [weak self] in
            do {
                let files: [MaintenanceFile]
                if let app { files = try await worker.remnants(for: app) }
                else { files = try await worker.caches() }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.files = files
                // Only identity-matched non-personal remnants are preselected. Cache cleaning starts unselected.
                self.selectedFiles = Set(files.filter { app != nil && $0.verifiedIdentity && !$0.containsPersonalData }.map(\.id))
                self.finish("\(files.count) öğe bulundu. Taşınacak öğeleri denetle ve seç.")
            } catch { self?.failed(error, token: token) }
        }
    }

    func selectAllCaches() {
        guard section == .cleaner, !busy else { return }
        selectedFiles = Set(files.filter { !blocked($0) }.map(\.id))
    }

    func isRunning(_ app: ManagedApplication) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == app.bundleID || $0.bundleURL.map { $0.path == app.url.path || $0.path.hasPrefix(app.url.path + "/") } == true
        }
    }

    func blocked(_ file: MaintenanceFile) -> Bool {
        if section == .uninstaller { return selectedApplication.map { runningBundleIDs.contains($0.bundleID) } ?? true }
        let name = file.url.lastPathComponent
        return runningNames.contains(name) || runningBundleIDs.contains(where: { name == $0 || name.hasPrefix($0 + ".") })
            || (name == "Google" && runningBundleIDs.contains(where: { $0.hasPrefix("com.google.Chrome") }))
    }

    func confirmTrash() {
        guard !busy, let window else { return }
        let chosen = files.filter { selectedFiles.contains($0.id) && !blocked($0) }
        guard !chosen.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = section == .uninstaller ? "Seçilen uygulama ve kalıntıları Çöp Sepeti'ne taşınsın mı?" : "Seçilen önbellekler Çöp Sepeti'ne taşınsın mı?"
        alert.informativeText = "\(chosen.count) öğe · \(Self.size(chosen.reduce(0) { $0 + $1.bytes }))\n" +
            (chosen.contains(where: \.containsPersonalData) ? "Seçiminde kişisel uygulama verileri var. " : "") +
            "Dosyalar kalıcı silinmez. Alan kazanmak için Çöp Sepeti'ni daha sonra kendin boşaltabilirsin."
        alert.addButton(withTitle: "Çöp Sepeti'ne Taşı")
        alert.addButton(withTitle: "Vazgeç")
        alert.beginSheetModal(for: window) { [weak self, weak window] result in
            guard result == .alertFirstButtonReturn, let self, self.window === window else { return }
            self.moveToTrash(chosen)
        }
    }

    private func moveToTrash(_ chosen: [MaintenanceFile]) {
        guard !busy else { return }
        let app = section == .uninstaller ? selectedApplication : nil
        if let app, isRunning(app) { status = "Uygulama yeniden açıldı; işlem yapılmadı."; return }
        let ordered = chosen.sorted { !$0.isApplication && $1.isApplication }
        busy = true; generation = UUID()
        let token = generation, worker = worker
        task = Task(priority: .utility) { [weak self] in
            var moved = 0, failures: [String] = []
            for file in ordered {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                if self.blocked(file) { failures.append("\(file.url.lastPathComponent): uygulama açık"); continue }
                self.status = "Çöp Sepeti'ne taşınıyor: \(file.url.lastPathComponent)"
                do {
                    try await worker.trash(file, app: app)
                    guard self.generation == token else { return }
                    moved += 1; self.files.removeAll { $0.id == file.id }; self.selectedFiles.remove(file.id)
                    if file.isApplication, let app { self.applications.removeAll { $0.id == app.id }; self.applicationID = nil }
                } catch is CancellationError { return }
                catch { failures.append("\(file.url.lastPathComponent): \(error.localizedDescription)") }
            }
            guard let self, self.generation == token else { return }
            self.finish("\(moved) öğe Çöp Sepeti'ne taşındı." + (failures.isEmpty ? "" : "\nTaşınamayanlar:\n" + failures.joined(separator: "\n")))
        }
    }

    func reveal(_ file: MaintenanceFile) { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private func finish(_ message: String) { busy = false; task = nil; status = message }
    private func failed(_ error: Error, token: UUID) {
        guard generation == token, !(error is CancellationError) else { return }
        finish(error.localizedDescription)
    }
    private func observeRunningApps() {
        refreshRunning()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
            })
        }
    }
    private func refreshRunning() {
        let apps = NSWorkspace.shared.runningApplications
        runningBundleIDs = Set(apps.compactMap(\.bundleIdentifier))
        runningNames = Set(apps.flatMap { [$0.localizedName, $0.bundleURL?.deletingPathExtension().lastPathComponent].compactMap { $0 } })
        selectedFiles.subtract(files.filter(blocked).map(\.id))
    }
}
