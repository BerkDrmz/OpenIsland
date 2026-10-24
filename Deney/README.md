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
| Araçlar penceresi (Kaldırıcı, Önbellek temizleyici, Uygulama güncelleyici) | AppKit (`Deney/Sources/Tools/MaintenanceWindowView.swift`; denetleyici ortak, içerik `#if OPENISLAND_DENEY`). Ayrıntı: aşağıda "Araçlar penceresi" |
| Ayarlar penceresi (Genel, Modüller, Sistem Erişimi; ada önizlemesi dahil) | AppKit (`Deney/Sources/Settings`). Ayrıntı: aşağıda "Ayarlar penceresi" |

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

## Performans: SwiftUI ile A/B/B/A (2026-10-24, son sürüm: ada, paneller, Dock, Araçlar ve Ayarlar AppKit)

Ölçüm: uygulamanın kendi denetimli kıyası (`OPENISLAND_BENCHMARK_V2`), faz sınırında `proc_pid_rusage` (talimat,
çevrim, enerji tahmini, CPU, uyanma, ayak izi) ve WindowServer CPU'su; yalıtılmış test verisi, ölçüm sırasında başka
Deney örneği kapalı. Araçlar ve ham sonuçlar: `OpenIsland-Evidence/20261021-appkit` (`tools/final3.sh`,
`apps/AKZ.app`, `runs/*-hts*`, `runs/*-hic*`, `runs/*-hie*`, `wsoc/hoc-*`, `logs/final3.log`). Geçersiz koşu yok.

Sekme geçişi (her hızda 4'er koşu; Δ = AppKit − SwiftUI; parantezde mutlak uygulama CPU'su):

| Aralık | Talimat/seçim | Çevrim/seçim | CPU | Enerji/seçim | Ayak izi | Uyanma | WindowServer |
|---|---|---|---|---|---|---|---|
| 650 ms | −69% | −72% | −72% (10,4 → 2,9%) | −67% | −28% | 0% | −9% |
| 300 ms | −72% | −77% | −77% (18,9 → 4,3%) | −70% | −29% | −5% | −16% |
| 150 ms | −87% | −85% | −85% (27,2 → 4,2%) | −85% | −29% | −9% | −16% |
| 80 ms | −84% | −82% | −82% (35,9 → 6,4%) | −84% | −29% | −2% | −14% |
| 50 ms | −82% | −80% | −80% (46,2 → 9,3%) | −85% | −29% | −20% | −15% |

Enerji/saniye de her hızda −67…−85% (80 ms'de 121 → 19,8 mW). Önceki turdaki 50 ms'de WindowServer +%7 ve hızlı
geçişte uyanma +%2…11 artık yok: WindowServer her hızda −9…−16%, uyanma 0…−20%.

Hover aç/kapat (8 döngü, 4'er koşu): uygulama CPU süresi SwiftUI 590–620 ms → AppKit 250 ms (−59%), WindowServer
5820–6240 → 5690–5860 ms (−3%).

Boşta (1'er çift, 325 s): uygulamanın kendi CPU'su ikisinde de ≈0 (kompakt %0,05 → %0,04, açık %0,20 → %0,13),
uyanma kompakt 1,4 → 0,1/s, açık 4,9 → 0,45/s, ayak izi açıkta −17%. Bu turda boştaki WindowServer yorumlanamaz:
ölçüm boyunca `appstoreagent` %92–97 CPU'daydı, iki koşuda Chrome oluşturucusu da çalışıyordu. Boştaki
WindowServer yüzdesi bu yüke göre 4,5…25 arasında, koşu sırasından bağımsız oynadı. Sakin sistemdeki önceki turda
(`logs/idle2.log`) kompakt −%11, açık eşitti.

Araçlar ve Ayarlar pencereleri (süreç içi A/B/B/A; ayrıntı aşağıdaki bölümlerde): açılış −64% / −69%, bölüm ya da
sekme geçişi −65% / −23%, güncelleme taraması −38%, tercih güncellemesi −59%.

2026-10-23 turundaki CPU düşüşleri (her biri ayrı A/B ile kabul edildi; 80 ms'de uygulama CPU'su 35,1 → 19,7%, enerji/seçim
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
- Önceki turdaki 50 ms'de WindowServer +%7 ve hızlı geçişte uyanma +%2…11, son turda ölçülmüyor (−15% ve −20%).
- Boştaki WindowServer'ın sakin sistemde yeniden ölçülmesi gerekiyor (son turda arka plan yükü yüzünden yorumlanamadı).
- Pano ve Mikser sekme simgelerinin seçim rengi animasyonu her karede yeniden rasterleşir: SwiftUI de bu iki simgede
  renk animasyonu kullanır (üst üste binen alt yollar; `TabIconTintCheck`).
- Boşta kompakt +1,3 MiB: açılışta kare kaybını önleyen saklanan içerik; kaldırılırsa ilk açılış ~40 ms donar.

## Araçlar penceresi

Eşdeğerlik koşumu `OPENISLAND_DENEY_TOOLSPARITY=klasör` (`tools/toolsparity.sh ETİKET BÖLÜM`): aynı denetleyiciye bağlı
AppKit ve SwiftUI pencerelerini yan yana açar; ekran görüntüsü ve AX çerçeveleri alınır. Güncelleyicide ağ
kullanılmaz (paket kimliğinden türetilen deneme sürüm sonuçları). `tools/toolsflow.sh` AppKit penceresinde AX ile
satır seçimi, onay kutuları, "Tümünü seç", süzgeç ve "Tüm sonuçları göster" adımlarını yürütür; her adımda iki pencere
aynı durumu gösterir.

Sonuç (koyu ve açık görünüm, üç bölüm, taranmış listelerle): kenar çubuğu, başlık, düğmeler, onay kutuları, liste
satırları, ayırıcılar ve devre dışı satır renkleri piksel piksel aynı; AX çerçeveleri birebir (metinde ≤0,3 pt).
Kalan farklar:
- Glif kenarlarında alt piksel kenar yumuşatması (düğme başlıkları, >96 düzey fark yok, koyu görünümde).
- SwiftUI `List` henüz çizilmemiş satırları 24 pt sayar; kaydırma çubuğu düğmesi bu yüzden daha büyük görünür ve
  kaydırdıkça boyu değişir. AppKit gerçek satır yüksekliğini kullanır.

Ölçülen SwiftUI kuralları:
- `List` (`ListCoreScrollView`): kaydırma görünümü ve anahat zemini `controlBackgroundColor`, kaydırma çubukları
  otomatik gizlenir. Güncelleyici satırı 52 pt; seçim zemini liste koordinatlarında satırın 16 pt içinden, içerik
  zeminden 6 pt içeriden başlar. Ayırıcı metnin başından zeminin sağ kenarına uzanır.
- Bölümün sıkıştırılamayan içeriği pencereye sığmazsa ana sütun taşar ve ortalanır (güncelleyicide 8,5 pt taşma: her
  şey 4,25 pt yukarı).
- Düğme başlığının kökeni piksele yukarı yuvarlanır. Simgeli düğmede simge ile başlık arası NSButton'dakinden 3 pt
  geniştir.
- `Toggle(.checkbox)`: AX kutusu 14 pt kutu + 5 pt + kesirli metin genişliği. `.font(.caption)` yalnız başlığı küçültür.
  Devre dışıyken yalnız birincil renkli metin `tertiaryLabelColor` olur; ikincil ve renkli metinler aynı kalır.
- `.title3.bold()` yarı kalın (semibold) çizilir. Çok satırlı `Text` son satırda tek sözcük bırakmaz
  (`lineBreakStrategy .standard`).
- Kenar çubuğu `Label`: yükseklik piksele aşağı yuvarlanır (16,625 → 16,5). Metin yuvarlanmış yüksekliğin dibine
  oturur. `.headline` simgesi kalın çizilir ve metne göre 0,5 pt aşağıdadır.
- `NSTextField` (yuvarlak kenarlı) AX çerçevesini kenarlığın 1 pt dışında bildirir. SwiftUI alanın çerçevesini bildirir.

Performans (süreç içi A/B/B/A, `OPENISLAND_DENEY_TOOLSPARITY_BENCH=20`, aynı denetleyici, ölçülen sırada yalnız bir
görünüm bağlı; `toolsparity/bench10`):

| İşlem | SwiftUI | AppKit |
|---|---|---|
| Pencere içeriğini kur, yerleştir, çiz | 44,4–44,6 ms | 16,0–16,3 ms (−64%) |
| Bölüm değiştirme (ortalama) | 27,7–29,1 ms | 9,9–10,0 ms (−65%) |
| Güncelleme taraması (21 uygulama, uygulama başına durum değişir) | 182–187 ms | 113–116 ms (−38%) |

Bu ölçümle bulunan ve giderilen maliyetler:
- Bölüm görünümü her geçişte yeniden kuruluyordu ve SwiftUI'den pahalıydı (70 ms'ye karşı 57 ms). Artık kurulan
  bölümler saklanıyor, geçişte yalnız gizlenip gösteriliyor.
- Düğme `fittingSize` her yerleşimde yerleşim motorunu çalıştırıyordu. Artık ölçüler başlık/yazı tipi değişene kadar
  önbellekte.
- Liste her değişimde `reloadData` ile tüm satırları yeniden kuruyordu. Artık fark (ekle/sil) uygulanıyor.
- `ManagedApplication.id` (`url.path`) her çağrıda yeniden hesaplanıyor. Görünür/güncellenebilir uygulamalar güncelleme
  başına tek geçişte süzülüyor.

Ölçümün kendisinde bulunan hata: koşum ana kuyruktaki bir bloktan çalışınca AppKit görünümünün gözlem güncellemeleri
(`DispatchQueue.main.async`) iç içe döngüde çalışamıyordu ve AppKit sahte biçimde ucuz görünüyordu. Ölçüm artık
çalışma döngüsü zamanlayıcısından başlıyor ve her adımda görünen başlığı doğruluyor (60/60).

Kırpılan etiket: `TextLabel` (`.onSetNeedsDisplay`) yalnız boyutu değişince yeniden çizilmez. Kaydırma çubuğu
belirip satır daralınca kırpılmış metin eski genişlikteki hâliyle kalıyordu. Güncelleyici satırında genişlik
değişince yeniden çizilir. Aynı düzeltme paylaşılan `TextLabel.setFrameSize` içinde denendi ve reddedildi: adada
sekme geçişinde talimat/seçim değişmedi (+%0,1…2), ama uygulama CPU'su her hızda %2–5 arttı (`runs/*-tlbl*`).

## Ayarlar penceresi

Eşdeğerlik koşumu `OPENISLAND_DENEY_SETTINGSPARITY=klasör` (`tools/settingspair.sh ETİKET SEKME`): SwiftUI ve AppKit
pencerelerini sırayla **aynı konumda** açar (form zemini duvar kâğıdından ton alır, konuma bağlıdır), sekmeyi AX ile
seçer; ekran görüntüsü ve AX çerçeveleri alınır. `MODE=light|dark` görünümü, `HOVER="x y"` önizlemenin açık
durumunu, `DUMP=s` görünüm ağacı dökümünü (`tree.txt`: sınıf, çerçeve, katman rengi/köşe/kenarlık) açar.

Sonuç (koyu ve açık görünüm):
- **Modüller, Sistem Erişimi:** >8 düzey fark yok, AX ağacı birebir.
- **Genel:** bölümler ve satırlar aynı. Ada önizlemesi kompakt ve açık durumda yakın: açıkta >96 düzey fark yok,
  kompaktta 86 piksel (nabız çubuklarının kenar yumuşatması). AX'te metinler 0,1 pt farklı: SwiftUI metin AX'ini
  yuvarlanmamış önizleme yüksekliğinden (94,3) konumlar, kutuları yuvarlar (94,5).

Ölçülen SwiftUI kuralları (görünüm ağacından):
- Sekmeler gerçek `NSTabView` (−7, −10, 574 × 616); sekme grubunun AX çerçevesi barındırıcınınki.
- Gruplu form zemini pencere zemini malzemesinin kopyası: gri katman (sRGB 0,9647 / 0,1961) + `CAChameleonLayer`
  (%5 / %10). AppKit'te aynı sonuç `NSVisualEffectView(.windowBackground, .withinWindow, .active)` ile. Kendi kurulan
  bukalemun katmanı tonu sistemle aynı vermedi. Gri değeri genel gri uzayında verilince sRGB'de 0,2559'a kayıyor.
- Kutu: 6 pt sürekli köşe, dolgu siyah/beyaz α0,015, 0,5 pt kenarlık siyah α0,06 / beyaz α0,12. Ayırıcı 1 pt,
  siyah/beyaz α0,047, kutunun 10 pt içinden. Bölümler arası 30 pt, başlık (13 pt yarı kalın) + 10 pt, kutu + 10 pt
  açıklama. Açıklama kutunun sol kenarından sağdan 10 pt içeriye kayar ve sağa hizalıdır.
- İçerik tam genişlikte; eski tarz kaydırma çubuğu içeriğin üstünde (kırpma görünümü daralmaz).
- Anahtar: küçük `NSSwitch` 28 × 16, AX onay kutusu 26 × 15. Parçalı seçici içeriğin %55'i (eşit dilimler), satır
  40 pt. Menü seçicisi seçili öğenin genişliğinde.
- İzin satırı: düğme kutusu 22 pt (NSButton hizalaması 20), başlığın 1 pt üstünden; caption `Label`'da simge ile
  metin arası 12 pt; simge pencere piksel ızgarasına oturur. Satır AX'te tek öğe (düğme varsa düğme).
- Çok satırlı metnin AX genişliği kaydırılan satırın sonundaki boşluğu da kapsar.
- Önizleme: bütün canlanan değerler tek ilerleme yayıyla iki yerleşim arasında; yaprak katmanlar (kapak, nabız
  çubukları) ölçekten sonra pencere pikseline oturur (köken ve genişlik en yakın, yükseklik aşağı).

Performans (süreç içi A/B/B/A, `OPENISLAND_DENEY_SETTINGSPARITY_BENCH=20`, ölçülen sırada yalnız bir görünüm bağlı;
`settingsparity/sb2`):

| İşlem | SwiftUI | AppKit |
|---|---|---|
| Pencere içeriğini kur, yerleştir, çiz | 74,1–76,6 ms | 23,3–23,4 ms (−69%) |
| Sekme geçişi | 14,6–14,8 ms | 11,3 ms (−23%) |
| Tercih değişince güncelleme (Genel açıkken bir anahtar) | 9,4–9,6 ms | 3,8–3,9 ms (−59%) |

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
