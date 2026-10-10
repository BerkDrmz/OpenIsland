import Foundation
import IslandCore

/// Gerçek donanımda (GUI yok) Sistem sekmesinin veri katmanını doğrular. Hiçbir ayar değiştirilmez:
/// parlaklık ve klavye ışığı yalnızca okunur.
@main struct SystemMonitorCheck {
    @MainActor static func main() async throws {
        // The kernel right is shared by name, but every mach_host_self call adds a reference.
        // Repeated real sensor reads must leave the reference count unchanged.
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        func hostReferences() -> mach_port_urefs_t {
            var count: mach_port_urefs_t = 0
            precondition(mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &count) == KERN_SUCCESS)
            return count
        }
        let initialReferences = hostReferences()
        for _ in 0..<1000 {
            precondition(SystemSensors.cpuTicks() != nil)
            precondition(SystemSensors.memory() != nil)
        }
        precondition(hostReferences() == initialReferences, "CPU/memory readings leaked Mach send rights")
        print("PASS: 1000 CPU + 1000 memory reads; host send-right references unchanged (\(initialReferences))")

        // Exercise real sensor creation/read/destruction, not cancelled tasks that never sample.
        // Warm the allocator first; leaked IOHID clients previously grew ~9 MiB over 400 cycles.
        func thermalCycle() -> Bool {
            autoreleasepool {
                guard let sensor = ThermalSensors() else { return false }
                let value = sensor.read()
                return value.cpu != nil || value.gpu != nil
            }
        }
        if thermalCycle() {
            for _ in 0..<100 { precondition(thermalCycle()) }
            try await Task.sleep(for: .milliseconds(200))
            let before = physicalFootprint()
            for _ in 0..<400 { precondition(thermalCycle()) }
            try await Task.sleep(for: .milliseconds(200))
            let after = physicalFootprint()
            let growth = after > before ? after - before : 0
            precondition(growth < 2 * 1024 * 1024,
                         "Thermal sensor lifecycle leaked memory: \(growth) bytes over 400 cycles")
            print("PASS: 400 thermal sensor open/read/close cycles; settled growth \(growth) bytes after warm-up")
        } else {
            print("SKIP: thermal sensor lifecycle; compatible temperature sensors unavailable")
        }
        let monitor = SystemMonitor()
        precondition(!monitor.isRunning)
        monitor.start()
        try await Task.sleep(for: .seconds(3.2))
        precondition(monitor.isRunning)
        precondition(monitor.storageObserverCount == 3)
        let reads = monitor.storageReadCount
        precondition(reads == 1, "Storage must be read once on panel entry, not every CPU sample")
        let displayedUptime = monitor.uptime
        try await Task.sleep(for: .seconds(1.5))
        if Int(ProcessInfo.processInfo.systemUptime / 60) == Int(displayedUptime / 60) {
            precondition(monitor.uptime == displayedUptime,
                         "Minute-precision uptime label was republished during an unchanged minute")
        }
        precondition(monitor.storage.contains { $0.id == "/" }, "System volume not read")
        for volume in monitor.storage {
            precondition(volume.total > 0 && (0...volume.total).contains(volume.available))
        }
        print("Storage: \(monitor.storage.map { "\($0.name): \(ByteCountFormatter.string(fromByteCount: $0.available, countStyle: .file)) boş" }.joined(separator: " · "))")
        monitor.refreshStorage()
        try await Task.sleep(for: .milliseconds(400))
        precondition(monitor.storageReadCount == reads + 1, "Manual storage refresh did not complete")
        let cpu = monitor.cpu, memory = monitor.memory
        precondition(cpu != nil && (0...1).contains(cpu!), "CPU kullanımı okunamadı: \(String(describing: cpu))")
        precondition(memory != nil && memory!.usedBytes > 0 && memory!.usedBytes <= memory!.totalBytes, "Bellek geçersiz")
        precondition(monitor.uptime > 60, "Çalışma süresi geçersiz")
        if let gpu = monitor.gpu { precondition((0...1).contains(gpu)) }
        if let t = monitor.temperatures {
            for value in [t.cpu, t.gpu].compactMap({ $0 }) { precondition((10.0...120.0).contains(value), "Sıcaklık aralık dışı: \(value)") }
        }
        if let b = monitor.brightness { precondition((0...1).contains(b)) }
        if let k = monitor.keyboardBacklight { precondition((0...1).contains(k)) }
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "yok" }
        print("CPU %\(fmt(cpu.map { $0 * 100 })) · GPU %\(fmt(monitor.gpu.map { $0 * 100 })) · bellek \(memory!.usedBytes >> 20) / \(memory!.totalBytes >> 20) MB · sıkıştırılmış \(memory!.compressedBytes >> 20) MB · takas \(memory!.swapUsedBytes >> 20) MB · basınç \(monitor.pressure)")
        print("sıcaklık CPU \(fmt(monitor.temperatures?.cpu)) °C · GPU \(fmt(monitor.temperatures?.gpu)) °C · parlaklık \(monitor.brightness.map { String(format: "%.2f", $0) } ?? "yok") (ayarlanabilir \(monitor.canAdjustBrightness)) · klavye ışığı \(monitor.keyboardBacklight.map { String(format: "%.2f", $0) } ?? "yok") (ayarlanabilir \(monitor.canAdjustKeyboard))")

        for feature in ["temperature", "brightness", "keyboard"] {
            precondition(UserDefaults.standard.string(forKey: "privateAPI.\(feature).pending") == nil,
                         "\(feature): başarılı ilk çağrıdan sonra çökme işareti silinmeli")
        }

        // Kapatma: görev ve sensör istemcisi bırakılır; tekrar açılabilir.
        monitor.stop()
        precondition(!monitor.isRunning)
        precondition(monitor.storageObserverCount == 0)
        let stoppedReads = monitor.storageReadCount
        let stoppedUptime = monitor.uptime
        for _ in 0..<100 { monitor.start(); monitor.stop() }
        try await Task.sleep(for: .milliseconds(700))
        precondition(monitor.storageObserverCount == 0 && monitor.storageReadCount == stoppedReads, "Storage work leaked after close")
        precondition(monitor.uptime == stoppedUptime, "Cancelled task sampled after panel closed")
        precondition(!monitor.isRunning, "Hızlı aç-kapa görevi açık bıraktı")

        // Private ayar kapalıyken hiçbir private değer tutulmaz.
        monitor.privateEnabled = false
        precondition(monitor.temperatures == nil && monitor.brightness == nil && monitor.keyboardBacklight == nil)
        monitor.start()
        try await Task.sleep(for: .seconds(1.2))
        precondition(monitor.temperatures == nil && monitor.brightness == nil, "Kapalıyken private okuma yapıldı")
        precondition(monitor.cpu != nil, "Private kapalıyken genel ölçümler çalışmalı")
        monitor.stop()
        print("PASS System: gerçek donanımda CPU/GPU/bellek/sıcaklık/parlaklık/klavye ışığı okunuyor; aç-kapa görevi sızdırmıyor; private kapalıyken private çağrı yok")
    }

    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS, "Cannot read process physical footprint")
        return info.phys_footprint
    }
}
