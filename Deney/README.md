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
| Dokuz panel (Medya, Nook, Raf, Pano, Ses Mikseri, Odak, Notlar, Ayna, Sistem) | AppKit |
| Sürükle-bırak hedefi (Raf / AirDrop bölgeleri) | AppKit |
| Ayarlar, Araçlar, Dock önizlemeleri | SwiftUI barındırılıyor (istek üzerine açılan pencereler) |

## Eşdeğerlik kuralları (SwiftUI'den çalışma anında ölçülmüştür)

Her kural, aynı görünüm SwiftUI'de küçük bir koşum programında çizdirilip görünüm ağacı, yerleşim çerçeveleri,
AX ağacı ve 2× ekran görüntüsü okunarak çıkarılmıştır (araçlar: `OpenIsland-Evidence/20261021-appkit/tools`).

- **Bağlama sürümü:** Üretim ikilisi LC_BUILD_VERSION'da `sdk 14.0` taşır; AppKit/SwiftUI denetimleri bu yüzden
  Sonoma görünümüyle çizilir (yuvarlak kaydırıcı düğmesi, klasik açılır menü). Deney aynı platform sürümüyle bağlanır.
- **Görünüm:** SwiftUI kökü `.environment(\.colorScheme, .dark)`; tuvalde `NSAppearance.darkAqua`.
- **Metin:** satır yüksekliği punto tablosu (`TextMetrics`, 7–28 pt); metin kutusu genişliği piksele (0,5 pt) yukarı
  yuvarlanır; ortalı/sağa hizalı metin kutusu piksele oturur; tek satır kesme CoreText ile
  (`CTLineCreateTruncatedLine`, 61 genişlikte birebir); `minimumScaleFactor` ile küçülen satırın yüksekliği küçülmüş
  puntodan hesaplanır (19 pt × 0,99 → 22 pt).
- **Sembol:** yerleşim kutusu = hizalama genişliği × (görüntü yüksekliği − 0,5); görüntü kutunun sol-alt köşesine
  yaslanır; kökeni en yakın piksele yuvarlanır (24 sembol/boyut, 4 alt piksel konumda birebir). Adanın başlık
  satırında yarım piksel yukarı yuvarlanır (ekran görüntüsüyle belirlendi).
- **Label:** simge + 8 pt + metin; simge taban çizgisine hizalı (11 pt metinde taban 11,125 pt).
- **AppKit denetimleri:** SwiftUI'nin barındırdığı gibi hizalama dikdörtgeniyle yerleşir (küçük açılır menü 16 pt,
  mini 13 pt, kaydırıcı 16 pt; görünüm kenar boşlukları kadar taşar). `.buttonStyle(.plain)` içindeki menü seçici
  kenarlıksız/okuysuz. `TextEditor` ayarları (akıllı tırnak, ekleme imleci vurgu renginde…) birebir.
- **AX:** sembol görselinin çerçevesi mürekkep sınırı; metin çerçevesi metnin kapladığı alan; tembel yığının
  çerçevesi gerçekleşmiş çocukların birleşimi; yalnız simgeli düğmenin çerçevesi simge mürekkebi; Odak panelinde
  geometrik okuma sırası.
- **Animasyon:** hover/seçim geçişleri `CASpringAnimation` ile SwiftUI yay sabitleriyle (kütle 1, katılık
  (2π/response)², sönüm 4πζ/response), hedef değişince hız aktarılır, ölçek düğme merkezinden. Sekme tonu SwiftUI
  işlemiyle aynı: yerleşim değişirse `IslandMotion.resize`, değişmezse anında.

## Performans: SwiftUI (K8c, H9) ile A/B/B/A (2026-10-23, son sürüm)

Ölçüm: uygulamanın kendi denetimli kıyası (`OPENISLAND_BENCHMARK_V2`), faz sınırında `proc_pid_rusage` (talimat,
çevrim, enerji tahmini, CPU, uyanma, ayak izi) ve WindowServer CPU'su; yalıtılmış test verisi. Araçlar ve ham sonuçlar:
`OpenIsland-Evidence/20261021-appkit` (`tools/final.sh`, `runs/*-fts*`, `*-fic*`, `*-fie*`, `logs/wsvar.log`).
Geçersiz koşu yok.

Sekme geçişi (her hızda 4'er koşu; Δ = AppKit − SwiftUI):

| Aralık | Talimat/seçim | Çevrim/seçim | CPU | Enerji/seçim | Ayak izi | Uyanma | WindowServer |
|---|---|---|---|---|---|---|---|
| 650 ms | −44% | −48% | −46% | −47% | −23% | ≈0 | −2% |
| 300 ms | −41% | −48% | −46% | −44% | −27% | +2% | −2% |
| 150 ms | −52% | −55% | −53% | −57% | −27% | ≈0 | +3,5% |
| 80 ms | −48% | −52% | −41% | −70% | −27% | ≈0 | +10% |
| 50 ms | −48% | −50% | −37% | −77% | −27% | −9% | +10% |

Boşta (2'şer koşu, 325 s): kompakt — CPU −87%, uyanma 4,15 → 0,05/s, enerji −89%, WindowServer −11%, ayak izi
**+6% (+1,3 MiB; bir sonraki açılış için saklanan içerik)**. Açık — CPU/enerji/WindowServer eşit, uyanma −86%,
ayak izi −19%. Hover aç/kapat (8 döngü): uygulama CPU'su −47%.

Açık kalemler (kurala göre "daha fazla kaynak"):
- 80/50 ms hızlı geçişte WindowServer +8,5…10% (80 ms'de ayrı 4+4 koşu: SwiftUI %35,4, AppKit %38,4; maskesiz %38,9,
  bulanıklıksız %40,0 → maske/bulanıklık değil). Katman sayımı: görünür katman benzer (70–129 / 71–105) ama içerik
  taşıyan katman ~%80 fazla (her metin kendi dokusu). Aynı aralıkta uygulama CPU'su −17 yüzde puan, WindowServer +3
  yüzde puan: sistem toplamı belirgin düşük. 650–150 ms gerçekçi hızlarda fark yok.
- Boşta kompakt +1,3 MiB: açılışta kare kaybını önleyen saklanan içerik; kaldırılırsa ilk açılış ~40 ms donar.

## Akıcılık (kullanıcı testinde bulunan ve giderilen sorunlar)

| Sorun | Ölçüm | Çözüm |
|---|---|---|
| Açılışta 40–50 ms donma | Açılışta içerik kurulumu 17–33 ms + ilk çizim | Kapanan içerik saklanır ve yeniden kullanılır (`suspend`/`activate`: `didHide`/`didShow`, kaydırma/hover/odak sıfırlanır); yalnız ilk açılış için açılıştan sonra boşta uyku hâlinde ön kurulum |
| Büyüme ortasında yerinde sayan kare | Ekran videosu karelere ayrıldı | Yeni kurulan içerikte açılış yayı ilk kare ekrana çıkınca başlar |
| Arada bir "oyun lag'ı" | Kapanıştan hemen sonraki ön kurulum bir sonraki açılışın başına denk geliyordu (34–47 ms kare) | Ön kurulum yerine yeniden kullanım; 8 hızlı aç/kapa döngüsünde hareket içinde 0 kare kaybı |
| Ada kendi kendine kapanıp açılıyor | İmleç açık adanın alt kenarının 17–50 pt altına iniyordu | Açık adanın altında 40 pt hover payı (kullanıcı isteği; ana uygulamadan bilinçli fark) |
| Pencere sunucusu ek yükü | Core Image açılış bulanıklığı yarıçap 0'da takılı kalıyordu | Filtre yalnız bulanıklık sürerken takılı |
| Nook açılışı pahalı | Kısayollar her açılışta yeniden kuruluyor, büyük simgeler küçültülüyordu | Değişmedikçe yeniden kurulmaz; 28 pt simgeler önbellekte; tarih metinleri gün başına |

Tanı araçları (yalnız ortam değişkeniyle açılır, yoksa hiçbir şey yapmaz): `OPENISLAND_DENEY_FRAMELOG` (kare aralığı, tick süresi,
run-loop yükü, model değişimleri), `OPENISLAND_POINTER_LOG` (imleç giriş/çıkış ve faz değişimleri), kıyas modu
`OPENISLAND_BENCHMARK_V2=open-close` (`OPENISLAND_BENCHMARK_HOVER=1` ile hover yolu).

## Doğrulama

`tools/vis.sh UYGULAMA ETİKET` her iki uygulamayı yalıtılmış test verisiyle başlatır (Deney'in standart tercih
alanı SwiftUI uygulamasınınkinin kopyasıyla başlar), 8 sekmenin (Ayna kamera izni istediği için hariç) soğuk/sıcak
ekran görüntüsünü, AX ağacını ve AX çerçevelerini alır.
