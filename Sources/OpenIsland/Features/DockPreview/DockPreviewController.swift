import AppKit
import ApplicationServices
import IslandCore
import ScreenCaptureKit
import SwiftUI

/// Dock hover is event driven. Away from screen edges the callback does only a geometry
/// check. Window enumeration and single-frame captures run only after a deliberate hover.
@MainActor
final class DockPreviewController {
    private struct Target {
        let app: NSRunningApplication
        let anchor: CGRect // AppKit bottom-left coordinates
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var dock: AXUIElement?
    private var target: Target?
    private var showTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var pendingProbePoint: CGPoint?
    private var captureTasks: [UUID: Task<Void, Never>] = [:]
    private var captureWindows: [UUID: SCWindow] = [:]
    private var captureQueue: [UUID] = []
    private var requestedImages: Set<UUID> = []
    private var resolvingCaptureWindows = false
    private var generation: UInt64 = 0
    private var lastProbeTime: TimeInterval = 0
    private var panel: NSPanel?
    private let model = DockPreviewModel()
    private var enabled = false
    private var screenAccess = false
    private var screenFrames: [CGRect] = []
    private var previewEdge: DockPreviewRules.Edge?
    private let accessibilityTrusted: () -> Bool
    private let screenCaptureAllowed: () -> Bool
    private let captureCatalog: @MainActor (pid_t) async throws -> [SCWindow]
    var onRequestScreenAccess: (() -> Void)?

    // Lifecycle diagnostics used by the native regression check, never periodically sampled.
    var isMonitoring: Bool { globalMonitor != nil }
    var monitorCount: Int { (globalMonitor == nil ? 0 : 1) + (localMonitor == nil ? 0 : 1) }
    var observerCount: Int { workspaceObservers.count + (screenObserver == nil ? 0 : 1) }
    var isVisible: Bool { panel?.isVisible == true }
    var imageCount: Int { model.images.count }
    var pendingCaptureCount: Int { captureTasks.count + captureQueue.count }
    var previewedWindows: [DockPreviewWindow] { model.windows }
    private(set) var probeCount = 0
    private(set) var windowReadCount = 0
    private(set) var applicationReadCount = 0
    private(set) var captureCount = 0
    private(set) var dismissalCount = 0

    init(accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         screenCaptureAllowed: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         captureCatalog: @escaping @MainActor (pid_t) async throws -> [SCWindow] = DockPreviewController.loadCaptureCatalog) {
        self.accessibilityTrusted = accessibilityTrusted
        self.screenCaptureAllowed = screenCaptureAllowed
        self.captureCatalog = captureCatalog
    }

    private var dismissMonitor: Any?

    func configure(enabled: Bool) {
        self.enabled = enabled
        screenFrames = NSScreen.screens.map(\.frame)
        let allowed = enabled && screenCaptureAllowed()
        if allowed != screenAccess { dismiss() }
        screenAccess = allowed
        guard enabled && accessibilityTrusted() else { stop(); return }
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .mouseMoved
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.enabled else { return }
                let point = event.locationInWindow
                if !self.isVisible && self.target == nil && self.showTask == nil && self.probeTask == nil {
                    guard DockPreviewRules.nearDockEdge(point, screens: self.screenFrames) else { return }
                }
                self.pointerMoved(to: point)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                if event.type == .keyDown {
                    if event.keyCode == 53, self?.isVisible == true { self?.dismiss(); return true }
                    if self?.target != nil { self?.dismiss() }
                } else if event.type == .mouseMoved {
                    let point = NSEvent.mouseLocation
                    if self?.isVisible != true && self?.target == nil && self?.showTask == nil && self?.probeTask == nil {
                        guard let screens = self?.screenFrames, DockPreviewRules.nearDockEdge(point, screens: screens) else { return false }
                    }
                    self?.pointerMoved(to: point)
                } else if self?.target != nil || self?.isVisible == true {
                    self?.handleDismissEvent(event)
                }
                return false
            }
            return consumed ? nil : event
        }
        observeLifecycle()
    }

    func stop() {
        enabled = false
        dismiss()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
        globalMonitor = nil
        localMonitor = nil
        dismissMonitor = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        dock = nil
        screenFrames.removeAll()
        lastProbeTime = 0
    }

    func dismiss() {
        // Global clicks, drags and Space notifications also arrive with no preview.
        // An already empty service needs neither cancellation nor observable writes.
        if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
        dismissMonitor = nil
        guard target != nil || showTask != nil || dismissTask != nil || probeTask != nil
            || panel?.contentView != nil || !captureTasks.isEmpty || !captureQueue.isEmpty else { return }
        dismissalCount += 1
        generation &+= 1
        showTask?.cancel(); showTask = nil
        dismissTask?.cancel(); dismissTask = nil
        cancelProbe()
        captureTasks.values.forEach { $0.cancel() }
        captureTasks.removeAll()
        captureQueue.removeAll()
        captureWindows.removeAll()
        requestedImages.removeAll()
        resolvingCaptureWindows = false
        target = nil
        previewEdge = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        model.clear()
    }

    private func observeLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if app.bundleIdentifier == "com.apple.dock" { self.dock = nil; self.dismiss() }
                    else if app.isTerminated && self.target?.app.processIdentifier == app.processIdentifier { self.dismiss() }
                }
            })
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dismiss()
                    self?.screenFrames = NSScreen.screens.map(\.frame)
                }
            }
    }

    private func attachDismissMonitor() {
        guard dismissMonitor == nil else { return }
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .rightMouseDragged, .keyDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handleDismissEvent(event) }
        }
    }

    private func handleDismissEvent(_ event: NSEvent) {
        guard enabled else { return }
        if event.type == .keyDown {
            if target != nil { dismiss() }
            return
        }
        let point = event.window == nil ? event.locationInWindow : NSEvent.mouseLocation
        if event.type == .scrollWheel {
            if isVisible && panel?.frame.contains(point) != true { dismiss() }
            return
        }
        if event.type == .leftMouseDragged || event.type == .rightMouseDragged { dismiss(); return }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if !isVisible || panel?.frame.contains(point) != true { dismiss() }
            return
        }
    }

    private func handle(_ event: NSEvent) {
        guard enabled else { return }
        if event.type == .mouseMoved {
            pointerMoved(to: NSEvent.mouseLocation)
        } else {
            handleDismissEvent(event)
        }
    }

    /// Separate entry point lets native checks exercise the edge gate without moving the user's cursor.
    func pointerMoved(to point: CGPoint) {
        guard enabled else { return }
        if isVisible, let panel, panel.frame.contains(point) { cancelProbe(); cancelDismiss(); return }
        if isVisible, let target, let panel, let previewEdge,
           DockPreviewRules.bridge(anchor: target.anchor, panel: panel.frame, edge: previewEdge).contains(point) {
            cancelProbe(); cancelDismiss(); return
        }
        guard DockPreviewRules.nearDockEdge(point, screens: screenFrames) else {
            if isVisible {
                cancelProbe()
                showTask?.cancel()
                showTask = nil
                scheduleDismiss()
            } else if target != nil || showTask != nil || probeTask != nil {
                cancelProbe()
                showTask?.cancel()
                showTask = nil
                target = nil
            }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if target?.anchor.insetBy(dx: -2, dy: -2).contains(point) == true { cancelDismiss() }
        let elapsed = now - lastProbeTime
        guard elapsed >= DockPreviewRules.probeInterval else {
            // Deliver the last event in a fast burst, even when the pointer then stops.
            // This is one trailing callback, not a recurring mouse-position timer.
            pendingProbePoint = point
            if probeTask == nil {
                probeTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(DockPreviewRules.probeInterval - elapsed + 0.001)) } catch { return }
                    guard let self, !Task.isCancelled, let point = self.pendingProbePoint else { return }
                    self.probeTask = nil
                    self.pendingProbePoint = nil
                    self.pointerMoved(to: point)
                }
            }
            return
        }
        cancelProbe()
        lastProbeTime = now
        guard let next = dockTarget(at: point) else {
            showTask?.cancel(); showTask = nil
            if isVisible { scheduleDismiss() } else { target = nil }
            return
        }
        cancelDismiss()
        if target?.app.processIdentifier == next.app.processIdentifier {
            target = next
            return
        }
        dismiss()
        target = next
        attachDismissMonitor()
        let token = generation
        showTask = Task { [weak self] in
            if DockPreviewRules.hoverDelay > 0 {
                do { try await Task.sleep(for: .seconds(DockPreviewRules.hoverDelay)) } catch { return }
            }
            guard let self else { return }
            defer { if self.generation == token { self.showTask = nil } }
            guard !Task.isCancelled, self.enabled, self.generation == token,
                  let live = self.dockTarget(at: NSEvent.mouseLocation),
                  live.app.processIdentifier == next.app.processIdentifier else { return }
            self.target = live
            self.attachDismissMonitor()
            await self.present(live, token: token)
        }
    }

    private func cancelProbe() {
        probeTask?.cancel(); probeTask = nil
        pendingProbePoint = nil
    }

    private func cancelDismiss() { dismissTask?.cancel(); dismissTask = nil }

    private func scheduleDismiss() {
        guard dismissTask == nil else { return }
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(DockPreviewRules.exitGrace)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dockTarget(at point: CGPoint) -> Target? {
        probeCount += 1
        if dock == nil, let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            dock = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(dock!, 0.08)
        }
        guard let dock else { return nil }
        let cgPoint = coreGraphicsPoint(point)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dock, Float(cgPoint.x), Float(cgPoint.y), &hit) == .success,
              let hit else { return nil }
        let names = [kAXSubroleAttribute, kAXURLAttribute, kAXPositionAttribute, kAXSizeAttribute]
        var rawValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(hit, names as CFArray, [], &rawValues) == .success,
              let values = rawValues as? [AnyObject], values.count == names.count,
              values[0] as? String == "AXApplicationDockItem", let url = values[1] as? URL,
              CFGetTypeID(values[2]) == AXValueGetTypeID(), CFGetTypeID(values[3]) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(values[2], to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(values[3], to: AXValue.self), .cgSize, &dimensions) else { return nil }
        let rect = CGRect(origin: origin, size: dimensions)
        // Normalize the hit URL once, rather than once per running application.
        let standardizedTargetURL = url.standardizedFileURL
        let app: NSRunningApplication?
        if let current = target?.app, !current.isTerminated,
           current.bundleURL?.standardizedFileURL == standardizedTargetURL {
            // Pointer motion over the same Dock item needs fresh hit geometry, but
            // not another LaunchServices enumeration of every running application.
            app = current
        } else {
            applicationReadCount += 1
            let apps = NSWorkspace.shared.runningApplications
            app = apps.first { $0.bundleURL?.standardizedFileURL == standardizedTargetURL }
                ?? Bundle(url: url)?.bundleIdentifier.flatMap { id in apps.first { $0.bundleIdentifier == id } }
        }
        guard let app, !app.isTerminated, app.activationPolicy == .regular,
              rect.width > 0, rect.height > 0 else { return nil }
        let anchor = CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
        guard anchor.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        return Target(app: app, anchor: anchor)
    }

    private func present(_ target: Target, token: UInt64) async {
        let windows = readWindows(target.app)
        guard !windows.isEmpty, !Task.isCancelled, enabled, generation == token, !target.app.isTerminated,
              let screen = screen(containing: target.anchor) else { return }
        // Window cards are actionable immediately. A slow ScreenCaptureKit catalogue
        // must not delay the panel; visible-card requests wait for this one lookup.
        resolvingCaptureWindows = screenAccess
        model.applicationName = target.app.localizedName ?? "Uygulama"
        model.applicationIcon = target.app.icon
        model.windows = windows
        model.needsScreenAccess = !screenAccess
        model.requestImage = { [weak self] id in self?.requestImage(id) }
        model.selectWindow = { [weak self] id in self?.selectWindow(id) }
        model.requestPermission = { [weak self] in
            self?.dismiss()
            self?.onRequestScreenAccess?()
        }
        let frame = DockPreviewRules.panelFrame(anchor: target.anchor, screen: screen.frame, visibleFrame: screen.visibleFrame,
            windowCount: windows.count, permissionFooter: model.needsScreenAccess)
        previewEdge = DockPreviewRules.edge(anchor: target.anchor, screen: screen.frame)
        if panel == nil {
            let panel = DockPreviewWindowPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                               backing: .buffered, defer: false)
            // Above normal application windows, below menus, modal alerts and system UI.
            panel.level = .floating
            panel.title = "OpenIsland — Dock önizlemeleri"
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.acceptsMouseMovedEvents = true
            self.panel = panel
        }
        #if OPENISLAND_DENEY
        // AppKit deneyi: aynı model ve yerleşimle AppKit paneli (Deney/Sources/Panels/DockPreviewPanelView.swift).
        panel?.contentView = DockPreviewPanelView(model: model, size: frame.size)
        #else
        let hosting = NSHostingView(rootView: DockPreviewPanel(model: model).frame(width: frame.width, height: frame.height))
        // A wrapping permission message must not replace our screen-clamped panel geometry
        // with SwiftUI's unconstrained intrinsic height.
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        panel?.contentView = hosting
        #endif
        panel?.setFrame(frame, display: false)
        panel?.orderFrontRegardless()

        guard screenAccess else { return }
        let availableWindows = (try? await captureCatalog(target.app.processIdentifier)) ?? []
        guard !Task.isCancelled, enabled, generation == token, !target.app.isTerminated else { return }
        var available = availableWindows
        for window in windows {
            if let index = DockPreviewRules.captureIndex(for: .init(title: window.title, frame: window.frame),
                candidates: available.map { .init(title: $0.title ?? "", frame: $0.frame) }) {
                captureWindows[window.id] = available.remove(at: index)
            }
        }
        resolvingCaptureWindows = false
        for id in requestedImages { enqueueImage(id) }
    }

    private static func loadCaptureCatalog(for pid: pid_t) async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
            .sorted { $0.isOnScreen && !$1.isOnScreen }
    }

    private func requestImage(_ id: UUID) {
        guard !requestedImages.contains(id), enabled else { return }
        requestedImages.insert(id)
        guard !resolvingCaptureWindows else { return }
        enqueueImage(id)
    }

    private func enqueueImage(_ id: UUID) {
        guard captureWindows[id] != nil else { model.unavailable.insert(id); return }
        captureQueue.append(id)
        startCaptures()
    }

    private func startCaptures() {
        while captureTasks.count < DockPreviewRules.concurrentCaptures, !captureQueue.isEmpty {
            let id = captureQueue.removeFirst()
            guard let window = captureWindows[id] else { continue }
            let token = generation
            captureCount += 1
            captureTasks[id] = Task { [weak self] in
                let image = try? await Self.capture(window)
                guard !Task.isCancelled, let self, self.generation == token, self.enabled else { return }
                self.captureTasks[id] = nil
                if let image { self.model.images[id] = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)) }
                else { self.model.unavailable.insert(id) }
                self.startCaptures()
            }
        }
    }

    private static func capture(_ window: SCWindow) async throws -> CGImage {
        let limit = DockPreviewRules.thumbnailPixels
        let scale = min(limit.width / max(window.frame.width, 1), limit.height / max(window.frame.height, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                        configuration: configuration)
    }

    func selectWindow(_ id: UUID) {
        guard let target, let window = model.windows.first(where: { $0.id == id }), !target.app.isTerminated else { dismiss(); return }
        AXUIElementSetMessagingTimeout(window.element, 0.15)
        if window.minimized { _ = AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        target.app.unhide()
        target.app.activate()
        _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        let app = AXUIElementCreateApplication(target.app.processIdentifier)
        _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window.element)
        dismiss()
    }

    private func readWindows(_ app: NSRunningApplication) -> [DockPreviewWindow] {
        windowReadCount += 1
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.12)
        guard let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            guard attribute(window, kAXRoleAttribute) as? String == kAXWindowRole,
                  let rect = frame(of: window), rect.width.isFinite, rect.height.isFinite,
                  rect.minX.isFinite, rect.minY.isFinite, rect.width >= 100, rect.height >= 60 else { return nil }
            let title = attribute(window, kAXTitleAttribute) as? String ?? ""
            return DockPreviewWindow(title: title.isEmpty ? (app.localizedName ?? "Pencere") : title, frame: rect,
                minimized: attribute(window, kAXMinimizedAttribute) as? Bool == true, element: window)
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = attribute(element, kAXPositionAttribute), CFGetTypeID(origin) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(origin, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private var primaryTop: CGFloat { screenFrames.first?.maxY ?? 0 }
    private func coreGraphicsPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: primaryTop - point.y) }
    private func appKitPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: primaryTop - point.y) }
    private func screen(containing anchor: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }
    }
}

private final class DockPreviewWindowPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
