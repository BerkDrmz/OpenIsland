import Testing
@testable import IslandCore

@Suite("Pil tasarrufu kuralı")
struct EnergyRulesTests {
    @Test func lowPowerModeSavesEnergyWhenEnabled() {
        #expect(EnergyRules.savesEnergy(isEnabled: true, lowPowerMode: true, thermal: .nominal))
        #expect(!EnergyRules.savesEnergy(isEnabled: true, lowPowerMode: false, thermal: .nominal),
                "Yalnızca pilde olmak ya da normal sıcaklık tasarrufu başlatmaz")
    }

    @Test func onlySeriousOrCriticalHeatSavesEnergy() {
        #expect(!EnergyRules.savesEnergy(isEnabled: true, lowPowerMode: false, thermal: .fair))
        #expect(EnergyRules.savesEnergy(isEnabled: true, lowPowerMode: false, thermal: .serious))
        #expect(EnergyRules.savesEnergy(isEnabled: true, lowPowerMode: false, thermal: .critical))
    }

    @Test func disabledSettingNeverSaves() {
        for thermal in [ThermalLevel.nominal, .fair, .serious, .critical] {
            for lowPower in [false, true] {
                #expect(!EnergyRules.savesEnergy(isEnabled: false, lowPowerMode: lowPower, thermal: thermal))
            }
        }
    }
}
