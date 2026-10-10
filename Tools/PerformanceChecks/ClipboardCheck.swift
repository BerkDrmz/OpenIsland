import AppKit

@MainActor enum AppPaths { static let support = FileManager.default.temporaryDirectory }
// Keep both the pasteboard and application-name lookup controlled. The production
// source still performs the real changeCount check and attribution logic.
final class NSRunningApplication: @unchecked Sendable {
    let name: String?
    var nameQueries = 0
    init(_ name: String?) { self.name = name }
    var localizedName: String? { nameQueries += 1; return name }
}
@MainActor final class NSWorkspace {
    static let shared = NSWorkspace()
    nonisolated static let didActivateApplicationNotification = Notification.Name("ClipboardCheck.didActivate")
    nonisolated static let applicationUserInfoKey = "application"
    let notificationCenter = NotificationCenter()
    var frontmostApplication: NSRunningApplication? = NSRunningApplication("Synthetic source")
}
func AXIsProcessTrusted() -> Bool { false }
// Clipboard contents are controlled: this test never reads/writes the user's pasteboard.
@MainActor final class NSPasteboard {
    typealias PasteboardType = AppKit.NSPasteboard.PasteboardType
    static let general = NSPasteboard()
    var changeCount = 0
    enum AccessBehavior { case alwaysAllow, alwaysDeny }
    var accessBehavior: AccessBehavior = .alwaysAllow
    var types: [PasteboardType]? = [.string]
    var value: String?
    func clearContents() { value = nil; changeCount += 1 }
    func setString(_ value: String, forType: PasteboardType) { self.value = value; changeCount += 1 }
    func setData(_ data: Data, forType: PasteboardType) { changeCount += 1 }
    func writeObjects(_ objects: [NSURL]) { changeCount += 1 }
    func readObjects(forClasses: [AnyClass], options: [AppKit.NSPasteboard.ReadingOptionKey: Any]) -> [Any]? { nil }
    func string(forType: PasteboardType) -> String? { value }
    func data(forType: PasteboardType) -> Data? { nil }
}

@main struct ClipboardCheck {
    @MainActor static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        checkRefreshQueries(in: folder)
        let store = folder.appendingPathComponent("clipboard.json")
        let history = ClipboardHistory(storeURL: store)
        let first = ClipItem(content: .text("first synthetic entry"), date: Date(), sourceApp: "test")
        let second = ClipItem(content: .text("second synthetic entry"), date: Date(), sourceApp: "test")
        history.copy(first)
        let initial = history.items
        let saved = try Data(contentsOf: store)
        let sentinelDate = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: sentinelDate], ofItemAtPath: store.path)
        for _ in 0..<1000 { history.copy(history.items[0]) }
        precondition(history.items == initial && NSPasteboard.general.value == "first synthetic entry")
        let afterRecopies = try Data(contentsOf: store)
        precondition(afterRecopies == saved)
        let modification = try FileManager.default.attributesOfItem(atPath: store.path)[.modificationDate] as! Date
        precondition(modification == sentinelDate, "Repeated head copy rewrote disk")
        history.copy(second)
        precondition(history.items.count == 2)
        history.copy(first)
        precondition(history.items.map(\.id) == [first.id, second.id], "Promotion rebuilt existing row identity")
        precondition(history.items[0].date >= first.date && history.items[0].sourceApp == "test")
        let reloaded = ClipboardHistory(storeURL: store)
        precondition(reloaded.items == history.items, "Persistence no longer preserves ordering/contents")
        history.limit = 2
        history.copy(ClipItem(content: .text("third synthetic entry"), date: Date(), sourceApp: "test"))
        precondition(history.items.count == 2 && history.items[1].id == first.id)
        history.limit = 1
        history.copy(history.items[0])
        precondition(history.items.count == 1, "Reduced limit was ignored by deduplication")
        history.copy(first)
        history.remove(history.items[0])
        precondition(history.items.isEmpty)
        history.copy(second)
        history.clear()
        precondition(history.items.isEmpty)
        print("PASS Clipboard: 1000 head recopies / 0 history changes / 0 disk writes; actual copy still updates pasteboard; promotion keeps row identity, order and limit; persistence/remove/clear preserved")
    }

    @MainActor private static func checkRefreshQueries(in folder: URL) {
        let application = NSWorkspace.shared.frontmostApplication!
        let history = ClipboardHistory(storeURL: folder.appendingPathComponent("refresh.json"))
        history.start()
        defer { history.stop() }
        application.nameQueries = 0
        for _ in 0..<1000 { history.refresh() }
        precondition(application.nameQueries == 0 && history.items.isEmpty,
                     "Unchanged clipboard refresh must not query the frontmost application's name")
        NSPasteboard.general.setString("new synthetic clipboard", forType: .string)
        history.refresh()
        precondition(application.nameQueries == 1 && history.items[0].sourceApp == "Synthetic source",
                     "A real change must still resolve and preserve the source application")
        for _ in 0..<1000 { history.refresh() }
        precondition(application.nameQueries == 1 && history.items.count == 1)

        let next = NSRunningApplication("Next synthetic app")
        NSPasteboard.general.setString("copied before switching", forType: .string)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
                                                   object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: next])
        precondition(history.items[0].sourceApp == "Synthetic source" && application.nameQueries == 1,
                     "Activation must preserve the previous app attribution without a fresh lookup")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
                                                   object: nil)
        NSPasteboard.general.setString("unknown previous source", forType: .string)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
                                                   object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: next])
        precondition(history.items[0].sourceApp == nil && application.nameQueries == 1,
                     "Explicit nil previous source must remain nil, not fall back to the current app")
        history.stop()
        NSPasteboard.general.setString("after stop", forType: .string)
        let stoppedItems = history.items
        history.refresh()
        precondition(history.items == stoppedItems && application.nameQueries == 1)
        print("PASS Clipboard refresh: 2000 unchanged checks / 0 extra app-name queries; changed content resolves once; activation and nil attribution preserved; stopped history stays inactive")
    }
}
