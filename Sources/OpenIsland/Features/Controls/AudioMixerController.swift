import AppKit
import CoreAudio
import AudioToolbox

struct MixerApplication: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let bundleID: String
    let icon: NSImage?
    let processes: [AudioObjectID]
    let isPlaying: Bool
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.processes == rhs.processes && lhs.isPlaying == rhs.isPlaying
    }
}

@MainActor
@Observable
final class AudioMixerController {
    private(set) var devices: [MixerDevice] = []
    private(set) var applications: [MixerApplication] = []
    private(set) var output: AudioObjectID = 0
    private(set) var systemOutput: AudioObjectID = 0
    private(set) var input: AudioObjectID = 0
    private(set) var outputLevel: Float?
    private(set) var inputLevel: Float?
    private(set) var error: String?
    private(set) var volumes: [pid_t: Float] = [:]
    private(set) var routes: [pid_t: String] = [:]
    private(set) var activeRouteCount = 0
    @ObservationIgnored private var panels = 0
    @ObservationIgnored private var listenerFingerprint = ""
    @ObservationIgnored private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var engines: [pid_t: AnyObject] = [:]
    @ObservationIgnored private var signatures: [pid_t: String] = [:]
    @ObservationIgnored private var directPending: [pid_t: Float] = [:]
    @ObservationIgnored private var directWorkers: [pid_t: Task<Void, Never>] = [:]
    @ObservationIgnored private var isSleeping = false

    var supportsApplicationMixer: Bool { if #available(macOS 14.2, *) { true } else { false } }
    var listenerCount: Int { listeners.count }

    func diagnosticState(pid: pid_t) -> String {
        guard #available(macOS 14.2, *), let route = engines[pid] as? ApplicationAudioRoute else { return "no route" }
        return route.diagnosticState
    }

    func interruptRouteForDiagnostics(pid: pid_t) {
        if #available(macOS 14.2, *) { (engines[pid] as? ApplicationAudioRoute)?.interruptForDiagnostics() }
    }

    func showPanel() {
        panels += 1
        refresh()
        attachListeners()
    }
    func hidePanel() {
        panels = max(0, panels - 1)
        attachListeners()
    }
    func shutdown() {
        panels = 0
        refreshTask?.cancel()
        refreshTask = nil
        detachListeners()
        if #available(macOS 14.2, *) { for engine in engines.values { (engine as? ApplicationAudioRoute)?.stop() } }
        engines.removeAll()
        publishRouteCount()
        signatures.removeAll()
        isSleeping = false
        directWorkers.values.forEach { $0.cancel() }
        directWorkers.removeAll()
        directPending.removeAll()
    }
    func clearError() { error = nil }

    func selectDevice(_ id: AudioObjectID, selector: AudioObjectPropertySelector) {
        guard AudioHardwareAccess.write(AudioHardwareAccess.system, selector, id) else {
            error = "Ses aygıtı değiştirilemedi. Aygıt bağlantısını kontrol et."
            return
        }
        refresh()
        attachListeners()
    }
    func setDeviceLevel(_ value: Float, input: Bool) {
        let device = input ? self.input : output
        guard AudioHardwareAccess.setLevel(device, input: input, level: value) else {
            error = "Bu aygıt yazılımsal ses seviyesini desteklemiyor."
            return
        }
        if input { inputLevel = value } else { outputLevel = value }
    }
    func setApplicationVolume(_ value: Float, pid: pid_t) {
        // Re-resolve helper processes on interaction as well as HAL notifications.
        // A queued process-list event must not leave the slider controlling an old tap.
        if engines[pid] == nil,
           applications.contains(where: { $0.id == pid && DirectApplicationVolume.kind(for: $0.bundleID) == nil }) {
            refresh()
        }
        guard let app = applications.first(where: { $0.id == pid }) else { return }
        let direct = DirectApplicationVolume.kind(for: app.bundleID)
        guard direct != nil || supportsApplicationMixer else { return }
        let level = min(max(value, 0), 1)
        volumes[pid] = level
        if let direct {
            applyDirectVolume(level, to: app, using: direct)
            attachListeners()
            return
        }
        guard supportsApplicationMixer else { return }
        reconcileRoutes()
        attachListeners()
    }
    func setApplicationOutput(_ uid: String, pid: pid_t) {
        routes[pid] = uid.isEmpty ? nil : uid
        reconcileRoutes()
        attachListeners()
    }
    func restoreApplication(_ pid: pid_t) {
        if applications.contains(where: { $0.id == pid && DirectApplicationVolume.kind(for: $0.bundleID) != nil }) {
            routes[pid] = nil
            reconcileRoutes()
            setApplicationVolume(1, pid: pid)
            return
        }
        volumes[pid] = nil
        routes[pid] = nil
        reconcileRoutes()
        attachListeners()
    }

    func refresh() {
        let hardware = AudioHardwareAccess.self
        let nextDevices = MixerDevice.read()
        if devices != nextDevices { devices = nextDevices }
        let nextOutput = hardware.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let nextSystemOutput = hardware.defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let nextInput = hardware.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        if output != nextOutput { output = nextOutput }
        if systemOutput != nextSystemOutput { systemOutput = nextSystemOutput }
        if input != nextInput { input = nextInput }
        let nextOutputLevel = hardware.level(output, input: false)
        let nextInputLevel = hardware.level(input, input: true)
        if outputLevel != nextOutputLevel { outputLevel = nextOutputLevel }
        if inputLevel != nextInputLevel { inputLevel = nextInputLevel }
        var processMap: [pid_t: [AudioObjectID]] = [:]
        var playing = Set<pid_t>()
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let owners = running.map { (app: $0, pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, path: $0.bundleURL?.path) }
        if #available(macOS 14.2, *) {
            for object in hardware.objects(hardware.system, kAudioHardwarePropertyProcessObjectList) {
                guard let pid = hardware.scalar(object, kAudioProcessPropertyPID, initial: pid_t(0)), pid != 0 else { continue }
                let process = NSRunningApplication(processIdentifier: pid)
                let bundleID = hardware.string(object, kAudioProcessPropertyBundleID) ?? process?.bundleIdentifier ?? ""
                let processPath = process?.bundleURL?.path
                let owner = owners.first { candidate in
                    candidate.pid == pid
                    || (candidate.bundleID.map { bundleID == $0 || bundleID.hasPrefix($0 + ".") } ?? false)
                    || (candidate.path.map { processPath?.hasPrefix($0 + "/") == true } ?? false)
                }?.app
                guard let owner else { continue }
                processMap[owner.processIdentifier, default: []].append(object)
                if hardware.scalar(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) == 1 {
                    playing.insert(owner.processIdentifier)
                }
            }
        }
        // Core Audio status changes do not change application icons. Reuse the
        // already loaded icon instead of asking LaunchServices to read it again.
        let previous = Dictionary(uniqueKeysWithValues: applications.map { ($0.id, $0) })
        let next = running.map { app in
            let cached = previous[app.processIdentifier]
            let icon = cached?.bundleID == app.bundleIdentifier ? cached?.icon : nil
            return MixerApplication(id: app.processIdentifier, name: app.localizedName ?? "Uygulama", bundleID: app.bundleIdentifier ?? "",
                             icon: icon ?? app.icon,
                             processes: (processMap[app.processIdentifier] ?? []).sorted(), isPlaying: playing.contains(app.processIdentifier))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if applications != next { applications = next }
        let existing = Set(next.map(\.id))
        volumes = volumes.filter { existing.contains($0.key) }
        routes = routes.filter { existing.contains($0.key) }
        reconcileRoutes()
    }

    private func reconcileRoutes() {
        guard #available(macOS 14.2, *) else { return }
        defer { publishRouteCount() }
        guard !isSleeping else { return }
        var retained = Set<pid_t>()
        for app in applications {
            let direct = DirectApplicationVolume.kind(for: app.bundleID)
            // Direct controls own the gain. A user-selected output still needs
            // the Core Audio route, but it must not attenuate the signal twice.
            let volume: Float = direct == nil ? (volumes[app.id] ?? 1) : 1
            let override = routes[app.id] ?? ""
            guard volume != 1 || !override.isEmpty else { continue }
            // Sessiz/çalmayan uygulama için realtime ses döngüsü çalıştırma.
            guard app.isPlaying, !app.processes.isEmpty else {
                continue
            }
            let uid = override.isEmpty ? AudioHardwareAccess.string(output, kAudioDevicePropertyDeviceUID) : override
            guard let uid, let device = devices.first(where: { $0.output && $0.uid == uid }) else { continue }
            retained.insert(app.id)
            let signature = "\(device.id):" + uid + (volume == 0 ? ":mute:" : ":gain:") + app.processes.map(String.init).joined(separator: ",")
            if let engine = engines[app.id] as? ApplicationAudioRoute, signatures[app.id] == signature, engine.isOperational {
                engine.setVolume(volume)
                continue
            }
            (engines.removeValue(forKey: app.id) as? ApplicationAudioRoute)?.stop()
            signatures[app.id] = nil
            let engine = ApplicationAudioRoute()
            engine.onFailure = { [weak self, weak engine] error in
                guard let self, let engine, self.engines[app.id] === engine else { return }
                self.engines[app.id] = nil
                self.publishRouteCount()
                self.signatures[app.id] = nil
                if direct == nil { self.volumes[app.id] = nil }
                self.routes[app.id] = nil
                self.error = "\(app.name): \(error). Ses kaydedilmez; mikser yalnızca bellekte çalışır."
                self.attachListeners()
            }
            do {
                try engine.start(processes: app.processes, outputUID: uid, volume: volume)
                engines[app.id] = engine
                signatures[app.id] = signature
                if error?.hasPrefix(app.name + ":") == true { error = nil }
            } catch {
                engine.stop()
                if direct == nil { volumes[app.id] = nil }
                routes[app.id] = nil
                self.error = "\(app.name): \(error). Sistem Ayarları’nda OpenIsland’in sistem sesi erişimini kontrol et."
            }
        }
        for pid in Array(engines.keys) where !retained.contains(pid) {
            (engines.removeValue(forKey: pid) as? ApplicationAudioRoute)?.stop()
            signatures[pid] = nil
        }
    }

    private func scheduleRefresh() {
        // A Core Audio callback already queued before listener removal can arrive
        // after the panel closes. Do not revive monitoring for an inactive mixer.
        guard !isSleeping, panels > 0 || hasHardwareAdjustments else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            self.refresh()
            self.attachListeners()
        }
    }

    private func attachListeners() {
        let directIDs = Set(applications.filter { DirectApplicationVolume.kind(for: $0.bundleID) != nil }.map(\.id))
        let adjusted = Set(volumes.filter { $0.value != 1 && !directIDs.contains($0.key) }.keys).union(routes.keys)
        guard panels > 0 || !adjusted.isEmpty else {
            detachListeners()
            isSleeping = false
            refreshTask?.cancel()
            refreshTask = nil
            return
        }
        var properties: [(AudioObjectID, AudioObjectPropertyAddress)] = []
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            properties.append((AudioHardwareAccess.system, AudioHardwareAccess.address(selector)))
        }
        if #available(macOS 14.2, *) {
            properties.append((AudioHardwareAccess.system, AudioHardwareAccess.address(kAudioHardwarePropertyProcessObjectList)))
            for app in applications where panels > 0 || adjusted.contains(app.id) {
                for process in app.processes {
                    properties.append((process, AudioHardwareAccess.address(kAudioProcessPropertyIsRunningOutput)))
                }
            }
            for engine in engines.values {
                guard let route = engine as? ApplicationAudioRoute, route.monitoredDevice != 0 else { continue }
                for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceIsRunning] {
                    properties.append((route.monitoredDevice, AudioHardwareAccess.address(selector)))
                }
            }
        }
        if panels > 0 {
            for (id, input) in [(output, false), (self.input, true)] where id != 0 {
                let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
                for selector in [kAudioDevicePropertyVolumeScalar, kAudioHardwareServiceDeviceProperty_VirtualMainVolume] {
                    for element: UInt32 in [0, 1] {
                        properties.append((id, AudioHardwareAccess.address(selector, scope: scope, element: element)))
                    }
                }
            }
        }
        let fingerprint = properties.map { "\($0.0):\($0.1.mSelector):\($0.1.mScope):\($0.1.mElement)" }.sorted().joined(separator: ",")
        guard fingerprint != listenerFingerprint else { return }
        detachListeners()
        listenerFingerprint = fingerprint
        for (object, address) in properties {
            var address = address
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            if AudioObjectHasProperty(object, &address), AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
                listeners.append((object, address, block))
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSleeping = true
                self.refreshTask?.cancel()
                self.refreshTask = nil
                self.stopHardwareRoutes()
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSleeping = false
                self.stopHardwareRoutes()
                self.scheduleRefresh()
            }
        })
    }

    private func stopHardwareRoutes() {
        if #available(macOS 14.2, *) { for engine in engines.values { (engine as? ApplicationAudioRoute)?.stop() } }
        engines.removeAll()
        signatures.removeAll()
        publishRouteCount()
    }

    private var hasHardwareAdjustments: Bool {
        !routes.isEmpty || volumes.contains { pid, level in
            level != 1 && !applications.contains { $0.id == pid && DirectApplicationVolume.kind(for: $0.bundleID) != nil }
        }
    }

    /// Engine ownership is intentionally not observed by SwiftUI. Publish only
    /// lifecycle changes, so the header never retains a route that was stopped.
    private func publishRouteCount() {
        if activeRouteCount != engines.count { activeRouteCount = engines.count }
    }

    private func applyDirectVolume(_ level: Float, to app: MixerApplication, using direct: DirectApplicationVolume) {
        directPending[app.id] = level
        guard directWorkers[app.id] == nil else { return }
        directWorkers[app.id] = Task { [weak self] in
            // Dragging a slider coalesces to the latest value while the browser
            // handles an Apple Event. At most one script runs per application.
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self else { return }
            while let requested = self.directPending.removeValue(forKey: app.id), !Task.isCancelled {
                guard let running = NSRunningApplication(processIdentifier: app.id), !running.isTerminated,
                      running.bundleIdentifier == app.bundleID else { break }
                let result = await direct.apply(requested)
                guard !Task.isCancelled else { break }
                if self.directPending[app.id] != nil { continue }
                if result != .applied {
                    self.volumes[app.id] = nil
                    switch result {
                    case .noPlayer:
                        self.error = "\(app.name): açık sekmede kontrol edilebilen video veya müzik yok."
                    case .browserSettingDisabled:
                        if case .chromium = direct {
                            self.error = "\(app.name): Görünüm › Geliştirici › Apple Events'ten JavaScript'e izin ver ayarını aç."
                        } else {
                            self.error = "\(app.name): Geliştir menüsündeki Apple Events'ten JavaScript'e izin ver ayarını aç."
                        }
                    case .automationDenied:
                        self.error = "\(app.name): Sistem Ayarları › Gizlilik ve Güvenlik › Otomasyon'da OpenIsland'e izin ver."
                    case .failed:
                        self.error = "\(app.name): oynatıcı sesi değiştirilemedi."
                    case .applied: break
                    }
                }
            }
            self.directWorkers[app.id] = nil
            self.attachListeners()
        }
    }

    private func detachListeners() {
        listenerFingerprint = ""
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }
}
