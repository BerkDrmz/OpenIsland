import AppKit
import IslandCore
import SwiftUI

// The controller and image processing are real. Only external players and app handoff are stubbed.
@MainActor class TestMediaSource: MediaSource {
    var id: String
    var isSystemWide: Bool { false }
    var onUpdate: ((NowPlayingInfo?) -> Void)?
    var commands: [MediaCommand] = []
    init(id: String) { self.id = id }
    func start() {}
    func stop() {}
    func perform(_ command: MediaCommand) { commands.append(command) }
    func seek(to time: TimeInterval) async -> Bool { true }
}
@MainActor final class ScriptedPlayerSource: TestMediaSource {
    static let spotify = "test.spotify"
    static let music = "test.music"
    static var instances: [ScriptedPlayerSource] = []
    init(player: String) {
        super.init(id: player)
        Self.instances.append(self)
    }
}
@MainActor final class MediaRemoteAdapterSource: TestMediaSource {
    static func bundledPaths() -> String? { nil }
    init(paths: String) { super.init(id: "test.adapter") }
}
@MainActor final class MediaRemoteSource: TestMediaSource {
    init() { super.init(id: "test.remote") }
}
@MainActor enum MediaRemote {
    static let canReadNowPlayingDirectly = false
    static func send(_ command: MediaCommand) {}
}
@MainActor enum AppHandoff {
    static func reveal(_ application: NSRunningApplication) {}
}

@main struct MediaArtworkCheck {
    @MainActor static func main() {
        func artwork(_ red: UInt8, _ blue: UInt8) -> Data {
            let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 512 * 4, bitsPerPixel: 32)!
            let bytes = image.bitmapData!
            for index in stride(from: 0, to: 512 * 512 * 4, by: 4) {
                bytes[index] = red; bytes[index + 1] = 30; bytes[index + 2] = blue; bytes[index + 3] = 255
            }
            return image.representation(using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.none.rawValue])!
        }
        let red = artwork(230, 20), blue = artwork(20, 230)
        precondition(red.count == blue.count && red != blue, "fixture covers differ but have identical byte counts")
        func info(_ title: String, data: Data?) -> NowPlayingInfo {
            .init(title: title, artist: "Test", album: "Same album", duration: 240, elapsed: 0,
                  timestamp: Date(timeIntervalSince1970: 1), playbackRate: 1, isPlaying: true,
                  artworkData: data, bundleIdentifier: nil)
        }
        let controller = MediaController()
        controller.start()
        let source = ScriptedPlayerSource.instances[0]
        var trackChanges = 0, playbackChanges = 0, sessionEnds = 0
        controller.onTrackChange = { _ in trackChanges += 1 }
        controller.onPlaybackChange = { _ in playbackChanges += 1 }
        controller.onSessionEnd = { sessionEnds += 1 }
        source.onUpdate?(info("first", data: red))
        let firstImage = controller.artwork!
        let firstAccent = controller.accentNSColor
        let firstPulse = controller.pulseNSColor

        func measure(_ body: () -> Void) -> Double {
            let start = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
            body()
            return Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - start) / 1_000_000
        }
        let repeatedCost = measure {
            for index in 0..<500 { source.onUpdate?(info("track \(index)", data: red)) }
        }
        let reused = controller.artwork === firstImage
        let sameAccent = controller.accentNSColor === firstAccent
        let samePulse = controller.pulseNSColor === firstPulse
        let changedCost = measure {
            for index in 0..<100 {
                source.onUpdate?(info("different \(index)", data: index.isMultiple(of: 2) ? blue : red))
            }
        }
        print(String(format: "BENCH: 500 same-cover track changes %.3f ms CPU; 100 changed-cover tracks %.3f ms CPU; same-image reused=%@", repeatedCost, changedCost, String(reused)))
        if ProcessInfo.processInfo.environment["OPENISLAND_ARTWORK_BENCHMARK_ONLY"] == "1" { return }
        precondition(reused && sameAccent && samePulse, "same album must retain decoded image and both derived colors")
        precondition(trackChanges == 600 && playbackChanges == 1, "artwork dedup must preserve track/playback notifications")

        // Independently allocated but equal bytes must also preserve the rendered image.
        source.onUpdate?(info("last", data: red))
        let retainedImage = controller.artwork!
        let copy = red.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        source.onUpdate?(info("another title", data: copy))
        precondition(controller.artwork === retainedImage)
        // Same title and same byte count used to hide an actual cover update.
        source.onUpdate?(info("another title", data: blue))
        precondition(controller.artwork !== retainedImage)
        let pixels = controller.artwork!.samplePixels(side: 1)
        precondition(pixels[0].blue > pixels[0].red, "same-size replacement must render the new blue cover")
        let currentImage = controller.artwork!
        var paused = info("another title", data: blue)
        paused.isPlaying = false
        source.onUpdate?(paused)
        precondition(controller.artwork === currentImage && !controller.isPlaying && playbackChanges == 2)
        controller.nextTrack()
        precondition(source.commands == [.nextTrack], "media commands still route to active source")

        source.onUpdate?(info("missing", data: nil))
        precondition(controller.artwork == nil && controller.pulseNSColor == nil && controller.accentNSColor == .white)
        source.onUpdate?(info("invalid", data: Data([0, 1, 2, 3])))
        precondition(controller.artwork == nil)
        source.onUpdate?(info("recovered", data: red))
        precondition(controller.artwork != nil)
        source.onUpdate?(nil)
        source.onUpdate?(nil)
        precondition(controller.artwork == nil && controller.nowPlaying == nil && sessionEnds == 1)
        source.onUpdate?(info("new session", data: red))
        precondition(controller.artwork != nil, "cleared session must rebuild its artwork")
        controller.stop()
        print("PASS: real MediaController reuses identical cover + colors across 500 tracks; equal-length replacement, independent equal bytes, pause, controls, missing/invalid artwork, recovery, session clear, and track notifications preserved")
    }
}
