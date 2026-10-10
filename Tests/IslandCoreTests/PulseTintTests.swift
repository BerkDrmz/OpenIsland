import Testing
@testable import IslandCore

@Suite("Albüm renginde nabız")
struct PulseTintTests {
    typealias RGB = PulseTint.RGB

    private func pixels(_ color: RGB, count: Int) -> [RGB] { Array(repeating: color, count: count) }

    @Test func blackAndWhiteCoverGetsSilver() {
        let cover = pixels(RGB(red: 0.1, green: 0.1, blue: 0.1), count: 300) + pixels(RGB(red: 0.8, green: 0.8, blue: 0.82), count: 276)
        #expect(PulseTint.albumTint(pixels: cover) == PulseTint.silver)
    }

    /// Kullanıcının bildirdiği sorun: ortalama renk alınınca renkli kapak bulanık bir tona düşüyordu.
    /// Turuncu gömlek + gri arka plan: nabız turuncu olmalı, ten rengi/gri değil.
    @Test func dominantVividHueWinsOverMutedBackground() throws {
        let cover = pixels(RGB(red: 0.45, green: 0.42, blue: 0.40), count: 400) // soluk arka plan
            + pixels(RGB(red: 0.85, green: 0.35, blue: 0.10), count: 150)       // turuncu
            + pixels(RGB(red: 0.15, green: 0.30, blue: 0.70), count: 26)        // küçük mavi ayrıntı
        let tint = try #require(PulseTint.albumTint(pixels: cover))
        let (hue, saturation, brightness) = PulseTint.hsv(tint)
        #expect(hue > 0.02 && hue < 0.1, "turuncu tonu korunur: \(hue)")
        #expect(saturation >= 0.45, "soluk değil")
        #expect(brightness > 0.99, "parlaklık en üstte")
    }

    @Test func darkBlueIsLightenedJustEnoughToReadOnBlack() throws {
        let tint = try #require(PulseTint.albumTint(pixels: pixels(RGB(red: 0.05, green: 0.08, blue: 0.5), count: 100)))
        #expect(PulseTint.luminance(tint) >= PulseTint.minimumLuminance - 0.001)
        #expect(PulseTint.luminance(tint) < PulseTint.minimumLuminance + 0.01, "gerekenden fazla beyazlatılmaz")
        #expect(tint.blue > tint.red && tint.blue > tint.green, "mavi kalır")
    }

    @Test func brightColorKeepsItsHueAtFullBrightness() throws {
        let tint = try #require(PulseTint.albumTint(pixels: pixels(RGB(red: 0.9, green: 0.2, blue: 0.6), count: 50)))
        let (hue, _, brightness) = PulseTint.hsv(tint)
        #expect(abs(hue - PulseTint.hsv(RGB(red: 0.9, green: 0.2, blue: 0.6)).hue) < 0.05)
        #expect(brightness > 0.99)
        #expect((PulseTint.luminance(tint) + 0.05) / 0.05 >= 5, "siyah üzerinde en az 5:1")
    }

    @Test func emptyOrInvalidInputKeepsDefaultAmber() {
        #expect(PulseTint.albumTint(pixels: []) == nil)
        #expect(PulseTint.albumTint(pixels: [RGB(red: .nan, green: 0.5, blue: 0.5)]) == nil)
    }
}
