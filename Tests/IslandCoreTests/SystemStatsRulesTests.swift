import Testing
@testable import IslandCore

@Suite("Sistem istatistik kuralları")
struct SystemStatsRulesTests {
    @Test func cpuUsageFromTickDeltas() throws {
        let a = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let b = CPUTicks(user: 160, system: 70, idle: 920, nice: 10)
        let usage = try #require(CPUTicks.usage(from: a, to: b))
        #expect(abs(usage - 90.0 / 160.0) < 1e-9)
        #expect(CPUTicks.usage(from: a, to: a) == nil, "Aynı okuma: fark yok")
        #expect(CPUTicks.usage(from: b, to: a) == nil, "Sayaç geriye gitti (uyanma/sıfırlama)")
    }

    @Test func memoryMatchesActivityMonitorDefinition() {
        let page: UInt64 = 16_384
        let b = MemoryRules.breakdown(pageSize: page, total: 16 << 30, internalPages: 500_000, purgeablePages: 50_000,
                                      wiredPages: 150_000, compressorPages: 200_000, externalPages: 190_000, swapUsed: 1 << 30)
        #expect(b.usedBytes == (450_000 + 150_000 + 200_000) * page)
        #expect(b.compressedBytes == 200_000 * page)
        #expect(b.cachedBytes == (190_000 + 50_000) * page)
        #expect(b.swapUsedBytes == 1 << 30)
        let clamped = MemoryRules.breakdown(pageSize: page, total: 1 << 20, internalPages: 100, purgeablePages: 500,
                                            wiredPages: 10_000_000, compressorPages: 0, externalPages: 0, swapUsed: 0)
        #expect(clamped.usedBytes == 1 << 20, "Toplamı aşmaz; internal < purgeable sıfıra kenetlenir")
        #expect(clamped.usedFraction == 1)
    }

    @Test func pressureLevels() {
        #expect(MemoryRules.pressure(level: 1) == .normal)
        #expect(MemoryRules.pressure(level: 2) == .warning)
        #expect(MemoryRules.pressure(level: 4) == .critical)
        #expect(MemoryRules.pressure(level: 99) == .normal)
    }

    /// Cihazdan okunan gerçek ad kümesi: kalibrasyon (−22 °C) ve pil/NAND sensörleri hariç tutulur.
    @Test func temperatureGroupsIgnoreInvalidAndUnrelatedSensors() throws {
        let readings: [(name: String, celsius: Double)] = [
            ("PMU tdie1", 36), ("PMU tdie2", 40), ("PMU tdev1", -22), ("PMU tcal", 51.8),
            ("PMU2 tdie1", 32), ("PMU2 tdie2", 34), ("PMU2 tdev3", -22.2),
            ("gas gauge battery", 30), ("NAND CH0 temp", 32), ("PMU tdie3", -5),
        ]
        let summary = TemperatureRules.summarize(readings)
        #expect(summary.cpu == 40, "yalnızca geçerli PMU tdie sensörlerinden alınan en yüksek gerçek değer")
        #expect(summary.gpu == 34)
        #expect(TemperatureRules.summarize([("gas gauge battery", 30)]) == .init(cpu: nil, gpu: nil), "Eşleşme yoksa gösterilmez")
        #expect(TemperatureRules.summarize([]) == .init(cpu: nil, gpu: nil))
    }

    @Test func temperatureUsesLatestSensorValueWithoutKeepingHistoricPeakOrSmoothing() {
        let high = TemperatureRules.summarize([("PMU tdie1", 71.625), ("PMU tdie2", 65.125), ("PMU2 tdie1", 55.25)])
        #expect(high == .init(cpu: 71.625, gpu: 55.25))
        let next = TemperatureRules.summarize([("PMU tdie1", 39.875), ("PMU tdie2", 40.0625),
            ("PMU tdie3", .nan), ("PMU tdie4", .infinity), ("PMU tdie5", 121),
            ("PMU2 tdie1", 35.125), ("PMU2 tdie2", -22)])
        #expect(next == .init(cpu: 40.0625, gpu: 35.125))
        #expect(TemperatureRules.summarize([("PMU tdie1", .nan), ("PMU2 tdie1", .infinity)]) == .init(cpu: nil, gpu: nil))
    }

    @Test func privateGuardBlocksBuildThatCrashedAndRetriesAfterUpdate() {
        let clean = PrivateAPIGuardRules.State(pendingBuild: nil, blockedBuild: nil)
        let afterLaunch = PrivateAPIGuardRules.launch(clean, currentBuild: "26A434")
        #expect(PrivateAPIGuardRules.isAllowed(afterLaunch, currentBuild: "26A434"))

        // Deneme başladı, süreç çöktü: pending kaldı.
        let crashed = PrivateAPIGuardRules.State(pendingBuild: "26A434", blockedBuild: nil)
        let next = PrivateAPIGuardRules.launch(crashed, currentBuild: "26A434")
        #expect(next.blockedBuild == "26A434" && next.pendingBuild == nil)
        #expect(!PrivateAPIGuardRules.isAllowed(next, currentBuild: "26A434"), "Aynı yapıda tekrar denenmez")

        // macOS güncellendi: yeni yapıda yeniden denenir.
        let updated = PrivateAPIGuardRules.launch(next, currentBuild: "26A500")
        #expect(updated.blockedBuild == nil)
        #expect(PrivateAPIGuardRules.isAllowed(updated, currentBuild: "26A500"))
    }

}
