import Accelerate
import CoreAudio
import os

/// Sadece kullanıcı uygulamanın sesini/routunu değiştirdiğinde kurulur. 100% + varsayılan çıkışta
/// kaynak yoktur. Kaynak ses ancak tap'ten gerçek örnekler geldikten sonra değiştirilir.
@available(macOS 14.2, *)
@MainActor
final class ApplicationAudioRoute {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private let gain = OSAllocatedUnfairLock(initialState: (target: Float(1), current: Float(0), ready: false, hasAudio: false))
    private var retainedDescription: CATapDescription?
    private var started = false
    private var readinessTask: Task<Void, Never>?
    var onFailure: ((Error) -> Void)?

    /// Read only on a hardware event or user action, never from the audio callback.
    /// A retained route can outlive its HAL device after sleep or an audio restart.
    var isOperational: Bool {
        if readinessTask != nil { return true }
        guard tap != 0 else { return false }
        if aggregate == 0 { return retainedDescription?.muteBehavior == .muted }
        return started
            && AudioHardwareAccess.scalar(aggregate, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) == 1
            && AudioHardwareAccess.scalar(aggregate, kAudioDevicePropertyDeviceIsRunning, initial: UInt32(0)) == 1
    }

    var monitoredDevice: AudioObjectID { aggregate }

    /// On-demand developer snapshot; no extra work in the realtime callback.
    var diagnosticState: String {
        let state = gain.withLock { $0 }
        return "started=\(started) operational=\(isOperational) tap=\(tap) starting=\(readinessTask != nil) device=\(aggregate) ready=\(state.ready) signal=\(state.hasAudio) target=\(state.target) current=\(state.current)"
    }

    func interruptForDiagnostics() {
        guard ProcessInfo.processInfo.environment["OPENISLAND_DIAGNOSTICS"] != nil, aggregate != 0 else { return }
        AudioDeviceStop(aggregate, io)
    }

    func start(processes: [AudioObjectID], outputUID: String, volume: Float) throws {
        stop()
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "OpenIsland Ses Mikseri"
        description.uuid = UUID()
        description.isPrivate = true
        // macOS can return successful tap/IO creation with all-zero buffers when
        // audio access is denied. Keep the original audible until input is verified.
        description.muteBehavior = volume == 0 ? .muted : .unmuted
        retainedDescription = description
        gain.withLock { $0 = (target: volume, current: 0, ready: false, hasAudio: false) }
        do {
            try caCheck(AudioHardwareCreateProcessTap(description, &tap), "Uygulama ses erişimi")
            // Sessiz modda yalnızca tap mute: aggregate/realtime callback çalıştırma.
            if volume == 0, tap != 0 { return }
            if volume != 0, tap != 0 { _ = try configureOutput(outputUID: outputUID) }
            readinessTask = Task { [weak self] in
                // Only bounded startup checks. No timer, metering or task remains
                // once routing is ready, cancelled, or rejected by macOS.
                for delay in [Duration.milliseconds(100), .milliseconds(200), .milliseconds(500), .seconds(2), .milliseconds(100)] {
                    do { try await Task.sleep(for: delay) } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    // HAL can briefly report success with kAudioObjectUnknown after
                    // another tap is destroyed. Keep the requested gain while retrying
                    // this startup only; never retain an unusable route indefinitely.
                    if self.tap == 0 {
                        guard let description = self.retainedDescription else { return }
                        do {
                            try caCheck(AudioHardwareCreateProcessTap(description, &self.tap), "Uygulama ses erişimi")
                        } catch {
                            self.fail(error)
                            return
                        }
                        guard self.tap != 0 else { continue }
                    }
                    if volume == 0 {
                        self.readinessTask = nil
                        return
                    }
                    if self.aggregate == 0 {
                        do {
                            guard try self.configureOutput(outputUID: outputUID) else { continue }
                        } catch {
                            self.fail(error)
                            return
                        }
                    }
                    if self.gain.withLock({ $0.hasAudio }) {
                        guard let description = self.retainedDescription else { return }
                        description.muteBehavior = .mutedWhenTapped
                        guard AudioHardwareAccess.write(self.tap, kAudioTapPropertyDescription, description) else {
                            self.fail(CoreAudioError(status: -1, operation: "Kaynak ses yönlendirilemedi"))
                            return
                        }
                        self.gain.withLock { $0.ready = true }
                        self.readinessTask = nil
                        return
                    }
                }
                self?.fail(CoreAudioError(status: -1, operation: "Uygulama sesi alınamadı; sesin çaldığını ve OpenIsland’in sistem sesi iznini kontrol et"))
            }
        } catch {
            stop()
            throw error
        }
    }

    /// HAL may publish the tap before its format becomes readable, especially
    /// immediately after destroying a previous tap. Retry only during bounded startup;
    /// the original audio remains audible until real samples arrive.
    private func configureOutput(outputUID: String) throws -> Bool {
        guard let description = retainedDescription else { return false }
        guard let format = AudioHardwareAccess.scalar(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()), format.mSampleRate > 0 else { return false }
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2 else {
            throw CoreAudioError(status: -1, operation: "Desteklenmeyen ses biçimi")
        }
        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenIsland Mixer",
            kAudioAggregateDeviceUIDKey: "OpenIsland.Mixer." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID, kAudioSubDeviceInputChannelsKey: 0, kAudioSubDeviceOutputChannelsKey: 2]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                             kAudioSubTapDriftCompensationKey: true]]
        ]
        try caCheck(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregate), "Ses yönlendirme")
        // Yalnızca iki kanallı PCM çıkışı destekle; farklı formatta sessizce sesi bozma.
        guard let outputFormat = AudioHardwareAccess.scalar(aggregate, kAudioDevicePropertyStreamFormat,
                   initial: AudioStreamBasicDescription(), scope: kAudioDevicePropertyScopeOutput),
              outputFormat.mFormatID == kAudioFormatLinearPCM,
              outputFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              outputFormat.mBitsPerChannel == 32, outputFormat.mChannelsPerFrame == 2 else {
            throw CoreAudioError(status: -1, operation: "Çıkış aygıtı stereo Float32 desteklemiyor")
        }
        let gain = self.gain
        // Core Audio invokes this on its realtime thread. Explicit Sendable prevents
        // Swift 6 from inheriting the enclosing MainActor and trapping in the callback.
        try caCheck(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, nil) { @Sendable _, input, _, output, _ in
            // Realtime callback: dosya/ağ, allocation, log, UI, task veya metering yok.
            // This synchronous, nonescaping lock closure uses the callback's
            // input pointer only while Core Audio owns that buffer.
            let (old, value) = gain.withLockUnchecked { state in
                if !state.hasAudio { state.hasAudio = AudioGainProcessor.containsSignal(input: input) }
                let old = state.current
                let value = state.ready ? state.target : 0
                state.current = value
                return (old, value)
            }
            AudioGainProcessor.render(input: input, output: output, from: old, to: value)
        }, "Ses işleyicisi")
        try caCheck(AudioDeviceStart(aggregate, io), "Ses işleyicisini başlat")
        started = true
        return true
    }

    func setVolume(_ value: Float) { gain.withLock { $0.target = min(max(value, 0), 1) } }

    func stop() {
        readinessTask?.cancel()
        readinessTask = nil
        if aggregate != 0 {
            if started { AudioDeviceStop(aggregate, io) }
            if let io { AudioDeviceDestroyIOProcID(aggregate, io) }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        io = nil
        aggregate = 0
        started = false
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        tap = 0
        retainedDescription = nil
    }

    private func fail(_ error: Error) {
        stop()
        onFailure?(error)
    }
}
