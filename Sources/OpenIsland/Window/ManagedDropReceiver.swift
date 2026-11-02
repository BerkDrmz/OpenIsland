import AppKit
import IslandCore

/// AppKit's drag destination lookup excludes the unmanaged Space used by the
/// visible island. A *drag-only* managed window supplies the native destination;
/// the existing visual/sensor windows keep their stationary Space membership.
/// No polling, mouseMoved monitor, display link or idle timer is installed.
@MainActor
final class ManagedDropReceiver {
    /// Read-only lifecycle verification; never observed by the UI.
    static var monitoringState: (receivers: Int, monitors: Int, lifecycleObservers: Int) { DropGestureMonitor.shared.state }
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .URL, .string]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    var onEnter: ((CGPoint) -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onExit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDrop: ((NSPasteboard, CGPoint) -> Bool)?

    private var frame: CGRect
    private var enabled = true
    private var window: NSPanel?
    private var entered = false
    private var delivered = false
    private let view = DropView()

    init(frame: CGRect) {
        self.frame = frame
        view.owner = self
        DropGestureMonitor.shared.add(self)
    }

    func update(frame: CGRect, enabled: Bool) {
        self.frame = frame
        self.enabled = enabled
        if !enabled { end() }
        if let window, window.isVisible, window.frame != frame {
            window.setFrame(frame, display: false)
        }
    }

    func stop() {
        DropGestureMonitor.shared.remove(self)
        end()
        window?.close()
        window = nil
    }

    fileprivate func begin() {
        guard enabled else { return }
        if window == nil {
            let panel = DropPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.collectionBehavior = PublicStationaryProvider.collectionBehavior
            panel.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue + 5)
            panel.contentView = view
            panel.setAccessibilityElement(false)
            window = panel
        }
        entered = false
        delivered = false
        window?.setFrame(frame, display: false)
        window?.ignoresMouseEvents = false
        window?.orderFrontRegardless()
    }

    fileprivate func end() {
        guard entered || delivered || window?.isVisible == true else { return }
        let cancelled = entered && !delivered
        entered = false
        delivered = false
        window?.ignoresMouseEvents = true
        window?.orderOut(nil)
        if cancelled { onCancel?() }
    }

    fileprivate var containsMouse: Bool { frame.contains(NSEvent.mouseLocation) }

    private final class DropPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class DropView: NSView {
        weak var owner: ManagedDropReceiver?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor
            registerForDraggedTypes(ManagedDropReceiver.types)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

        private func location(_ sender: NSDraggingInfo) -> CGPoint {
            window?.convertPoint(toScreen: sender.draggingLocation) ?? NSEvent.mouseLocation
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard sender.draggingPasteboard.availableType(from: ManagedDropReceiver.types) != nil,
                  let owner else { return [] }
            owner.entered = true
            owner.onEnter?(location(sender))
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            owner?.onMove?(location(sender))
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { owner?.onExit?() }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { owner != nil }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let owner else { return false }
            owner.delivered = true
            return owner.onDrop?(sender.draggingPasteboard, location(sender)) ?? false
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            DropGestureMonitor.shared.finish()
        }
    }
}

/// One pair of event monitors for all displays, released with the last receiver.
/// Pasteboard types are read only after a changed drag pasteboard is observed;
/// once armed, subsequent movement does no work here (AppKit handles the drag).
@MainActor
private final class DropGestureMonitor {
    static let shared = DropGestureMonitor()
    private final class WeakReceiver {
        weak var value: ManagedDropReceiver?
        init(_ value: ManagedDropReceiver) { self.value = value }
    }
    private var receivers: [ObjectIdentifier: WeakReceiver] = [:]
    private var monitors: [Any] = []
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let pasteboard = NSPasteboard(name: .drag)
    private var gate = DragSessionGate(changeCount: NSPasteboard(name: .drag).changeCount)
    private var releaseCleanup: DispatchWorkItem?
    private var generation = 0
    var state: (receivers: Int, monitors: Int, lifecycleObservers: Int) {
        (receivers.values.filter { $0.value != nil }.count, monitors.count, lifecycleObservers.count)
    }

    func add(_ receiver: ManagedDropReceiver) {
        receivers[ObjectIdentifier(receiver)] = WeakReceiver(receiver)
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(local) }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            })
        }
    }

    func remove(_ receiver: ManagedDropReceiver) {
        receivers[ObjectIdentifier(receiver)] = nil
        receivers = receivers.filter { $0.value.value != nil }
        guard receivers.isEmpty else { return }
        finish()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        lifecycleObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        lifecycleObservers.removeAll()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            generation += 1
            releaseCleanup?.cancel()
            releaseCleanup = nil
            if gate.isActive { Array(receivers.values).forEach { $0.value?.end() } }
            gate.mouseDown()
        case .leftMouseDragged:
            guard !gate.isActive else { return }
            let count = pasteboard.changeCount
            if gate.activate(changeCount: count, support: pasteboardSupport()) {
                IslandDiagnostics.shared?.log("native drop: armed managed receiver")
                generation += 1
                receivers.values.forEach { $0.value?.begin() }
            }
        case .leftMouseUp:
            guard gate.isActive else { gate.end(changeCount: pasteboard.changeCount); return }
            // A drop inside our receiver finishes via native draggingEnded. If
            // released elsewhere, no AppKit completion is owed to this window.
            if !receivers.values.contains(where: { $0.value?.containsMouse == true }) {
                finish()
            } else {
                // Bounded safety cleanup for a cancelled/undelivered native drag;
                // not a repeating task or a delay before accepting the drop.
                let token = generation
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.finish()
                }
                releaseCleanup?.cancel()
                releaseCleanup = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            }
        default: break
        }
    }

    private func pasteboardSupport() -> Bool? {
        guard let types = pasteboard.types, !types.isEmpty else { return nil }
        return types.contains { ManagedDropReceiver.types.contains($0) }
    }

    func finish() {
        generation += 1
        releaseCleanup?.cancel()
        releaseCleanup = nil
        guard gate.isActive else { return }
        gate.end(changeCount: pasteboard.changeCount)
        Array(receivers.values).forEach { $0.value?.end() }
    }
}
