import Foundation
import UserNotifications

enum AppPaths {
    /// ~/Library/Application Support/io.github.openisland
    static let support: URL = {
        // Only an explicitly enabled developer run may redirect storage to a disposable fixture.
        let environment = ProcessInfo.processInfo.environment
        if environment["OPENISLAND_DIAGNOSTICS"] != nil,
           let path = environment["OPENISLAND_TEST_SUPPORT"], path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // SwiftUI ve AppKit sürümü aynı uygulamadır (io.github.openisland.OpenIsland): aynı veri klasörü.
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
        #if OPENISLAND_APPKIT
        // Isolated validation bundles must never request or deliver user notifications.
        if TestIsolationGuard.isValidationBundle { return }
        #endif
        guard AppPaths.isRunningAsBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        #if OPENISLAND_APPKIT
        // Isolated validation bundles must never request or deliver user notifications.
        if TestIsolationGuard.isValidationBundle { return }
        #endif
        guard AppPaths.isRunningAsBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
