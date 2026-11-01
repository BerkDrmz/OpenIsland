import AVFoundation
import Foundation

/// Yeniden kodlamadan kapsayıcı değişimi (AVFoundation passthrough): ayrı görüntü + ses → MP4, birleşik akıştan
/// yalnız ses → M4A. Çözünürlük, bit hızı veya codec değişmez; FFmpeg gerekmez.
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
        let duration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let cv = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try cv?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: v, at: .zero)
        cv?.preferredTransform = try await v.load(.preferredTransform)
        let ca = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        try ca?.insertTimeRange(CMTimeRange(start: .zero, duration: min(duration, audioDuration)), of: a, at: .zero)
        try await export(composition, to: output, type: .mp4, handle: handle)
    }

    static func extractAudio(from source: URL, to output: URL, handle: Handle) async throws {
        let asset = AVURLAsset(url: source)
        guard let a = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noTrack }
        let composition = AVMutableComposition()
        let ca = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        try ca?.insertTimeRange(try await a.load(.timeRange), of: a, at: .zero)
        try await export(composition, to: output, type: .m4a, handle: handle)
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
