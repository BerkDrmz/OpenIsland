import Foundation
import IslandCore

// Only platform registrations are faked; the real monitor/source/callback lifecycle is compiled below.
let kBluetoothDeviceClassMajorAudio = 4
let kBluetoothDeviceClassMinorAudioLoudspeaker = 5
enum CBManager { static let authorization = Authorization.allowed }
enum Authorization { case allowed, denied, restricted }
final class FakeBTState: @unchecked Sendable {
    static let shared = FakeBTState()
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var registrations = 0
    private var tokens: [UUID: IOBluetoothUserNotification] = [:]
    private var latest: IOBluetoothUserNotification?
    func add(_ token: IOBluetoothUserNotification) -> Bool {
        lock.lock(); defer { lock.unlock() }
        tokens[token.id] = token; registrations += 1; latest = token
        return registrations == 1
    }
    func remove(_ token: IOBluetoothUserNotification) { lock.lock(); tokens[token.id] = nil; lock.unlock() }
    var active: Int { lock.lock(); defer { lock.unlock() }; return tokens.count }
    var count: Int { lock.lock(); defer { lock.unlock() }; return registrations }
    var connection: IOBluetoothUserNotification? { lock.lock(); defer { lock.unlock() }; return latest }
}
final class IOBluetoothUserNotification: NSObject, @unchecked Sendable {
    let id = UUID()
    weak var target: NSObject?
    let callback: Selector
    init(target: Any, callback: Selector) { self.target = target as? NSObject; self.callback = callback }
    func unregister() { FakeBTState.shared.remove(self) }
    func emit(_ device: IOBluetoothDevice) { target?.perform(callback, with: self, with: device) }
}
final class IOBluetoothDevice: NSObject {
    let addressString: String? = "fake-device"
    let name: String? = "Fake Speaker"
    let deviceClassMajor = kBluetoothDeviceClassMajorAudio
    let deviceClassMinor = kBluetoothDeviceClassMinorAudioLoudspeaker
    convenience init?(addressString: String) { self.init() }
    func isConnected() -> Bool { true }
    static func pairedDevices() -> [Any] { [] }
    static func register(forConnectNotifications target: Any, selector: Selector) -> IOBluetoothUserNotification? {
        precondition(!Thread.isMainThread, "Synchronous Bluetooth initialization still blocks the main thread")
        let token = IOBluetoothUserNotification(target: target, callback: selector)
        if FakeBTState.shared.add(token) { FakeBTState.shared.gate.wait() }
        return token
    }
    func register(forDisconnectNotification target: Any, selector: Selector) -> IOBluetoothUserNotification? {
        precondition(!Thread.isMainThread)
        let token = IOBluetoothUserNotification(target: target, callback: selector)
        _ = FakeBTState.shared.add(token)
        return token
    }
}

@main struct BluetoothCheck {
    @MainActor static func main() async throws {
        let monitor = BluetoothConnectionMonitor()
        let started = ContinuousClock.now
        monitor.start(); monitor.start()
        precondition(started.duration(to: .now) < .milliseconds(100))
        try await wait { FakeBTState.shared.count == 1 }
        monitor.stop()
        precondition(!monitor.isMonitoring)
        FakeBTState.shared.gate.signal()
        try await wait { FakeBTState.shared.active == 0 }
        monitor.start()
        try await wait { monitor.isMonitoring }
        var connects = 0
        monitor.onConnected = { _, kind in precondition(kind == .external); connects += 1 }
        // The latest token is the connection registration before the emitted event installs disconnect tracking.
        let connection = FakeBTState.shared.connection!
        connection.emit(IOBluetoothDevice()); connection.emit(IOBluetoothDevice())
        try await wait { connects == 1 }
        try await Task.sleep(for: .milliseconds(50))
        precondition(connects == 1)
        for _ in 0..<100 { monitor.stop(); monitor.start() }
        monitor.stop()
        try await wait { FakeBTState.shared.active == 0 }
        connection.emit(IOBluetoothDevice()) // stale delivery after shutdown
        try await Task.sleep(for: .milliseconds(50))
        precondition(connects == 1 && !monitor.isMonitoring)
        print("PASS: real Bluetooth bridge with blocked platform registration: main stays responsive, stop cancels desired start, duplicate/stale callbacks ignored; 100 toggles leave 0 registrations")
    }
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out")
    }
}
