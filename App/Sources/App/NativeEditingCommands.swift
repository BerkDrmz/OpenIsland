import AppKit

/// Accessory apps still need an edit menu for Cocoa to resolve the standard
/// command-key equivalents through the current first responder. This menu does
/// not activate the app, observe input, or read/write the pasteboard itself.
@MainActor
enum NativeEditingCommands {
    private static var routingMenu: NSMenu?
    private static weak var installedMainMenu: NSMenu?
    private static let editingActions: Set<Selector> = [
        Selector(("undo:")), Selector(("redo:")), #selector(NSText.cut(_:)),
        #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:))
    ]

    private static func installRoutingMenu(from menu: NSMenu, main: NSMenu) {
        let routing = NSMenu()
        for item in menu.items {
            if let action = item.action, editingActions.contains(action),
               let copy = item.copy() as? NSMenuItem {
                routing.addItem(copy)
            }
        }
        routingMenu = routing
        installedMainMenu = main
    }

    /// A nonactivating panel may receive key events while another app owns the
    /// menu bar. Resolve its own Cocoa edit equivalents, not that other app's.
    static func route(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command),
              window.isKeyWindow, window.firstResponder is NSText else { return false }
        return routingMenu?.performKeyEquivalent(with: event) == true
    }

    static func install() {
        let main = NSApp.mainMenu ?? NSMenu()
        if installedMainMenu === main, routingMenu != nil { return }
        func existingEditMenu(_ menu: NSMenu) -> NSMenu? {
            if menu.items.contains(where: { $0.action == Selector(("undo:")) }) { return menu }
            for item in menu.items {
                if let submenu = item.submenu, let found = existingEditMenu(submenu) { return found }
            }
            return nil
        }
        if let existing = existingEditMenu(main) {
            installRoutingMenu(from: existing, main: main)
            return
        }
        if main.items.isEmpty {
            let application = NSMenuItem()
            let applicationMenu = NSMenu(title: "OpenIsland")
            applicationMenu.addItem(withTitle: "OpenIsland’dan Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            application.submenu = applicationMenu
            main.addItem(application)
        }

        let editing = NSMenuItem()
        let menu = NSMenu(title: "Düzen")
        menu.addItem(withTitle: "Geri Al", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Yinele", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Tümünü Seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editing.submenu = menu
        main.addItem(editing)
        NSApp.mainMenu = main
        installRoutingMenu(from: menu, main: main)
    }
}
