import Foundation
import UserNotifications

enum AppPaths {
    /// ~/Library/Application Support/io.github.openisland
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("io.github.openisland", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// UserNotifications, SMAppService gibi API'ler gerçek bir .app paketi ister;
    /// `swift run` ile çıplak binary çalışırken bunlara dokunmamak gerekir (aksi halde çöker).
    static var isRunningAsBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}

enum Notifier {
    static func requestAuthorization() {
        guard AppPaths.isRunningAsBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard AppPaths.isRunningAsBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
