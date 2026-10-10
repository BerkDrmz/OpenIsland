import AppKit
import IslandCore

@MainActor final class NSScreen {
    static var screens: [NSScreen] = []
    var frame: CGRect
    var visibleFrame: CGRect
    var safeAreaInsets: NSEdgeInsets
    var auxiliaryTopLeftArea: CGRect?
    var auxiliaryTopRightArea: CGRect?
    let backingScaleFactor: CGFloat
    let localizedName = "Controlled display"
    let deviceDescription: [NSDeviceDescriptionKey: Any]
    init(id: UInt32, frame: CGRect, safeTop: CGFloat, scale: CGFloat) {
        self.frame = frame
        visibleFrame = frame.insetBy(dx: 0, dy: 0)
        safeAreaInsets = NSEdgeInsets(top: safeTop, left: 0, bottom: 0, right: 0)
        backingScaleFactor = scale
        deviceDescription = [NSDeviceDescriptionKey("NSScreenNumber"): id]
        if safeTop > 0 {
            auxiliaryTopLeftArea = CGRect(x: frame.minX, y: frame.maxY - safeTop, width: 762.5, height: safeTop)
            auxiliaryTopRightArea = CGRect(x: frame.maxX - 762.5, y: frame.maxY - safeTop, width: 762.5, height: safeTop)
        }
    }
}
@MainActor final class NSStatusBar {
    static let system = NSStatusBar()
    let thickness: CGFloat = 24
}
func CGDisplayIsBuiltin(_ id: UInt32) -> Int32 { id == 1 ? 1 : 0 }

@main struct ScreenGeometryCheck {
    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(1400)) }
    @MainActor static func main() async {
        let builtIn = NSScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1710, height: 1107), safeTop: 33.5, scale: 2)
        let external = NSScreen(id: 2, frame: CGRect(x: 1710, y: 27, width: 1920, height: 1080), safeTop: 0, scale: 1)
        external.visibleFrame.size.height -= 24
        NSScreen.screens = [builtIn, external]
        let manager = ScreenManager()
        var updates = 0
        manager.onChange = { _ in updates += 1 }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // İlk gecikmiş okumada henüz eski değer var; ikinci okuma animasyonun son geometrisini yakalamalı.
        try? await Task.sleep(for: .milliseconds(650))
        external.visibleFrame.size.height -= 16
        await settle()
        precondition(manager.screens.first { $0.id == 2 }?.menuBarHeight == 40)
        print("PASS: settled Space transition replaces stale visibleFrame after the first reading")
        precondition(manager.screens.first { $0.id == 1 }?.metrics.notchSize.height == 33.5)
        precondition(manager.screens.first { $0.id == 2 }?.hasNotch == false)
        precondition(manager.targets(for: .primary).map(\.id) == [1])
        print("PASS: per-display notch and primary selection stay independent")

        external.frame.origin = CGPoint(x: -1920, y: -300)
        external.visibleFrame = external.frame
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await settle()
        precondition(manager.screens.first { $0.id == 2 }?.frame == external.frame)
        precondition(manager.screens.first { $0.id == 2 }?.metrics.floatOffset == 29)
        print("PASS: application switch rereads display arrangement and hidden menu-bar geometry")

        let unchanged = updates
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await settle()
        precondition(updates == unchanged)
        print("PASS: unchanged geometry does not trigger island placement")

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        manager.stop()
        external.visibleFrame.size.height -= 50
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await settle()
        precondition(updates == unchanged)
        print("PASS: shutdown cancels pending refresh and removes observers from both centers")
    }
}
