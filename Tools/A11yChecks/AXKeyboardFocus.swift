// Tam Klavye Erişimi testi (TEST örneği; kurulu uygulama geçici olarak kapalıyken).
// Ürünün kendi yolu: Ctrl-Option-Cmd-I kısayolu adayı açar ve paneli anahtar pencere yapar. Ardından Tab'ı N, Shift-Tab'ı N kez
// YALNIZCA test sürecine gönderir ve her adımda odaktaki öğeyi (rol | etiket | yardım) yazar; sonunda Escape ile kapatır.
// usage: axkeys PID [N]
import AppKit
import ApplicationServices

let pid = pid_t(CommandLine.arguments[1])!
let n = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 16
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil }
func focused() -> String {
    guard let f = attr(app, kAXFocusedUIElementAttribute) else { return "-" }
    let e = f as! AXUIElement
    let label = (attr(e, kAXDescriptionAttribute) as? String) ?? (attr(e, kAXTitleAttribute) as? String) ?? ""
    return "\(attr(e, kAXRoleAttribute) as? String ?? "?") | \(label) | \((attr(e, kAXHelpAttribute) as? String) ?? "")"
}
func key(_ code: CGKeyCode, flags: CGEventFlags = [], hid: Bool = false) {
    for down in [true, false] {
        let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        ev.flags = flags
        if hid { ev.post(tap: .cghidEventTap) } else { ev.postToPid(pid) }
    }
    Thread.sleep(forTimeInterval: 0.35)
}
let previousFront = NSWorkspace.shared.frontmostApplication
key(34, flags: [.maskControl, .maskAlternate, .maskCommand], hid: true) // I
Thread.sleep(forTimeInterval: 1.5)
print("after-hotkey", focused())
for i in 1...n { key(48); print("tab+\(i)", focused()) }
for i in 1...n { key(48, flags: .maskShift); print("shift-tab+\(i)", focused()) }
key(53) // Escape: adayı kapat
if let previousFront, previousFront.processIdentifier != pid { previousFront.activate() }
