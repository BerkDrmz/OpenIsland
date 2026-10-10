import Foundation
import Network
import IslandCore

/// Path availability only: no probes, requests, DNS lookups or Wi-Fi scans.
/// A satisfied route does not guarantee the public Internet/server is reachable.
@MainActor
final class NetworkMonitor {
    var onChange: ((Bool) -> Void)?
    private var monitor: NWPathMonitor?
    private var transitions = NetworkTransitionState()
    private var generation: UInt64 = 0
    private let queue = DispatchQueue(label: "OpenIsland.network-path", qos: .utility)
    var isMonitoring: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        generation &+= 1
        let token = generation
        transitions = NetworkTransitionState()
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.monitor != nil, self.generation == token,
                      let changed = self.transitions.update(isAvailable: available) else { return }
                self.onChange?(changed)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        generation &+= 1
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        monitor = nil
        transitions = NetworkTransitionState()
    }
}
