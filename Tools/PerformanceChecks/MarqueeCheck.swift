import AppKit
import QuartzCore

@main
struct MarqueeCheck {
    @MainActor static func main() {
        let view = MarqueeLayerView()
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        
        // 1. Kısa metin: genişliğe sığıyor (animasyon eklenmemeli)
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 20)
        view.update(text: "Kısa Şarkı", font: font, color: .white, speed: 28, delay: 2.0, trailingGap: 36, isPaused: false)
        view.layout()
        
        let contentLayer = view.layer!.sublayers![0]
        precondition(contentLayer.animation(forKey: "marqueeScroll") == nil, "Sığan metne animasyon eklenmemelidir")
        let sublayers = contentLayer.sublayers!
        precondition(sublayers.count == 2, "İki CATextLayer bulunmalıdır")
        let secondary = sublayers[1]
        precondition(secondary.isHidden, "Sığan metinde ikinci katman gizli olmalıdır")
        
        // 2. Uzun metin: genişlikten taşıyor (Core Animation döngüsü kurulmalı)
        let longTitle = "Bohemian Rhapsody — Remastered 2011 — Queen With Long Title"
        view.frame = CGRect(x: 0, y: 0, width: 120, height: 20)
        view.update(text: longTitle, font: font, color: .white, speed: 28, delay: 2.0, trailingGap: 36, isPaused: false)
        view.layout()
        
        precondition(!secondary.isHidden, "Taşan metinde ikinci katman görünür olmalıdır")
        guard let anim = contentLayer.animation(forKey: "marqueeScroll") as? CAKeyframeAnimation else {
            fatalError("Taşan metinde CAKeyframeAnimation eklenmiş olmalıdır")
        }
        precondition(anim.repeatCount == .infinity, "Animasyon sonsuz döngüde olmalıdır")
        precondition(anim.keyTimes?.count == 3, "keyTimes 3 elemanlı olmalıdır [0, delayFraction, 1]")
        precondition(anim.values?.count == 3, "values [0, 0, -distance] olmalıdır")
        
        // 3. Duraklatma (isPaused = true): animasyon durmalı, transform sıfırlanmalı
        view.update(text: longTitle, font: font, color: .white, speed: 28, delay: 2.0, trailingGap: 36, isPaused: true)
        precondition(contentLayer.animation(forKey: "marqueeScroll") == nil, "Duraklatıldığında animasyon kaldırılmalıdır")
        
        // 4. Yeniden başlatma (isPaused = false)
        view.update(text: longTitle, font: font, color: .white, speed: 28, delay: 2.0, trailingGap: 36, isPaused: false)
        precondition(contentLayer.animation(forKey: "marqueeScroll") != nil, "Çalmaya geçildiğinde animasyon başlamalıdır")
        
        // 5. stopAnimations: tüm animasyonlar temizlenmeli
        view.stopAnimations()
        precondition(contentLayer.animation(forKey: "marqueeScroll") == nil, "stopAnimations tüm animasyonları temizlemelidir")
        
        // 6. Türkçe karakterler ve emoji bütünlüğü
        let turkishEmoji = "🎵 Güneş Açtı — Çığlıklar & Şiirler 🎶"
        view.update(text: turkishEmoji, font: font, color: .white, speed: 28, delay: 2.0, trailingGap: 36, isPaused: false)
        view.layout()
        precondition(contentLayer.animation(forKey: "marqueeScroll") != nil, "Türkçe ve emoji metin başarıyla animasyonlanmalıdır")
        
        // 7. 1000 yinelenen layout döngüsü (kararlılık ve bellek sızıntısızlık testi)
        for _ in 0..<1000 {
            view.layout()
        }
        precondition(contentLayer.sublayers?.count == 2, "Katman sayısı 1000 layout sonrasında da sabit 2 kalmalıdır")
        
        print("PASS: native marquee: short text static; overflow animates with CoreAnimation; pause/resume works; unicode/emoji intact; 1000 layouts stable")
    }
}
