import AppKit
import Foundation
import IslandCore

/// Sistem sekmesinin verisi. **Yalnızca sekme görünürken ölçer**: `start`/`stop` panelin `onAppear`/`onDisappear`'ında
/// çağrılır; sekme kapalıyken (ada kapalı, başka sekme) zamanlayıcı, görev ve sensör işi yoktur. Ölçümler mikro-
/// milisaniyelik çekirdek çağrılarıdır; ölçüm aralığı 2 sn (Düşük Güç Modu'nda 4 sn).
@MainActor
@Observable
final class SystemMonitor {
    private(set) var cpu: Double?
    private(set) var gpu: Double?
    private(set) var memory: MemoryBreakdown?
    private(set) var pressure = MemoryRules.Pressure.normal
    private(set) var temperatures: TemperatureRules.Summary?
    private(set) var storage: [StorageVolume] = []
    @ObservationIgnored private(set) var storageReadCount = 0
    private(set) var uptime: TimeInterval = 0
    /// 0...1; `nil`: bu Mac'te okunamıyor (sembol yok, güncelleme sonrası uyumsuz ya da kapalı).
    private(set) var brightness: Float?
    private(set) var keyboardBacklight: Float?

    /// Ayarlar › "Sıcaklık, parlaklık ve klavye ışığı". Kapalıyken hiçbir private çağrı yapılmaz.
    @ObservationIgnored var privateEnabled = true {
        didSet { if !privateEnabled { releasePrivate() } }
    }
    /// Düşük Güç Modu / ısınma: ölçüm aralığı uzar.
    @ObservationIgnored var slowPolling = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var storageTask: Task<Void, Never>?
    @ObservationIgnored private var storageObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var previousTicks: CPUTicks?
    @ObservationIgnored private var thermal: ThermalSensors?
    @ObservationIgnored private var displayControl: ManagedLevelControl?
    @ObservationIgnored private var keyboardControl: ManagedLevelControl?
    @ObservationIgnored private var didTryPrivate = false
    /// Kaydırıcı sürüklenirken değeri kullanıcı belirler; ölçüm onu ezmez.
    @ObservationIgnored private var adjusting = false

    var isRunning: Bool { task != nil }
    var storageObserverCount: Int { storageObservers.count }
    var canAdjustBrightness: Bool { displayControl?.canHandle ?? false }
    var canAdjustKeyboard: Bool { keyboardControl?.canHandle ?? false }

    func start() {
        guard task == nil else { return }
        previousTicks = nil
        task = Task { [weak self] in
            // İlk okuma CPU için temel olur; ikinci okuma kısa sürede gelir ki panel boş kalmasın.
            guard !Task.isCancelled else { return }
            self?.sample()
            try? await Task.sleep(for: .milliseconds(500))
            while !Task.isCancelled {
                guard let self else { return }
                self.sample()
                try? await Task.sleep(for: .seconds(self.slowPolling ? 4 : 2))
            }
        }
        observeVolumes()
        refreshStorage()
    }

    func stop() {
        task?.cancel()
        task = nil
        adjusting = false
        storageTask?.cancel()
        storageTask = nil
        storageObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        storageObservers.removeAll()
        thermal = nil // sensör istemcisi yalnızca sekme açıkken tutulur
    }

    /// Uyanma / ekran değişimi: devre dışı kalmış kontrole tek bir yeni hak.
    func recover() {
        displayControl?.reset()
        keyboardControl?.reset()
    }

    func setBrightness(_ value: Float) {
        guard let control = displayControl, let level = control.set(value) else { return }
        brightness = level
    }

    func setKeyboardBacklight(_ value: Float) {
        guard let control = keyboardControl, let level = control.set(value) else { return }
        keyboardBacklight = level
    }

    func setAdjusting(_ value: Bool) { adjusting = value }

    /// CPU/GPU örnekleme döngüsüne bağlı değildir. Yalnızca görünür UI için tek metadata okuması.
    func refreshStorage() {
        guard isRunning else { return }
        storageTask?.cancel()
        storageTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard !Task.isCancelled else { return }
            let volumes = await Task.detached(priority: .utility) { StorageVolume.read() }.value
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.storageReadCount += 1
            if self.storage != volumes { self.storage = volumes }
            self.storageTask = nil
        }
    }

    private func observeVolumes() {
        guard storageObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            storageObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStorage() }
            })
        }
    }

    // MARK: - Ölçüm

    private func sample() {
        // The visible uptime label has minute precision. CPU/GPU still sample at
        // their normal cadence; do not invalidate the temperature column every 2 s
        // merely to republish seconds which it never displays.
        let nextUptime = ProcessInfo.processInfo.systemUptime
        if Int(nextUptime / 60) != Int(uptime / 60) { uptime = nextUptime }
        if let ticks = SystemSensors.cpuTicks() {
            if let previousTicks, let usage = CPUTicks.usage(from: previousTicks, to: ticks), cpu != usage { cpu = usage }
            previousTicks = ticks
        }
        let nextGPU = SystemSensors.gpuUtilization()
        if gpu != nextGPU { gpu = nextGPU }
        let nextMemory = SystemSensors.memory()
        if memory != nextMemory { memory = nextMemory }
        let nextPressure = SystemSensors.memoryPressure()
        if pressure != nextPressure { pressure = nextPressure }
        if privateEnabled { samplePrivate() }
    }

    private func samplePrivate() {
        if !didTryPrivate {
            didTryPrivate = true
            displayControl = PrivateLevelBackends.displayBrightness().map(ManagedLevelControl.init)
            keyboardControl = PrivateLevelBackends.keyboardBacklight().map(ManagedLevelControl.init)
        }
        if thermal == nil { thermal = ThermalSensors() }
        if let thermal {
            let summary = thermal.read()
            let next = (summary.cpu == nil && summary.gpu == nil) ? nil : summary
            if temperatures != next { temperatures = next }
        }
        if !adjusting {
            let nextBrightness = displayControl?.level
            if brightness != nextBrightness { brightness = nextBrightness }
            let nextKeyboard = keyboardControl?.level
            if keyboardBacklight != nextKeyboard { keyboardBacklight = nextKeyboard }
        }
    }

    private func releasePrivate() {
        thermal = nil
        displayControl = nil
        keyboardControl = nil
        didTryPrivate = false
        temperatures = nil
        brightness = nil
        keyboardBacklight = nil
    }
}
