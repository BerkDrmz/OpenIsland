import Foundation
import IslandCore

/// Progress publications are event-driven; only active transfers retain KVO tokens.
/// The relay coalesces bursts before dispatching to the main actor (at most 10 updates/s/transfer).
@MainActor
@Observable
final class TransferMonitor {
    private struct Transfer {
        let name: String
        let progress: Progress
        var fraction: Double
        let relay: TransferUpdateRelay
        var observations: [NSKeyValueObservation]
    }

    private(set) var fraction: Double = 0
    private(set) var primaryName: String?
    private(set) var isActive = false
    @ObservationIgnored var onActiveChange: ((Bool) -> Void)?
    @ObservationIgnored var onFinished: ((String) -> Void)?
    @ObservationIgnored var onEnded: ((String, TransferOutcome) -> Void)?
    @ObservationIgnored private var transfers: [UUID: Transfer] = [:]
    @ObservationIgnored private var subscribers: [Any] = []
    @ObservationIgnored private var isMonitoring = false
    @ObservationIgnored private var endedProgresses = NSHashTable<Progress>.weakObjects()
    @ObservationIgnored private let folders: [URL]
    var trackedTransferCount: Int { transfers.count }
    var subscriptionCount: Int { subscribers.count }

    init(folders: [URL]? = nil) {
        // NSProgress subscriptions match a folder's direct children, not every descendant.
        // App Store versions that publish NSProgress use application bundle URLs.
        let defaults = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            + FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)
            + FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)
        var seen = Set<URL>()
        self.folders = (folders ?? defaults).map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        for folder in folders {
            let subscriber = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
                let id = UUID()
                MainActor.assumeIsolated { self?.track(progress, id: id) }
                return { MainActor.assumeIsolated { self?.untrack(id) } }
            }
            subscribers.append(subscriber)
        }
    }

    func stop() {
        isMonitoring = false
        // Stop local work before removeSubscriber can synchronously invoke unpublish callbacks.
        for transfer in transfers.values {
            transfer.relay.cancel()
            transfer.observations.forEach { $0.invalidate() }
        }
        transfers.removeAll()
        endedProgresses.removeAllObjects()
        subscribers.forEach(Progress.removeSubscriber)
        subscribers.removeAll()
        publish()
    }

    func track(_ progress: Progress, id: UUID) {
        guard isMonitoring, transfers[id] == nil, !endedProgresses.contains(progress),
              !transfers.values.contains(where: { $0.progress === progress }) else { return }
        let relay = TransferUpdateRelay { [weak self] snapshot in
            MainActor.assumeIsolated { self?.update(id, snapshot: snapshot) }
        }
        // A remote NSProgress proxy can expose fileURL only after its userInfo has been fetched.
        let url = progress.userInfo[.fileURLKey] as? URL ?? progress.fileURL
        transfers[id] = Transfer(name: Self.displayName(for: url), progress: progress,
                                 fraction: Self.safeFraction(progress.fractionCompleted), relay: relay, observations: [])
        let observations = [
            progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in relay.receive(progress) },
            progress.observe(\.isCancelled, options: [.new]) { progress, _ in relay.receive(progress) },
            progress.observe(\.isFinished, options: [.new]) { progress, _ in relay.receive(progress) }
        ]
        transfers[id]?.observations = observations
        if progress.isCancelled || progress.isFinished {
            untrack(id)
        } else {
            publish()
            relay.receive(progress) // closes the registration/read race
        }
    }

    private func update(_ id: UUID, snapshot: TransferUpdateRelay.Snapshot) {
        guard transfers[id] != nil else { return }
        transfers[id]?.fraction = snapshot.fraction
        if snapshot.cancelled || snapshot.finished { untrack(id) } else { publish() }
    }

    func untrack(_ id: UUID) {
        guard let transfer = transfers.removeValue(forKey: id) else { return }
        endedProgresses.add(transfer.progress)
        transfer.relay.cancel()
        transfer.observations.forEach { $0.invalidate() }
        let outcome = TransferOutcome.terminal(fraction: transfer.progress.fractionCompleted,
                                               isFinished: transfer.progress.isFinished,
                                               isCancelled: transfer.progress.isCancelled)
        // Clear active state first; a completed notice must not be suppressed by the transfer's priority.
        publish()
        guard isMonitoring else { return }
        if outcome == .completed { onFinished?(transfer.name) }
        else { onEnded?(transfer.name, outcome) }
    }

    private func publish() {
        let active = !transfers.isEmpty
        let average = active ? transfers.values.reduce(0) { $0 + $1.fraction } / Double(transfers.count) : 0
        let stepped = (average * 100).rounded(.down) / 100
        if stepped != fraction { fraction = stepped }
        let name = transfers.sorted { $0.key.uuidString < $1.key.uuidString }.first?.value.name
        if name != primaryName { primaryName = name }
        if active != isActive { isActive = active; onActiveChange?(active) }
    }

    nonisolated private static func safeFraction(_ fraction: Double) -> Double {
        fraction.isFinite ? min(max(fraction, 0), 1) : 0
    }

    private static func displayName(for url: URL?) -> String {
        guard var url else { return "Dosya" }
        if ["download", "crdownload", "part", "app", "appdownload"].contains(url.pathExtension.lowercased()) { url.deletePathExtension() }
        return url.lastPathComponent
    }
}

/// One cancellable work item per burst; no repeating timer. All cross-thread state is lock protected.
private final class TransferUpdateRelay: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let fraction: Double
        let cancelled: Bool
        let finished: Bool
    }
    private let lock = NSLock()
    private var latest: Snapshot?
    private var delivered: Snapshot?
    private var work: DispatchWorkItem?
    private var closed = false
    private let handler: @Sendable (Snapshot) -> Void
    init(handler: @escaping @Sendable (Snapshot) -> Void) { self.handler = handler }

    func receive(_ progress: Progress) {
        let fraction = progress.fractionCompleted
        let value = Snapshot(fraction: fraction.isFinite ? (min(max(fraction, 0), 1) * 100).rounded(.down) / 100 : 0,
                             cancelled: progress.isCancelled, finished: progress.isFinished)
        lock.lock()
        defer { lock.unlock() }
        guard !closed, value != latest, value != delivered || latest != nil else { return }
        latest = value
        guard work == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.deliver() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    private func deliver() {
        lock.lock()
        let value = closed ? nil : latest
        latest = nil
        work = nil
        delivered = value
        lock.unlock()
        if let value { handler(value) }
    }

    func cancel() {
        lock.lock()
        closed = true
        latest = nil
        work?.cancel()
        work = nil
        lock.unlock()
    }
}
