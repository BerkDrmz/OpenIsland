import AppKit

// OpenIsland'in Space/tam ekran geçişlerindeki yatay hareketini ölçer (geliştirici aracı, salt okuma).
//
// Pencerenin animasyon sırasındaki gerçek ekran konumu SkyLight'tan (`SLSGetScreenRectForWindow`) ~150 Hz okunur;
// ekran kaydı izni gerekmez. Cihazda doğrulandı: public ayarlı bir pencere bu ölçümde her geçişte 1773–5322 pt
// kayıyor, private Space'teki ada 0,0 pt. Kullanım: ./Scripts/space-probe.sh [saniye]

typealias Conn = Int32
guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
      let connSym = dlsym(sky, "SLSMainConnectionID"), let rectSym = dlsym(sky, "SLSGetScreenRectForWindow"),
      let spacesSym = dlsym(sky, "SLSCopySpacesForWindows"), let activeSym = dlsym(sky, "SLSGetActiveSpace"),
      let managedSym = dlsym(sky, "SLSCopyManagedDisplaySpaces")
else { print("Bu macOS'ta ölçüm arayüzü yok."); exit(1) }
let conn = unsafeBitCast(connSym, to: (@convention(c) () -> Conn).self)()
let screenRect = unsafeBitCast(rectSym, to: (@convention(c) (Conn, UInt32, UnsafeMutablePointer<CGRect>) -> Int32).self)
let copySpaces = unsafeBitCast(spacesSym, to: (@convention(c) (Conn, Int32, CFArray) -> Unmanaged<CFArray>?).self)
let activeSpace = unsafeBitCast(activeSym, to: (@convention(c) (Conn) -> UInt64).self)
let managedSpaces = unsafeBitCast(managedSym, to: (@convention(c) (Conn) -> Unmanaged<CFArray>?).self)

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
let start = Date()
func clock() -> String { String(format: "%6.1f sn", Date().timeIntervalSince(start)) }
func spaceKinds() -> [UInt64: String] {
    var kinds: [UInt64: String] = [:]
    for display in managedSpaces(conn)?.takeRetainedValue() as? [[String: Any]] ?? [] {
        for space in display["Spaces"] as? [[String: Any]] ?? [] {
            if let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value {
                kinds[id] = (space["type"] as? Int) == 4 ? "tam ekran" : "masaüstü"
            }
        }
    }
    return kinds
}
// Her ekranın aktif Space'i ayrıdır. SLSGetActiveSpace yalnızca tek bir ekranı döndürür;
// harici ekrandaki geçişlerin "0 geçiş" diye raporlanmaması için ekran bazında izlenir.
func currentDisplaySpaces() -> [String: UInt64] {
    var result: [String: UInt64] = [:]
    for display in managedSpaces(conn)?.takeRetainedValue() as? [[String: Any]] ?? [] {
        guard let identifier = display["Display Identifier"] as? String,
              let current = display["Current Space"] as? [String: Any],
              let id = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
        result[identifier] = id
    }
    return result
}

func islandWindows() -> [(id: UInt32, bounds: CGRect)] {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    // NotchPanel ve NotchSensorPanel'in seviyeleri. Ayarlar, menüler ve diğer
    // normal OpenIsland pencereleri Space animasyonuna katılabilir; ada değildir.
    let overlayLevels = [NSWindow.Level.mainMenu.rawValue + 3, NSWindow.Level.mainMenu.rawValue + 4]
    return list.compactMap { w in
        guard (w[kCGWindowOwnerName as String] as? String) == "OpenIsland",
              let layer = w[kCGWindowLayer as String] as? Int, overlayLevels.contains(layer),
              let id = w[kCGWindowNumber as String] as? Int,
              let dict = w[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
        return (UInt32(id), bounds)
    }
}

struct Track { var baseX: CGFloat; var maxDeviation: CGFloat = 0; var movingSamples = 0; var everHidden = false }
var tracks: [UInt32: Track] = [:]
var windows = islandWindows()
guard !windows.isEmpty else { print("OpenIsland çalışmıyor. Önce uygulamayı açın."); exit(1) }
var kinds = spaceKinds()
var lastSpace = activeSpace(conn)
var lastDisplaySpaces = currentDisplaySpaces()
var displayLabels = Dictionary(uniqueKeysWithValues: lastDisplaySpaces.keys.sorted().enumerated().map { ($1, "Ekran \($0 + 1)") })
var nextSpaceRefresh = Date()
var transitions = 0, lastWarning = Date.distantPast
print("OpenIsland Space ölçümü: \(Int(seconds)) sn. Şimdi testleri yapın (dört parmak kaydırma, tam ekran, Mission Control…).")
print("Başlangıç Space: \(lastSpace) (\(kinds[lastSpace] ?? "?")) · ada pencereleri: \(windows.map { "#\($0.id)" }.joined(separator: ", "))\n")
if !lastDisplaySpaces.isEmpty {
    print("Ekran bazında başlangıç: " + lastDisplaySpaces.keys.sorted().map { key in
        let id = lastDisplaySpaces[key]!
        return "\(displayLabels[key]!) Space \(id) (\(kinds[id] ?? "?"))"
    }.joined(separator: " · "))
}
var nextRefresh = Date()
while Date().timeIntervalSince(start) < seconds {
    if Date() >= nextRefresh {
        let fresh = islandWindows()
        // Ekran değişiminde ada bilerek yeniden yerleşir: yeni pencere/konum yeni temel olur.
        for window in fresh where tracks[window.id] == nil || abs(tracks[window.id]!.baseX - window.bounds.minX) > 0.5 && tracks[window.id]!.movingSamples == 0 {
            if tracks[window.id] != nil { print("\(clock())  ℹ️ ada yeniden yerleşti (#\(window.id), x=\(window.bounds.minX)) — ekran değişimi olabilir") }
            tracks[window.id] = Track(baseX: window.bounds.minX)
        }
        windows = fresh
        kinds = spaceKinds()
        nextRefresh = Date().addingTimeInterval(0.5)
    }
    if Date() >= nextSpaceRefresh {
        let current = currentDisplaySpaces()
        if current.isEmpty {
            let space = activeSpace(conn)
            if space != lastSpace {
                transitions += 1
                print("\(clock())  Space \(lastSpace) (\(kinds[lastSpace] ?? "?")) → \(space) (\(kinds[space] ?? "?"))")
                lastSpace = space
            }
        } else {
            for key in current.keys.sorted() {
                let space = current[key]!
                if displayLabels[key] == nil { displayLabels[key] = "Ekran \(displayLabels.count + 1)" }
                if let previous = lastDisplaySpaces[key], previous != space {
                    transitions += 1
                    print("\(clock())  \(displayLabels[key]!) Space \(previous) (\(kinds[previous] ?? "?")) → \(space) (\(kinds[space] ?? "?"))")
                } else if lastDisplaySpaces[key] == nil {
                    print("\(clock())  ℹ️ \(displayLabels[key]!) eklendi · Space \(space)")
                }
            }
            for key in lastDisplaySpaces.keys.sorted() where current[key] == nil {
                print("\(clock())  ℹ️ \(displayLabels[key] ?? "Ekran") çıkarıldı")
            }
            lastDisplaySpaces = current
        }
        nextSpaceRefresh = Date().addingTimeInterval(0.1)
    }
    for window in windows {
        var rect = CGRect.zero
        guard screenRect(conn, window.id, &rect) == noErr, var track = tracks[window.id] else { continue }
        let deviation = abs(rect.minX - track.baseX)
        if deviation > 0.5 {
            track.movingSamples += 1
            if Date().timeIntervalSince(lastWarning) > 0.25 {
                print("\(clock())  ❌ ada yatay hareket etti: \(String(format: "%.1f", deviation)) pt (#\(window.id))")
                lastWarning = Date()
            }
        }
        track.maxDeviation = max(track.maxDeviation, deviation)
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], window.id) as? [[String: Any]]
        if !(info?.first?[kCGWindowIsOnscreen as String] as? Bool ?? false) { track.everHidden = true }
        tracks[window.id] = track
    }
    usleep(6_000)
}

print("\n── Sonuç ──")
print("Gözlenen Space değişimi: \(transitions)")
for (id, track) in tracks.sorted(by: { $0.key < $1.key }) {
    let membership = (copySpaces(conn, 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []).map(\.intValue)
    let verdict = track.maxDeviation <= 0.5 ? "SABİT ✅" : "KAYDI ❌"
    print("#\(id): en büyük yatay sapma \(String(format: "%.1f", track.maxDeviation)) pt · hareketli örnek \(track.movingSamples) · "
        + "\(track.everHidden ? "bir an ekrandan ÇIKTI ⚠️" : "hep ekranda") · kayan Space üyeliği \(membership.isEmpty ? "yok" : "\(membership)") → \(verdict)")
}
if transitions == 0 { print("Uyarı: ölçüm sırasında Space değişmedi; testi süre içinde yapın.") }
