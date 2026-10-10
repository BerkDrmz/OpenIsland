import Foundation

/// Seeded once, then updated only by connection events. No timers or name-based identity.
public struct BluetoothConnectionState: Sendable {
    private var connected: Set<String> = []
    public init() {}

    public mutating func seed(_ identifiers: Set<String>) { connected = identifiers }
    public mutating func connect(_ identifier: String) -> Bool {
        !identifier.isEmpty && connected.insert(identifier).inserted
    }
    public mutating func disconnect(_ identifier: String) { connected.remove(identifier) }

    public static func displayName(_ name: String?) -> String {
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? "Bluetooth cihazı" : clean
    }
}
