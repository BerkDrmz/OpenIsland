import AppKit
import Foundation
import IslandCore

/// Sistem sekmesinin verisi. **Yalnızca sekme görünürken ölçer**: `start`/`stop` panelin `onAppear`/`onDisappear`'ında
/// çağrılır; sekme kapalıyken (ada kapalı, başka sekme) zamanlayıcı, görev ve sensör işi yoktur.
/// CPU/GPU/bellek ve sıcaklık okumaları seri arka plan aktörlerinde yapılır; ölçüm aralığı
/// 2 sn (Düşük Güç Modu'nda 4 sn). Değişmeyen değerler yeniden yayımlanmaz.
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
        didSet {
            guard privateEnabled != oldValue else { return }
            privateRevision &+= 1
            if !privateEnabled { releasePrivate() }
        }
    }
    /// Düşük Güç Modu / ısınma: ölçüm aralığı uzar.
    @ObservationIgnored var slowPolling = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var storageTask: Task<Void, Never>?
    @ObservationIgnored private var storageObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var previousTicks: CPUTicks?
    @ObservationIgnored private let thermalWorker: ThermalSamplingWorker
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var privateRevision: UInt64 = 0
    @ObservationIgnored private let readPublic: @Sendable () async -> SystemSensors.Snapshot
    @ObservationIgnored private let readStorage: @Sendable () -> [StorageVolume]
    @ObservationIgnored private(set) var sampleCount = 0
    @ObservationIgnored private(set) var privateSampleCount = 0
    @ObservationIgnored private var displayControl: ManagedLevelControl?
    @ObservationIgnored private var keyboardControl: ManagedLevelControl?
    @ObservationIgnored private var didTryPrivate = false
    /// Kaydırıcı sürüklenirken değeri kullanıcı belirler; ölçüm onu ezmez.
    @ObservationIgnored private var adjusting = false
    @ObservationIgnored private var lastSampleInstant: ContinuousClock.Instant = .now - .seconds(10)

    var isRunning: Bool { task != nil }
    var storageObserverCount: Int { storageObservers.count }
    var canAdjustBrightness: Bool { displayControl?.canHandle ?? false }
    var canAdjustKeyboard: Bool { keyboardControl?.canHandle ?? false }

    init(thermalWorker: ThermalSamplingWorker = ThermalSamplingWorker(),
         readPublic: @escaping @Sendable () async -> SystemSensors.Snapshot = {
             await SystemSamplingWorker.shared.read()
         },
         readStorage: @escaping @Sendable () -> [StorageVolume] = { StorageVolume.read() }) {
        self.thermalWorker = thermalWorker
        self.readPublic = readPublic
        self.readStorage = readStorage
    }

    @ObservationIgnored private var panelViewers = 0

    func panelDidAppear() {
        panelViewers += 1
        if panelViewers == 1 { start() }
    }

    func panelDidDisappear() {
        guard panelViewers > 0 else { return }
        panelViewers -= 1
        if panelViewers == 0 { stop() }
    }

    func start() {
        guard task == nil else { return }
        generation &+= 1
        let token = generation
        let elapsed = ContinuousClock.now - lastSampleInstant
        if elapsed >= .milliseconds(1500) {
            previousTicks = nil
        }
        task = Task(priority: .utility) { [weak self] in
            // İlk okuma CPU için temel olur; ikinci okuma kısa sürede gelir ki panel boş kalmasın.
            guard !Task.isCancelled else { return }
            if let self {
                let elapsed = ContinuousClock.now - self.lastSampleInstant
                if elapsed >= .milliseconds(1500) {
                    await self.sample(generation: token)
                }
            }
            if let self, self.cpu == nil {
                try? await Task.sleep(for: .milliseconds(1000))
            } else {
                try? await Task.sleep(for: .seconds(self?.slowPolling == true ? 4 : 2))
            }
            while !Task.isCancelled {
                guard let self else { return }
                await self.sample(generation: token)
                try? await Task.sleep(for: .seconds(self.slowPolling ? 4 : 2))
            }
        }
        observeVolumes()
        // One cancellable read on entry also catches disk changes while the panel was closed.
        refreshStorage(after: .milliseconds(250))
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        adjusting = false
        storageTask?.cancel()
        storageTask = nil
        storageObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        storageObservers.removeAll()
    }

    /// Uyanma / ekran değişimi: devre dışı kalmış kontrole tek bir yeni hak.
    func recover() {
        privateRevision &+= 1 // re-enumerate cached sensor services after wake/display changes
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
    func refreshStorage(after delay: Duration = .milliseconds(50)) {
        guard isRunning else { return }
        storageTask?.cancel()
        let readStorage = self.readStorage
        storageTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            let read = Task.detached(priority: .utility) { readStorage() }
            let volumes = await withTaskCancellationHandler {
                await read.value
            } onCancel: {
                // Cancelling an unstructured parent task does not automatically
                // cancel a detached read. Let it stop between volume queries.
                read.cancel()
            }
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

    private func sample(generation token: UInt64) async {
        guard generation == token, !Task.isCancelled else { return }
        let revision = privateRevision
        let snapshot = await readPublic()
        guard generation == token, isRunning, !Task.isCancelled else { return }
        // Gather both snapshots first: publishing public values and temperatures on two
        // separate actor resumptions caused two layout passes for one measurement.
        let privateValues = privateEnabled && privateRevision == revision
            ? await samplePrivate(generation: token, revision: revision) : nil
        guard generation == token, isRunning, !Task.isCancelled else { return }
        lastSampleInstant = .now
        sampleCount += 1
        let nextUptime = ProcessInfo.processInfo.systemUptime
        if Int(nextUptime / 60) != Int(uptime / 60) { uptime = nextUptime }
        if let ticks = snapshot.ticks {
            if let previousTicks, let usage = CPUTicks.usage(from: previousTicks, to: ticks), cpu != usage { cpu = usage }
            previousTicks = ticks
        }
        if gpu != snapshot.gpu { gpu = snapshot.gpu }
        if memory != snapshot.memory { memory = snapshot.memory }
        if pressure != snapshot.pressure { pressure = snapshot.pressure }
        if let privateValues, privateEnabled, privateRevision == revision {
            if temperatures != privateValues.temperature { temperatures = privateValues.temperature }
            if !adjusting {
                if brightness != privateValues.brightness { brightness = privateValues.brightness }
                if keyboardBacklight != privateValues.keyboard { keyboardBacklight = privateValues.keyboard }
            }
        }
    }

    private struct PrivateValues {
        let temperature: TemperatureRules.Summary?
        let brightness: Float?
        let keyboard: Float?
    }

    private func samplePrivate(generation token: UInt64, revision: UInt64) async -> PrivateValues? {
        privateSampleCount += 1
        if !didTryPrivate {
            didTryPrivate = true
            displayControl = PrivateLevelBackends.displayBrightness().map(ManagedLevelControl.init)
            keyboardControl = PrivateLevelBackends.keyboardBacklight().map(ManagedLevelControl.init)
        }
        var nextTemperature = temperatures
        if PrivateAPIGuard.begin("temperature") {
            let summary = await thermalWorker.read(revision: revision)
            // Reader creation failure retains the existing private-API safety behavior.
            // A successful read with temporarily missing values is not an API failure.
            if summary != nil { PrivateAPIGuard.succeeded("temperature") }
            else { PrivateAPIGuard.failed("temperature") }
            guard generation == token, privateRevision == revision, isRunning,
                  privateEnabled, !Task.isCancelled else { return nil }
            nextTemperature = summary.flatMap { $0.cpu == nil && $0.gpu == nil ? nil : $0 }
        }
        return PrivateValues(temperature: nextTemperature,
                             brightness: adjusting ? brightness : displayControl?.level,
                             keyboard: adjusting ? keyboardBacklight : keyboardControl?.level)
    }

    private func releasePrivate() {
        displayControl = nil
        keyboardControl = nil
        didTryPrivate = false
        temperatures = nil
        brightness = nil
        keyboardBacklight = nil
    }
}
