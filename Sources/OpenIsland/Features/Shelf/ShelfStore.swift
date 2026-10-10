import AppKit
import IslandCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Hashable, Sendable {
    var id = UUID()
    var url: URL
    /// Görsel verisi gibi dosya olmayan sürüklemeler önbelleğe kopyalanır; raf temizlenince silinir.
    let isTemporaryCopy: Bool
    /// Dosya silinmiş, taşınıp bulunamamış veya erişim yok: öğe gösterilir ama işlem hedefi olmaz.
    var isMissing = false
    var name: String { url.lastPathComponent }
}

/// Diskteki kalıcı kayıt. Bookmark, dosya taşınsa veya yeniden adlandırılsa da onu bulur.
/// Uygulama sandbox'sız olduğu için security-scoped bookmark gerekmez; normal bookmark yeterlidir.
private struct PersistedShelfItem: Codable {
    let id: UUID
    let bookmark: Data?
    let path: String
    let isTemporaryCopy: Bool
}

/// Dosya rafı. Finder dosyaları referans olarak (kopyalanmadan) tutulur; tarayıcıdan sürüklenen görseller,
/// file promise'ler (Fotoğraflar, Mail) ve metinler `~/Library/Caches/…/Shelf` altına yazılır.
/// Raf uygulama yeniden açıldığında korunur; küçük resimler yalnızca raf gösterildiğinde üretilir.
@MainActor
@Observable
final class ShelfStore: NSObject, NSSharingServiceDelegate {
    private(set) var items: [ShelfItem] = []
    private(set) var thumbnails: [URL: NSImage] = [:]
    /// Toplu işlem için seçili öğeler (⌘ ile ekle/çıkar, ⇧ ile aralık).
    private(set) var selection: Set<UUID> = []
    @ObservationIgnored var onCountChange: ((Int) -> Void)?
    /// AirDrop sayfası açıkken adanın kapanmaması için.
    @ObservationIgnored var hold: IslandHold?
    @ObservationIgnored var onAirDropSent: ((Int) -> Void)?
    /// Dosya işleminin durumu ("Zip'leniyor…", sonuç veya hata); eylem çubuğunda kısa süre gösterilir.
    private(set) var operationStatus: String?
    private(set) var isOperationRunning = false
    @ObservationIgnored private var statusClearTask: Task<Void, Never>?
    @ObservationIgnored private var selectionAnchor: UUID?

    /// `.data` file promise'leri (Mail ekleri vb.) kapsar; metin ve web bağlantıları da kabul edilir.
    static let acceptedTypes: [UTType] = [.fileURL, .image, .data, .url, .plainText]
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private var thumbnailsRequested = false
    @ObservationIgnored private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let storage: URL

    /// Explicit paths allow integration checks without touching the user's shelf or bookmarks.
    init(storage: URL? = nil, persistenceURL: URL? = nil) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.storage = storage ?? base.appendingPathComponent("io.github.openisland/Shelf", isDirectory: true)
        self.storeURL = persistenceURL ?? AppPaths.support.appendingPathComponent("shelf.json")
        super.init()
        try? FileManager.default.createDirectory(at: self.storage, withIntermediateDirectories: true)
    }

    // MARK: - Ekleme

    /// Sürükle-bırak sağlayıcılarını işler; `true` dönerse en az bir öğe kabul edilmiştir.
    ///
    /// Sıra: dosya URL'si → dosya temsili (görseller ve **file promise**'ler: Fotoğraflar, Mail; sistem
    /// bunları `NSItemProvider` üzerinden sağlar) → web bağlantısı (.webloc) → düz metin (.txt).
    @discardableResult
    func ingest(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url, url.isFileURL else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.add(url, temporary: false) }
                    }
                }
            } else if let type = ShelfImportRules.fileRepresentationType(provider.registeredTypeIdentifiers,
                                                                         suggestedFilename: provider.suggestedName) {
                accepted = true
                let destinationFolder = storage
                let suggested = provider.suggestedName
                provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] tempURL, _ in
                    // Geçici dosya yalnızca bu blok süresince yaşar; hemen kopyala.
                    guard let tempURL else { return }
                    guard let target = try? ShelfImportRules.copyRepresentation(at: tempURL,
                        suggestedFilename: suggested, into: destinationFolder) else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.add(target, temporary: true) }
                    }
                }
            } else if provider.suggestedName != nil,
                      provider.registeredTypeIdentifiers.contains(where: {
                          guard let type = UTType($0) else { return false }
                          return type.conforms(to: .data) && !type.conforms(to: .url)
                      }) {
                // A named file with conflicting type metadata must not become a text/image export.
                continue
            } else if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url, !url.isFileURL else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.addLink(url) }
                    }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                accepted = true
                _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
                    guard let text, !text.isEmpty else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.addText(text) }
                    }
                }
            }
        }
        return accepted
    }

    func addLink(_ url: URL) {
        let plist = ["URL": url.absoluteString]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        let target = Self.uniqueURL(in: storage, name: url.host() ?? "Bağlantı", extension: "webloc")
        guard (try? data.write(to: target)) != nil else { return }
        add(target, temporary: true)
    }

    func addText(_ text: String) {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Metin"
        let name = String(firstLine.prefix(32)).replacingOccurrences(of: "/", with: "-")
        let target = Self.uniqueURL(in: storage, name: name.isEmpty ? "Metin" : name, extension: "txt")
        guard (try? text.write(to: target, atomically: true, encoding: .utf8)) != nil else { return }
        add(target, temporary: true)
    }

    private nonisolated static func uniqueURL(in folder: URL, name: String, extension ext: String) -> URL {
        var candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }

    /// Sensör penceresine (AppKit drag destination) doğrudan bırakılan içerik.
    @discardableResult
    func ingest(pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            urls.forEach { add($0, temporary: false) }
            selectDropped(urls)
            return true
        }
        // File promise (Fotoğraflar, Mail): dosya henüz yok; kaynak uygulama hedef klasöre yazar.
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            for receiver in receivers {
                let destination = storage.appendingPathComponent(UUID().uuidString, isDirectory: true)
                guard (try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)) != nil else { continue }
                receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: promiseQueue) { [weak self] url, error in
                    guard error == nil else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.add(url, temporary: true) }
                    }
                }
            }
            return true
        }
        let representations = [NSPasteboard.PasteboardType.png, .tiff].compactMap { type in
            pasteboard.data(forType: type).map { (type.rawValue, $0) }
        }
        guard let image = ShelfImportRules.imageRepresentation(from: Dictionary(uniqueKeysWithValues: representations)) else { return false }
        let target = Self.uniqueURL(in: storage, name: "Görsel-\(UUID().uuidString.prefix(6))", extension: image.fileExtension)
        guard (try? image.data.write(to: target)) != nil else { return false }
        add(target, temporary: true)
        return true
    }

    func add(_ url: URL, temporary: Bool) {
        guard url.isFileURL, !items.contains(where: { $0.url == url }) else { return }
        items.append(ShelfItem(url: url, isTemporaryCopy: temporary))
        onCountChange?(items.count)
        if thumbnailsRequested { loadThumbnail(for: url) }
        save()
    }

    // MARK: - Kalıcılık

    /// Açılışta bir kez: bookmark'lar arka planda çözülür (dosya sistemi erişimi ana iş parçacığında değil).
    func restore() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([PersistedShelfItem].self, from: data), !saved.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let restored = saved.map(Self.resolve)
            await MainActor.run {
                guard let self, self.items.isEmpty else { return }
                self.items = restored
                self.onCountChange?(restored.count)
                // Taşınmış dosyaların yeni konumu (bayat bookmark) diske yazılır.
                let savedPaths = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0.path) })
                if restored.contains(where: { item in item.url.path != savedPaths[item.id] }) { self.save() }
            }
        }
    }

    /// Bookmark → güncel konum. Çözülemezse son bilinen yol "eksik" olarak gösterilir; asla çökmez.
    private nonisolated static func resolve(_ record: PersistedShelfItem) -> ShelfItem {
        let fallback = URL(fileURLWithPath: record.path)
        var stale = false
        guard let bookmark = record.bookmark,
              let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.isReadableFile(atPath: url.path)
        else {
            return ShelfItem(id: record.id, url: fallback, isTemporaryCopy: record.isTemporaryCopy, isMissing: true)
        }
        return ShelfItem(id: record.id, url: url, isTemporaryCopy: record.isTemporaryCopy)
    }

    private func save() {
        let records = items.map { item in
            PersistedShelfItem(
                id: item.id,
                bookmark: item.isMissing ? nil : try? item.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                path: item.url.path,
                isTemporaryCopy: item.isTemporaryCopy
            )
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// Raf gösterildiğinde (olay güdümlü): küçük resimler ilk kez üretilir ve dosyaların hâlâ
    /// yerinde olup olmadığı tek seferlik doğrulanır. Raf hiç açılmazsa bu maliyet hiç oluşmaz.
    func panelDidAppear() {
        for index in items.indices {
            let exists = FileManager.default.isReadableFile(atPath: items[index].url.path)
            if items[index].isMissing == exists { items[index].isMissing = !exists }
        }
        if !thumbnailsRequested {
            thumbnailsRequested = true
            items.filter { !$0.isMissing }.forEach { loadThumbnail(for: $0.url) }
        }
    }

    // MARK: - Eylemler

    func remove(_ item: ShelfItem) {
        remove([item])
    }

    func remove(_ removed: [ShelfItem]) {
        let ids = Set(removed.map(\.id))
        for item in removed {
            thumbnails[item.url] = nil
            if item.isTemporaryCopy {
                // Only OpenIsland-owned cache files may be deleted by removing a shelf item.
                let root = storage.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                guard item.url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { continue }
                try? FileManager.default.removeItem(at: item.url)
                let folder = item.url.deletingLastPathComponent()
                if folder != storage, (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        onCountChange?(items.count)
        save()
    }

    func removeAll() {
        remove(items)
    }

    // MARK: - Seçim

    /// Seçim varsa seçili öğeler, yoksa tümü (toplu eylemlerin hedefi).
    var actionTargets: [ShelfItem] {
        (selection.isEmpty ? items : items.filter { selection.contains($0.id) }).filter { !$0.isMissing }
    }

    /// Finder'daki davranış: tıklama tek seçer, ⌘ ekler/çıkarır, ⇧ son bağlantı noktasından aralık seçer.
    func select(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let from = items.firstIndex(where: { $0.id == anchor }),
           let to = items.firstIndex(where: { $0.id == item.id }) {
            selection.formUnion(items[min(from, to)...max(from, to)].map(\.id))
        } else if modifiers.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            selectionAnchor = item.id
        } else {
            selection = [item.id]
            selectionAnchor = item.id
        }
    }

    func selectAll() { selection = Set(items.map(\.id)) }
    func clearSelection() { selection.removeAll() }

    /// Sürükleme başlarken: seçili bir öğe sürükleniyorsa tüm seçim, değilse yalnızca o öğe.
    func dragPayload(startingAt item: ShelfItem) -> [URL] {
        guard !item.isMissing else { return [] }
        return selection.contains(item.id) ? actionTargets.map(\.url) : [item.url]
    }

    // MARK: - Paylaşım

    func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { return }
        service.delegate = self
        hold?.begin()
        NSApp.activate() // AirDrop penceresi öne gelsin
        service.perform(withItems: urls)
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let count = items.count
        MainActor.assumeIsolated {
            hold?.end()
            onAirDropSent?(count)
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        MainActor.assumeIsolated { hold?.end() }
    }

    func quickLook(_ items: [ShelfItem]) {
        let panel = NSApp.windows.compactMap { $0 as? NotchPanel }.first { $0.frame.containsInclusive(NSEvent.mouseLocation) }
        QuickLookController.shared.preview(items.map(\.url), from: panel)
    }

    /// Sağlayıcılardaki dosya URL'lerini eşzamanlı yükler, hepsi gelince ana aktörde tamamlar.
    static func loadFileURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let collector = URLCollector()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collector.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collector.urls
            MainActor.assumeIsolated { completion(urls) }
        }
    }

    func open(_ item: ShelfItem) {
        guard !item.isMissing else { return }
        NSWorkspace.shared.open(item.url)
    }
    func revealInFinder(_ items: [ShelfItem]) { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }

    // MARK: - Dosya işlemleri (zip, arşivi aç, resmi sıkıştır, yolu kopyala)

    /// Bırakılan dosyalar seçilir: işlemler menüsü doğrudan onları hedefler. Raftakilerin hepsiyse seçim gerekmez.
    private func selectDropped(_ urls: [URL]) {
        let ids = Set(items.filter { urls.contains($0.url) }.map(\.id))
        guard !ids.isEmpty, ids.count < items.count else { return }
        selection = ids
        selectionAnchor = ids.first
    }

    func availableOperations(for targets: [ShelfItem]) -> [ShelfOperation] {
        ShelfOperationRules.available(for: targets.map { ShelfFileOperations.info(for: $0.url) })
    }

    func perform(_ operation: ShelfOperation, on targets: [ShelfItem]) {
        let urls = targets.filter { !$0.isMissing }.map(\.url)
        guard !urls.isEmpty, !isOperationRunning else { return }
        if operation == .copyPath {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            showStatus(urls.count == 1 ? "Yol kopyalandı" : "\(urls.count) yol kopyalandı")
            return
        }
        isOperationRunning = true
        showStatus(operation == .zip ? "Zip'leniyor…" : operation == .unzip ? "Açılıyor…" : "Sıkıştırılıyor…", clearsAutomatically: false)
        let fallback = storage
        Task.detached(priority: .userInitiated) {
            var outputs: [URL] = []
            var skipped = 0
            var failure: String?
            let folder = ShelfFileOperations.outputFolder(for: urls, fallback: fallback)
            do {
                switch operation {
                case .zip:
                    outputs = [try ShelfFileOperations.zip(urls, into: folder)]
                case .unzip:
                    for url in urls { outputs.append(try ShelfFileOperations.unzip(url, into: ShelfFileOperations.outputFolder(for: [url], fallback: fallback))) }
                case .compressImage:
                    for url in urls {
                        if let output = try ShelfFileOperations.compressImage(url, into: ShelfFileOperations.outputFolder(for: [url], fallback: fallback)) {
                            outputs.append(output)
                        } else {
                            skipped += 1
                        }
                    }
                case .copyPath:
                    break
                }
            } catch let error as ShelfFileOperations.Failure {
                failure = error.message
            } catch {
                failure = error.localizedDescription
            }
            let results = outputs, skippedCount = skipped, message = failure
            await MainActor.run { [weak self] in
                self?.finish(operation, outputs: results, skipped: skippedCount, failure: message, fallback: fallback)
            }
        }
    }

    private func finish(_ operation: ShelfOperation, outputs: [URL], skipped: Int, failure: String?, fallback: URL) {
        isOperationRunning = false
        for url in outputs {
            // Rafın kendi klasörüne yazılan çıktı geçicidir (raftan kaldırılınca silinir); kullanıcının klasörüne
            // yazılan asla silinmez.
            add(url, temporary: url.deletingLastPathComponent().standardizedFileURL == fallback.standardizedFileURL)
        }
        if !outputs.isEmpty {
            let ids = Set(items.filter { outputs.contains($0.url) }.map(\.id))
            selection = ids
            selectionAnchor = ids.first
        }
        if let failure {
            showStatus("Olmadı: \(failure)")
        } else if outputs.isEmpty, skipped > 0 {
            showStatus(skipped == 1 ? "Görsel zaten küçük" : "Görseller zaten küçük")
        } else if outputs.count == 1, let name = outputs.first?.lastPathComponent {
            showStatus("\(name) hazır")
        } else {
            showStatus("\(outputs.count) dosya hazır" + (skipped > 0 ? " · \(skipped) zaten küçük" : ""))
        }
    }

    /// Durum metni tek seferlik bir gecikmeyle temizlenir (yoklama yok).
    private func showStatus(_ text: String, clearsAutomatically: Bool = true) {
        statusClearTask?.cancel()
        operationStatus = text
        guard clearsAutomatically else { return }
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.operationStatus = nil
        }
    }

    func copyToPasteboard(_ items: [ShelfItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map { $0.url as NSURL })
    }

    // MARK: - Önizleme

    private func loadThumbnail(for url: URL) {
        thumbnails[url] = NSWorkspace.shared.icon(forFile: url.path) // anında yer tutucu
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 64, height: 64), scale: scale, representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let cgImage = representation?.cgImage else { return }
            let size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.thumbnails[url] = NSImage(cgImage: cgImage, size: size) }
            }
        }
    }
}

/// Eşzamanlı yükleme geri çağrılarından URL toplamak için kilitli kap.
private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func append(_ url: URL) { lock.withLock { storage.append(url) } }
    var urls: [URL] { lock.withLock { storage } }
}
