import AppKit
import Quartz

/// Raftaki dosyalar için Quick Look. `NotchPanel`, responder zincirinde `QLPreviewPanelController`
/// rolünü üstlenir ve veri kaynağı olarak bu nesneyi bağlar (Apple'ın önerdiği yol; veri kaynağı
/// doğrudan atanmaz).
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    /// Önizleme sırasında adanın kapanmaması için (kilit) çağrılır.
    var onVisibilityChange: ((Bool) -> Void)?
    private(set) var isPreviewing = false
    private var items: [URL] = []
    private var previousApp: NSRunningApplication?

    var hasItems: Bool { !items.isEmpty }

    func preview(_ urls: [URL], from panel: NSPanel?) {
        guard !urls.isEmpty, let previewPanel = QLPreviewPanel.shared() else { return }
        items = urls
        if previewPanel.isVisible, isPreviewing {
            previewPanel.reloadData()
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
        previewPanel.makeKeyAndOrderFront(nil)
    }

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        isPreviewing = true
        onVisibilityChange?(true)
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        isPreviewing = false
        onVisibilityChange?(false)
        previousApp?.activate() // odağı kullanıcının uygulamasına geri ver
        previousApp = nil
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { items[index] as NSURL }
    }
}
