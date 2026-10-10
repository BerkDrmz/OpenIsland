import Foundation
import IOKit
import IslandCore

/// CPU, bellek ve GPU okumaları: mach/sysctl ve IORegistry; yalnızca ölçüm sırasında çağrılır, arka plan işi yok.
enum SystemSensors {
    static func cpuTicks() -> CPUTicks? {
        // mach_host_self returns an owned send right on every call, including failed reads.
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // (user, system, idle, nice)
        return CPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                        idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }

    static func memory() -> MemoryBreakdown? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? swap.xsu_used : 0
        return MemoryRules.breakdown(
            pageSize: UInt64(getpagesize()), total: ProcessInfo.processInfo.physicalMemory,
            internalPages: UInt64(stats.internal_page_count), purgeablePages: UInt64(stats.purgeable_count),
            wiredPages: UInt64(stats.wire_count), compressorPages: UInt64(stats.compressor_page_count),
            externalPages: UInt64(stats.external_page_count), swapUsed: swapUsed)
    }

    static func memoryPressure() -> MemoryRules.Pressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryRules.pressure(level: Int(level))
    }

    /// GPU kullanımı (0...1): IORegistry `IOAccelerator` › `PerformanceStatistics` › "Device Utilization %".
    /// Belgelenmemiş bir anahtar; yoksa `nil` (arayüz "—" gösterir).
    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue, percent.isFinite {
                best = max(best ?? 0, min(max(percent / 100, 0), 1))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return best
    }
}
