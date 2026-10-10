/// Startup establishes a baseline; only subsequent distinct states become notices.
public struct NetworkTransitionState: Sendable {
    private var previous: Bool?
    public init() {}
    public mutating func update(isAvailable: Bool) -> Bool? {
        defer { previous = isAvailable }
        guard let previous, previous != isAvailable else { return nil }
        return isAvailable
    }
}

public enum DisplayChangeKind: Sendable, Equatable, Hashable {
    case connected, disconnected, configuration
}

/// Only external display changes are user-facing. Safe-area/menu-bar changes are excluded.
public struct ExternalDisplayConfiguration: Sendable, Equatable {
    public let id: UInt32
    public let name: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let scale: Double
    public init(id: UInt32, name: String, x: Double, y: Double, width: Double, height: Double, scale: Double) {
        self.id = id; self.name = name; self.x = x; self.y = y
        self.width = width; self.height = height; self.scale = scale
    }
}

public struct ExternalDisplayTransitions: Sendable {
    private var previous: [UInt32: ExternalDisplayConfiguration]
    public init(_ initial: [ExternalDisplayConfiguration]) {
        previous = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0) })
    }
    public mutating func update(_ configurations: [ExternalDisplayConfiguration]) -> [(String, DisplayChangeKind)] {
        let next = Dictionary(uniqueKeysWithValues: configurations.map { ($0.id, $0) })
        defer { previous = next }
        var events: [(String, DisplayChangeKind)] = []
        for id in previous.keys.sorted() where next[id] == nil { events.append((previous[id]!.name, .disconnected)) }
        for id in next.keys.sorted() {
            if previous[id] == nil { events.append((next[id]!.name, .connected)) }
            else if next[id] != previous[id] { events.append((next[id]!.name, .configuration)) }
        }
        return events
    }
}

public enum TransferOutcome: Sendable, Equatable, Hashable {
    case completed, cancelled, interrupted
    public static func terminal(fraction: Double, isFinished: Bool, isCancelled: Bool) -> Self {
        if isCancelled { return .cancelled }
        return isFinished || fraction >= 1 ? .completed : .interrupted
    }
}
