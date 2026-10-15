// Kontrastı Artır + Tam Klavye Erişimi canlı testi, yalnızca TEST örneğinde (PID).
// 1) Adayı genişletir ve iğneler; her sekmeye AXPress ile geçer, 1,6 sn sonra iki ekran görüntüsü alır (oturmuş kare kontrolü).
// 2) Klavye: odağı Medya sekme düğmesine verir; Tab'ı N kez, sonra Shift-Tab'ı N kez YALNIZCA bu sürece gönderir
//    (CGEvent.postToPid) ve her adımda uygulamanın odaktaki öğesini (rol/etiket) yazar.
// usage: axtabs PID OUTDIR CX [tabCount]
import AppKit
import ApplicationServices

let pid = pid_t(CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
let cx = Int(CommandLine.arguments[3])!
let tabCount = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4])! : 14
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func all(_ e: AXUIElement) -> [AXUIElement] { [e] + ((attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []).flatMap(all) }
func label(_ e: AXUIElement) -> String { (attr(e, kAXDescriptionAttribute) as? String) ?? (attr(e, kAXTitleAttribute) as? String) ?? "" }
func elements() -> [AXUIElement] { ((attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).flatMap(all) }
func button(_ name: String) -> AXUIElement? { elements().first { label($0) == name && (attr($0, kAXRoleAttribute) as? String) == "AXButton" } }
func press(_ name: String) -> Bool { button(name).map { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success } ?? false }
func shot(_ name: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R", "\(cx - 360),0,720,190", "\(out)/\(name).png"]; try? p.run(); p.waitUntilExit()
}

if let root = elements().first(where: { label($0) == "OpenIsland" }) {
    var names: CFArray?; AXUIElementCopyActionNames(root, &names)
    if let expand = (names as? [String])?.first(where: { $0.contains("Genişlet") }) { _ = AXUIElementPerformAction(root, expand as CFString) }
}
var ok = false
for _ in 0..<10 where !ok { Thread.sleep(forTimeInterval: 0.5); ok = press("Medya") }
_ = press("Adayı açık tut")
print("expanded", ok)
for tab in (ProcessInfo.processInfo.environment["NOSHOTS"] == "1" ? [] : ["Medya", "Nook", "Raf", "Pano", "Notlar", "Sistem"]) {
    let pressed = press(tab)
    Thread.sleep(forTimeInterval: 1.6)
    shot("\(tab)-a"); Thread.sleep(forTimeInterval: 0.4); shot("\(tab)-b")
    print("tab", tab, pressed)
}
_ = press("Nook"); Thread.sleep(forTimeInterval: 1.2)

// Klavye
func focused() -> String {
    guard let f = attr(app, kAXFocusedUIElementAttribute) else { return "-" }
    let e = f as! AXUIElement
    let help = (attr(e, kAXHelpAttribute) as? String) ?? ""
    return "\(attr(e, kAXRoleAttribute) as? String ?? "?")|\(label(e))|\(help)"
}
func key(_ code: CGKeyCode, shift: Bool) {
    for down in [true, false] {
        let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        if shift { ev.flags = .maskShift }
        ev.postToPid(pid)
    }
    Thread.sleep(forTimeInterval: 0.35)
}
// Panel yalnızca anahtar pencereyken klavye olayı alır: test örneğini öne al, penceresine ve düğmeye odak ver.
let previousFront = NSWorkspace.shared.frontmostApplication
_ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where elements().contains(where: { label($0) == "Medya" }) {
    _ = AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
}
Thread.sleep(forTimeInterval: 0.5)
if let start = button("Medya") {
    let set = AXUIElementSetAttributeValue(start, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.4)
    print("focus-set", set == .success, focused())
}
for i in 1...tabCount { key(48, shift: false); print("tab+\(i)", focused()) }
for i in 1...tabCount { key(48, shift: true); print("shift-tab+\(i)", focused()) }
// Kullanıcının öndeki uygulamasını geri getir.
if let previousFront, previousFront.processIdentifier != pid { previousFront.activate() }
