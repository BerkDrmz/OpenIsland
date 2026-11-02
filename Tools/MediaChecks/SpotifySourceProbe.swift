// Spotify ilerleme hatası sondası. Uygulamanın GERÇEK ScriptedPlayerSource / NowPlayingInfo / ScriptRunner
// kaynaklarıyla derlenir (kopya değil). Spotify'a hiçbir komut göndermez: yalnızca okur.
// Satır türleri (JSON, kişisel metin yok; parça kimliği yalnızca kısa özet):
//   raw    — dağıtık bildirimin ham sayısal alanları (Player State, Duration, Playback Position, Track ID özeti)
//   model  — kaynağın onUpdate ile yayınladığı NowPlayingInfo: elapsed, timestamp, duration, isPlaying,
//            ve şimdiki anda ekstrapole edilen geçen süre + yüzde (UI'nin gösterdiği değerler bundan hesaplanır)
//   truth  — Spotify'ın kontrol API'sinden salt okuma (player state, player position, duration)
//   tick   — her TICK sn: son model değerinin şimdiye ekstrapolasyonu (UI metni/çubuğu) + truth
// usage: probe [seconds=900] [tick=5]
import AppKit
import CryptoKit
import Foundation

let args = CommandLine.arguments
let total = args.count > 1 ? Double(args[1]) ?? 900 : 900
let tickSeconds = args.count > 2 ? Double(args[2]) ?? 5 : 5
let t0 = Date()

func emit(_ kind: String, _ fields: [String: Any]) {
    var row = fields
    row["kind"] = kind
    row["t"] = (Date().timeIntervalSince(t0) * 1000).rounded() / 1000
    row["epoch"] = Date().timeIntervalSince1970
    if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), let s = String(data: data, encoding: .utf8) {
        print(s); fflush(stdout)
    }
}

func short(_ s: String?) -> String {
    guard let s, !s.isEmpty else { return "" }
    return SHA256.hash(data: Data(s.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
}

func clock(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "?" }
    let s = Int(t.rounded(.down)); return String(format: "%d:%02d", s / 60, s % 60)
}

@MainActor final class Probe {
    let source = ScriptedPlayerSource(player: ScriptedPlayerSource.spotify)
    var last: NowPlayingInfo?
    var rawObserver: NSObjectProtocol?

    func start() {
        // Ham bildirim, kaynağınkiyle aynı ad; ayrı gözlemci (kaynağın davranışını değiştirmez).
        rawObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { note in
            let u = note.userInfo ?? [:]
            var f: [String: Any] = ["state": u["Player State"] as? String ?? "",
                                    "trackID": short(u["Track ID"] as? String),
                                    "keys": (u.keys.compactMap { $0 as? String }).sorted()]
            if let d = u["Duration"] { f["durationRaw"] = "\(d)"; f["durationType"] = "\(type(of: d))" }
            if let p = u["Playback Position"] { f["positionRaw"] = "\(p)"; f["positionType"] = "\(type(of: p))" }
            emit("raw", f)
            MainActor.assumeIsolated { self.readTruth("after-notification") }
        }
        source.onUpdate = { [weak self] info in
            MainActor.assumeIsolated {
                self?.last = info
                guard let info else { emit("model", ["nil": true]); return }
                let now = Date()
                let shown = info.elapsed(at: now)
                emit("model", ["elapsed": info.elapsed, "timestampAge": now.timeIntervalSince(info.timestamp),
                               "duration": info.duration, "isPlaying": info.isPlaying, "rate": info.playbackRate,
                               "shownElapsed": shown, "shownText": clock(shown),
                               "shownRemaining": "-" + clock(max(info.duration - shown, 0)),
                               "progress": info.duration > 0 ? shown / info.duration : -1,
                               "artworkBytes": info.artworkData?.count ?? 0, "track": short(info.trackKey)])
            }
        }
        source.start()
        Timer.scheduledTimer(withTimeInterval: tickSeconds, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }

    func tick() {
        if Date().timeIntervalSince(t0) > total { emit("end", [:]); exit(0) }
        if let info = last {
            let shown = info.elapsed(at: Date())
            emit("tick", ["shownElapsed": shown, "shownText": clock(shown), "duration": info.duration,
                          "progress": info.duration > 0 ? shown / info.duration : -1, "isPlaying": info.isPlaying,
                          "timestampAge": Date().timeIntervalSince(info.timestamp)])
        }
        readTruth("tick")
    }

    /// Salt okuma: player state, player position (sn), duration (ms), id özeti.
    func readTruth(_ why: String) {
        Task.detached {
            let script = NSAppleScript(source: "tell application \"Spotify\" to return {player state as string, player position, duration of current track, id of current track}")
            var error: NSDictionary?
            let d = script?.executeAndReturnError(&error)
            var f: [String: Any] = ["why": why]
            if let d, d.numberOfItems >= 4 {
                f["state"] = d.atIndex(1)?.stringValue ?? ""
                f["position"] = d.atIndex(2)?.doubleValue ?? -1
                f["durationMs"] = d.atIndex(3)?.doubleValue ?? -1
                f["trackID"] = short(d.atIndex(4)?.stringValue)
            } else { f["error"] = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1 }
            emit("truth", f)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let probe = MainActor.assumeIsolated { Probe() }
MainActor.assumeIsolated { probe.start() }
emit("start", ["total": total, "tick": tickSeconds])
app.run()
