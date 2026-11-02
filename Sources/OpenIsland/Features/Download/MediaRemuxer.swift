import AVFoundation
import Foundation
import IslandCore

/// Yeniden kodlamadan kapsayıcı değişimi (AVFoundation passthrough): ayrı görüntü + ses → MP4, birleşik akıştan
/// yalnız ses → M4A, yalnız görüntü → sessiz MP4. Çözünürlük, bit hızı veya codec değişmez; FFmpeg gerekmez.
/// Parçalı (DASH) kaynakta süre dosyanın başlığından alınır: AVFoundation YouTube DASH süresini iki katı okur.
enum MediaRemuxer {
    enum Failure: Error { case noTrack, exportFailed, cancelled }

    /// Dışa aktarma sürerken iptal edilebilsin diye oturum dışarıya verilir.
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var session: AVAssetExportSession?
        private var cancelled = false
        func attach(_ s: AVAssetExportSession) -> Bool {
            lock.withLock { session = s; return !cancelled }
        }
        func cancel() { lock.withLock { cancelled = true; return session }?.cancelExport() }
    }

    static func merge(video: URL, audio: URL, to output: URL, handle: Handle) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        guard let v = try await videoAsset.loadTracks(withMediaType: .video).first,
              let a = try await audioAsset.loadTracks(withMediaType: .audio).first else { throw Failure.noTrack }
        let duration = try await realDuration(videoAsset, video)
        let audioDuration = try await realDuration(audioAsset, audio)
        let cv = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try cv?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: v, at: .zero)
        cv?.preferredTransform = try await v.load(.preferredTransform)
        let ca = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        try ca?.insertTimeRange(CMTimeRange(start: .zero, duration: min(duration, audioDuration)), of: a, at: .zero)
        try await export(composition, to: output, type: .mp4, handle: handle)
    }

    static func extractAudio(from source: URL, to output: URL, handle: Handle) async throws {
        try await copy(source, tracks: [.audio], to: output, type: .m4a, handle: handle)
    }

    static func extractVideo(from source: URL, to output: URL, handle: Handle) async throws {
        try await copy(source, tracks: [.video], to: output, type: .mp4, handle: handle)
    }

    /// Parçalı (DASH) tek dosya sıradan MP4/M4A'ya taşınır: oynatıcılar doğru süreyi gösterir. Sıradan dosyada nil.
    static func normalizedType(_ file: URL) async -> AVFileType? {
        guard declaredDuration(file) != nil else { return nil }
        let hasVideo = (try? await AVURLAsset(url: file).loadTracks(withMediaType: .video).isEmpty) == false
        return hasVideo ? .mp4 : .m4a
    }

    static func normalize(_ source: URL, type: AVFileType, to output: URL, handle: Handle) async throws {
        try await copy(source, tracks: [.video, .audio], to: output, type: type, handle: handle)
    }

    private static func copy(_ source: URL, tracks kinds: [AVMediaType], to output: URL, type: AVFileType, handle: Handle) async throws {
        let asset = AVURLAsset(url: source)
        let limit = try await realDuration(asset, source)
        let composition = AVMutableComposition()
        var copied = 0
        for kind in kinds {
            guard let track = try await asset.loadTracks(withMediaType: kind).first else { continue }
            let range = try await track.load(.timeRange)
            let target = composition.addMutableTrack(withMediaType: kind, preferredTrackID: kCMPersistentTrackID_Invalid)
            try target?.insertTimeRange(CMTimeRange(start: range.start, duration: min(range.duration, limit)), of: track, at: .zero)
            if kind == .video { target?.preferredTransform = try await track.load(.preferredTransform) }
            copied += 1
        }
        guard copied > 0 else { throw Failure.noTrack }
        try await export(composition, to: output, type: type, handle: handle)
    }

    /// AVFoundation'ın okuduğu süre; parçalı dosya başlığında daha kısa bir süre bildiriyorsa o (gerçek içerik).
    private static func realDuration(_ asset: AVURLAsset, _ url: URL) async throws -> CMTime {
        let read = try await asset.load(.duration)
        guard let declared = declaredDuration(url) else { return read }
        return min(read, CMTime(seconds: declared, preferredTimescale: 90_000))
    }

    /// Başlıktaki (en çok 256 KB) parçalı MP4 süresi.
    static func declaredDuration(_ url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 256 << 10)).flatMap(FragmentedMP4.declaredDuration)
    }

    private static func export(_ asset: AVAsset, to output: URL, type: AVFileType, handle: Handle) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw Failure.exportFailed }
        session.outputURL = output
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = false
        guard handle.attach(session) else { throw Failure.cancelled }
        nonisolated(unsafe) let s = session
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in s.exportAsynchronously { c.resume() } }
        switch s.status {
        case .completed: return
        case .cancelled: throw Failure.cancelled
        default: throw Failure.exportFailed
        }
    }
}
