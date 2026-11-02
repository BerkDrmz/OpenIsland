// Gerçek MediaPanel doğrulaması: test örneğinin (PID) erişilebilirlik ağacından adayı genişletir, Medya sekmesini seçer,
// iğneyle açık tutar; sonra her TICK sn'de panelin GÖSTERDİĞİ süre metinlerini (kaydırıcının "geçen / toplam" AX değeri ve
// geçen/kalan etiketleri), oynat/duraklat düğmesinin etiketini ve Spotify'ın gerçek konumunu (salt okuma) kaydeder.
// Yalnızca test örneğinde eylem yapar; Spotify'a komut göndermez. usage: axmedia PID [seconds] [tick]
import AppKit
import ApplicationServices

guard AXIsProcessTrusted() else { print("not trusted"); exit(2) }
let pid = pid_t(CommandLine.arguments[1])!
let total = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 600
let tick = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3])! : 2
let app = AXUIElementCreateApplication(pid)
let t0 = Date()

func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func all(_ e: AXUIElement) -> [AXUIElement] { [e] + ((attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []).flatMap(all) }
func label(_ e: AXUIElement) -> String { (attr(e, kAXDescriptionAttribute) as? String) ?? (attr(e, kAXTitleAttribute) as? String) ?? "" }
func value(_ e: AXUIElement) -> String { (attr(e, "AXValueDescription") as? String) ?? (attr(e, kAXValueAttribute) as? String) ?? "" }
func elements() -> [AXUIElement] { ((attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).flatMap(all) }
func press(_ name: String) -> Bool {
    guard let e = elements().first(where: { label($0) == name && (attr($0, kAXRoleAttribute) as? String) == "AXButton" }) else { return false }
    return AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
}
func emit(_ f: [String: Any]) {
    var row = f; row["t"] = (Date().timeIntervalSince(t0) * 10).rounded() / 10
    if let d = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) { print(String(data: d, encoding: .utf8)!); fflush(stdout) }
}

// 1) Genişlet (kökün özel erişilebilirlik eylemi), 2) Medya sekmesi, 3) iğne.
if let root = elements().first(where: { label($0) == "OpenIsland" }) {
    var names: CFArray?
    AXUIElementCopyActionNames(root, &names)
    if let expand = (names as? [String])?.first(where: { $0.contains("Genişlet") }) {
        emit(["step": "expand", "ok": AXUIElementPerformAction(root, expand as CFString) == .success])
    }
}
Thread.sleep(forTimeInterval: 1.0)
emit(["step": "media", "ok": press("Medya")])
Thread.sleep(forTimeInterval: 0.6)
emit(["step": "pin", "ok": press("Adayı açık tut")])

let clock = try! NSRegularExpression(pattern: "^-?\\d+:\\d{2}( / \\d+:\\d{2})?$")
while Date().timeIntervalSince(t0) < total {
    let els = elements()
    var shown: [String] = []
    var playButton = ""
    for e in els {
        for s in [value(e), label(e)] where !s.isEmpty {
            if clock.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { shown.append(s) }
        }
        let l = (attr(e, kAXHelpAttribute) as? String) ?? label(e)
        if l == "Oynat" || l == "Duraklat" { playButton = l }
    }
    let script = NSAppleScript(source: "tell application \"Spotify\" to return {player state as string, player position, duration of current track}")
    var err: NSDictionary?
    let d = script?.executeAndReturnError(&err)
    emit(["shown": Array(Set(shown)).sorted(), "button": playButton,
          "truthState": d?.atIndex(1)?.stringValue ?? "", "truthPosition": d?.atIndex(2)?.doubleValue ?? -1,
          "truthDuration": (d?.atIndex(3)?.doubleValue ?? -1000) / 1000])
    Thread.sleep(forTimeInterval: tick)
}
