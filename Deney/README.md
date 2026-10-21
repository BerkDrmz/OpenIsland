# OpenIsland — AppKit deneyi

Amaç: OpenIsland'ın arayüzünü SwiftUI yerine AppKit + Core Animation ile, **aynı görünüm, animasyon ve
davranışla** ve daha düşük CPU/GPU/enerjiyle yeniden yazmak. Her adım SwiftUI sürümüyle (K8c) gerçek A/B/B/A
ölçümüyle karşılaştırılır; daha fazla kaynak harcayan mimari değişiklik kabul edilmez.

## Mimari

- **Ortak katman:** `Sources/IslandCore` (durum makinesi, yerleşim motoru) ve `Sources/OpenIsland` altındaki
  bütün servisler (`AppEnvironment`, `IslandCoordinator`, `IslandViewModel`, medya, pano, raf, notlar, sistem…)
  ana uygulamayla aynıdır. Deney yalnız arayüzü değiştirir.
- **Arayüz:** `Deney/Sources`. `NotchWindowController` ana uygulamanın aynısıdır; tek fark, içerik olarak SwiftUI
  `IslandRootView` yerine AppKit `IslandCanvasView` takılmasıdır (girdi yönlendirme, sensör, Space davranışı ortak).
- **Olay tabanlı:** model `withObservationTracking` ile yalnız değişince bir kez bildirir; yoklama yok.
- **Animasyon:** SwiftUI `spring(response:dampingFraction:)` ile aynı fizik (`Motion.swift`, analitik çözüm, hedef
  değişiminde hız korunur). Ekran tazelemesine bağlı sürücü yalnız animasyon sürerken çalışır; durağan adada iş yok.
  Ada yolu her karede `IslandShape` geometrisinden üretilir (sürekli eğrilikli köşeler birebir).
- **Yerleşim:** her durumun içeriği kendi sabit boyutunda, elle (frame) yerleşir; Auto Layout ve kare başı yerleşim
  geçişi yok. Paneller sekme başına bir kez kurulur ve açık oturum boyunca pencerede kalır; görünmeyen panel iş
  yapmaz, `onAppear/onDisappear` anlamı `didShow/didHide` ile korunur.
- **Güvenlik:** ayrı paket kimliği (`io.github.openisland.deney`), ayrı veri klasörü
  (`~/Library/Application Support/io.github.openisland.deney`), oturum açılış öğesi kaydı yok (`OPENISLAND_DENEY`).

## Derleme

```bash
./Deney/build.sh
```

Çıktı: `Deney/build/OpenIsland Deney.app`. Kurulu OpenIsland ile aynı anda çalışırsa iki ada üst üste biner.

## Durum

| Parça | Durum |
|---|---|
| Uygulama girişi, menü çubuğu menüsü | AppKit |
| Pencere, sensör, girdi yönlendirme, Space | Ortak (AppKit) |
| Ada yüzeyi, morph, gevşeme, içerik geçişleri | AppKit |
| Kalıcı medya katmanları (kapak, nabız) | AppKit |
| Kompakt, HUD, bildirimler, kilit açma, ses aygıtı, bırakma bölgesi | AppKit |
| Genişletilmiş kabuk: sekmeler, seçim kapsülü, iğne, başlık kayması, HUD şeridi | AppKit |
| Paneller (Medya, Nook, Raf, Pano, Odak, Notlar, Ayna, Mikser, Sistem) | Sırayla çevriliyor |
| Sürükle-bırak hedefi | Yapılacak |
| Ayarlar, Araçlar, Dock önizlemeleri | Şimdilik SwiftUI (sonra) |
