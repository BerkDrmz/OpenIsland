import Foundation
import IOBluetooth
import CoreBluetooth
import IslandCore

/// UI ownership remains on the main actor. IOBluetooth's synchronous coordinator/registration
/// may wait on the system Bluetooth service; it must never block application launch or hover.
@MainActor
final class BluetoothConnectionMonitor {
    var onConnected: ((String, AudioOutputKind) -> Void)?
    var onDisconnected: ((String, AudioOutputKind) -> Void)?
    private var enabled = false
    private var generation: UInt64 = 0
    private var ready = false
    private lazy var source = BluetoothEventSource(
        onReady: { [weak self] token, ready in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.enabled, self.generation == token else { return }
                self.ready = ready
            }
        }, onEvent: { [weak self] token, name, kind, connected in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.enabled, self.generation == token else { return }
                if connected { self.onConnected?(name, kind) }
                else { self.onDisconnected?(name, kind) }
            }
        })

    var isMonitoring: Bool {
        ready && enabled && CBManager.authorization != .denied && CBManager.authorization != .restricted
    }

    func start() {
        guard !enabled else { return }
        enabled = true
        ready = false
        generation &+= 1
        source.setRunning(true, generation: generation)
    }

    func stop() {
        guard enabled else { return }
        enabled = false
        ready = false
        generation &+= 1
        source.setRunning(false, generation: generation)
    }
}

/// Exactly one serial source/queue for the monitor's entire lifetime, including rapid start/stop.
/// Desired state is locked; all IOBluetooth objects, registrations and dedup state are queue-owned.
private final class BluetoothEventSource: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "OpenIsland.bluetooth-events", qos: .utility)
    private let lock = NSLock()
    private var desired: (running: Bool, generation: UInt64) = (false, 0)
    private var connection: IOBluetoothUserNotification?
    private var disconnections: [String: IOBluetoothUserNotification] = [:]
    private var state = BluetoothConnectionState()
    private let onReady: @Sendable (UInt64, Bool) -> Void
    private let onEvent: @Sendable (UInt64, String, AudioOutputKind, Bool) -> Void

    init(onReady: @escaping @Sendable (UInt64, Bool) -> Void,
         onEvent: @escaping @Sendable (UInt64, String, AudioOutputKind, Bool) -> Void) {
        self.onReady = onReady
        self.onEvent = onEvent
        super.init()
    }

    func setRunning(_ running: Bool, generation: UInt64) {
        lock.lock(); desired = (running, generation); lock.unlock()
        queue.async { [weak self] in self?.reconcile(generation) }
    }

    private func desiredState() -> (running: Bool, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return desired
    }

    private func reconcile(_ generation: UInt64) {
        let intent = desiredState()
        guard intent.generation == generation else { return }
        guard intent.running else { unregister(); return }
        if connection == nil {
            connection = IOBluetoothDevice.register(forConnectNotifications: self,
                                                     selector: #selector(didConnect(_:device:)))
            if connection != nil {
                let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.isConnected() }
                state.seed(Set(devices.compactMap(\.addressString)))
                devices.forEach(observeDisconnect)
            }
        }
        // A stop can arrive while the system registration is waiting. Never resurrect it.
        let latest = desiredState()
        guard latest.running else { unregister(); return }
        onReady(latest.generation, connection != nil)
    }

    private func unregister() {
        connection?.unregister(); connection = nil
        disconnections.values.forEach { $0.unregister() }
        disconnections.removeAll()
        state.seed([])
    }

    private func observeDisconnect(_ device: IOBluetoothDevice) {
        guard let address = device.addressString, disconnections[address] == nil else { return }
        disconnections[address] = device.register(forDisconnectNotification: self,
                                                   selector: #selector(didDisconnect(_:device:)))
    }

    private static func kind(_ device: IOBluetoothDevice) -> AudioOutputKind {
        guard device.deviceClassMajor == kBluetoothDeviceClassMajorAudio else { return .bluetooth }
        return device.deviceClassMinor == kBluetoothDeviceClassMinorAudioLoudspeaker ? .external : .headphones
    }

    @objc private func didConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        let intent = desiredState()
        guard intent.running else { return }
        let token = ObjectIdentifier(notification)
        let name = BluetoothConnectionState.displayName(device.name), kind = Self.kind(device)
        queue.async { [weak self] in
            guard let self, self.desiredState().running, self.desiredState().generation == intent.generation, let connection = self.connection,
                  ObjectIdentifier(connection) == token, self.state.connect(address) else { return }
            if let current = IOBluetoothDevice(addressString: address) { self.observeDisconnect(current) }
            self.emit(name, kind: kind, connected: true, generation: intent.generation)
            // Device can disconnect before the disconnect observer is registered.
            if let current = IOBluetoothDevice(addressString: address), !current.isConnected() {
                self.disconnections.removeValue(forKey: address)?.unregister()
                self.state.disconnect(address)
                self.emit(name, kind: kind, connected: false, generation: intent.generation)
            }
        }
    }

    @objc private func didDisconnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        let intent = desiredState()
        guard intent.running else { return }
        let token = ObjectIdentifier(notification)
        let name = BluetoothConnectionState.displayName(device.name), kind = Self.kind(device)
        queue.async { [weak self] in
            guard let self, self.desiredState().running, self.desiredState().generation == intent.generation, let registered = self.disconnections[address],
                  ObjectIdentifier(registered) == token else { return }
            registered.unregister()
            self.disconnections[address] = nil
            self.state.disconnect(address)
            self.emit(name, kind: kind, connected: false, generation: intent.generation)
        }
    }

    private func emit(_ name: String, kind: AudioOutputKind, connected: Bool, generation: UInt64) {
        let intent = desiredState()
        if intent.running, intent.generation == generation { onEvent(generation, name, kind, connected) }
    }
}
