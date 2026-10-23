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
| Dock önizlemeleri | AppKit (`DockPreviewPanelView`; denetleyici ortak, içerik `#if OPENISLAND_DENEY`). SwiftUI ile yan yana koşum (`OPENISLAND_DENEY_DOCKPARITY`): bütün öğe sınır kutuları ve AX ağacı/çerçeveleri birebir, kalan piksel farkı 1–2 düzey (ölçeklenen önizlemede tek sütun ≤39); gösterim başına CPU 5,3 → 3,3 ms |
| Ayarlar, Araçlar | SwiftUI barındırılıyor (istek üzerine açılan pencereler) |

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
`OpenIsland-Evidence/20261021-appkit` (`tools/final2.sh`, `runs/*-gts*`, `wsoc/goc-*`, `logs/final2.log`; önceki tur
`tools/final.sh`, `runs/*-fts*`, `*-fic*`, `*-fie*`). Geçersiz koşu yok.

Sekme geçişi (her hızda 4'er koşu; Δ = AppKit − SwiftUI; parantezde mutlak uygulama CPU'su):

| Aralık | Talimat/seçim | Çevrim/seçim | CPU | Enerji/seçim | Ayak izi | Uyanma | WindowServer |
|---|---|---|---|---|---|---|---|
| 650 ms | −63% | −67% | −64% (18,9 → 6,8%) | −53% | −28% | +2% | −12% |
| 300 ms | −62% | −69% | −64% (30,8 → 11,1%) | −51% | −28% | +7% | −6% |
| 150 ms | −81% | −76% | −68% (42,9 → 13,9%) | −86% | −28% | +11% | −3% |
| 80 ms | −79% | −73% | −58% (47,4 → 19,7%) | −90% | −28% | +8% | +1% |
| 50 ms | −76% | −65% | −47% (50,2 → 26,7%) | −91% | −28% | +9% | +7% |

Hover aç/kapat (8 döngü, 4'er koşu): uygulama CPU süresi SwiftUI 1150 ms → AppKit 510 ms (−56%), WindowServer −5%.
Boşta (önceki tur, 2'şer koşu, 325 s): kompakt — CPU −87%, uyanma 4,15 → 0,05/s, enerji −89%, WindowServer −11%, ayak
izi **+6% (+1,3 MiB; bir sonraki açılış için saklanan içerik)**. Açık — CPU/enerji/WindowServer eşit, uyanma −86%, ayak
izi −19%. Son turdan sonra boşta tekrar (önceki sürümle A/B/B/A, `logs/idle2.log`): kompakt ve açıkta CPU %0,001,
uyanma 0/s, ayak izi aynı; boşta gerileme yok.

Son turdaki CPU düşüşleri (her biri ayrı A/B ile kabul edildi; 80 ms'de uygulama CPU'su 35,1 → 19,7%, enerji/seçim
2,58 → 1,13 mJ):

| Bulgu (Time Profiler + `OPENISLAND_DENEY_IMGPROBE`) | Çözüm |
|---|---|
| Başlık kayma yayında her karede sembol çerçevesi değişiyordu; `NSImageView` her çerçeve değişiminde iç görüntü alt görünümünü güncelleyip sembolü yeniden rasterleştiriyordu (uygulama CPU'sunun ~%28'i) | Çerçeve yerinde, görünen kayma `sublayerTransform` (dururken birim dönüşüm). Yan etki: önceki sürüm kaymadan sonra kesirli konumda rasterleşmiş görüntüyü dururken de taşıyordu; şimdi başlık her sekmede SwiftUI referansına önceki kadar yakın (ilk sekmedeki taban farkta) |
| `contentTintColor`'a aynı rengi atamak sembolü yeniden rasterleştiriyor | Yalnız renk değişince yazılır |
| Kare sürücülerinin her biri ayrı Core Animation commit'i yapıyordu | `FrameClock`: penceredeki sürücüler tek ekran tazelemesi geri çağrısında, kare başına tek commit |
| `needsLayout` her karede pencerenin bütün görünüm ağacını taratıyordu (başlık etiketi, kapak köşesi) | Doğrudan yerleştirme |
| `isFlipped` @objc köprüsü her çağrıda ana aktör denetimi (~%3) | `nonisolated` |
| `TextLabel` genişliği/yüksekliği her yerleşimde CoreText/TextKit ile yeniden ölçülüyordu (Pano satırları) | Metin/yazı tipi değişene kadar önbellek |
| Nook takvim/anımsatıcı listeleri, Notlar menüsü, Pano satırları her gösterimde aynı veriyle yeniden kuruluyordu | Yalnız veri değişince |
| Seçim kapsülü görünümü kayma/yeniden boyutlama yayında her karede taşınıyor, pencerenin izleme alanı hesabını yeniliyordu | Kapsül başlık katmanında düz `CALayer` (aynı katman özellikleri; görüntü ve AX birebir aynı); talimat/seçim −%4,7, WindowServer'da tutarlı fark yok (`logs/wsm.log`) |

Reddedilen deney: gizlenen panelleri görünüm ağacından ayırmak (katman sayısını azaltır) uygulama CPU'sunu +%4,
talimatı +%20 artırdı; WindowServer'da ölçülebilir kazanç yok.

Açık kalemler (kurala göre "daha fazla kaynak"):
- 50 ms geçişte WindowServer +%7 (80 ms'de fark gürültü içinde). Katman ağacı hazırlığı: içerik taşıyan katman sayısı
  SwiftUI'den fazla. Aynı aralıkta uygulama CPU'su −23 yüzde puan, WindowServer +2,7 yüzde puan: sistem toplamı belirgin
  düşük.
- Hızlı geçişte uyanma +%2…11 (önceki sürümlerde de vardı; kare saati açık/kapalı aynı). Muhtemel kaynak: her geçişte
  panel sönmesinin bitişi için kurulan zamanlayıcı; kaldırmak `didHide` zamanlamasını değiştirir.
- Pano ve Mikser sekme simgelerinin seçim rengi animasyonu her karede yeniden rasterleşir: SwiftUI de bu iki simgede
  renk animasyonu kullanır (üst üste binen alt yollar; `TabIconTintCheck`).
- Boşta kompakt +1,3 MiB: açılışta kare kaybını önleyen saklanan içerik; kaldırılırsa ilk açılış ~40 ms donar.

## Akıcılık (kullanıcı testinde bulunan ve giderilen sorunlar)

| Sorun | Ölçüm | Çözüm |
|---|---|---|
| Açılışta 40–50 ms donma | Açılışta içerik kurulumu 17–33 ms + ilk çizim | Kapanan içerik saklanır ve yeniden kullanılır (`suspend`/`activate`: `didHide`/`didShow`, kaydırma/hover/odak sıfırlanır); yalnız ilk açılış için açılıştan sonra boşta uyku hâlinde ön kurulum |
| Büyüme ortasında yerinde sayan kare | Ekran videosu karelere ayrıldı | Yeni kurulan içerikte açılış yayı ilk kare ekrana çıkınca başlar |
| Arada bir "oyun lag'ı" | Kapanıştan hemen sonraki ön kurulum bir sonraki açılışın başına denk geliyordu (34–47 ms kare) | Ön kurulum yerine yeniden kullanım; 8 hızlı aç/kapa döngüsünde hareket içinde 0 kare kaybı |
| Hızlı sekme geçişinde başlık titriyor (SwiftUI'de de) | Kompakt gövdede satır kayması sekmeye göre değişiyor, her geçişte bütün simge satırı birkaç punto sağa sola sıçrıyordu; yaylar yarıda yeniden hedefleniyordu | Kullanıcı isteğiyle bilinçli fark: satır kayması en dar gövdeye göre sabit (simgeler hiç yer değiştirmez); 350 ms içinde gelen geçişte kapsül, simge tonu ve panel animasyonsuz son hâline geçer. 80 ms geçişte uygulama CPU'su 15,7 → 12,2% (`logs/wsr.log`) |
| Tıklanan sekmede mavi odak halkası | Özel düğmeler "Klavyeyle gezinme" kapalıyken de odak alıyordu | `NSButton`/SwiftUI gibi yalnız klavyeyle gezinme açıkken |
| Ada kendi kendine kapanıp açılıyor | İmleç açık adanın alt kenarının 17–50 pt altına iniyordu | Açık adanın altında 40 pt hover payı (kullanıcı isteği; ana uygulamadan bilinçli fark) |
| Pencere sunucusu ek yükü | Core Image açılış bulanıklığı yarıçap 0'da takılı kalıyordu | Filtre yalnız bulanıklık sürerken takılı |
| Nook açılışı pahalı | Kısayollar her açılışta yeniden kuruluyor, büyük simgeler küçültülüyordu | Değişmedikçe yeniden kurulmaz; 28 pt simgeler önbellekte; tarih metinleri gün başına |

Tanı araçları (yalnız ortam değişkeniyle açılır, yoksa hiçbir şey yapmaz): `OPENISLAND_DENEY_FRAMELOG` (kare aralığı, tick süresi,
run-loop yükü, model değişimleri), `OPENISLAND_POINTER_LOG` (imleç giriş/çıkış ve faz değişimleri),
`OPENISLAND_DENEY_IMGPROBE=dosya` (görüntü görünümü yeniden çizimleri görünüm yolu başına; `OPENISLAND_DENEY_IMGPROBE_STACKS=N`
ile N çerçevelik çağrı yığınları), `OPENISLAND_DENEY_NOCLOCK` (karşılaştırma için sürücü başına ayrı ekran bağlantısı),
kıyas modu `OPENISLAND_BENCHMARK_V2=open-close` (`OPENISLAND_BENCHMARK_HOVER=1` ile hover yolu).

## Doğrulama

`tools/vis.sh UYGULAMA ETİKET` her iki uygulamayı yalıtılmış test verisiyle başlatır (Deney'in standart tercih
alanı SwiftUI uygulamasınınkinin kopyasıyla başlar), 8 sekmenin (Ayna kamera izni istediği için hariç) soğuk/sıcak
ekran görüntüsünü, AX ağacını ve AX çerçevelerini alır.
