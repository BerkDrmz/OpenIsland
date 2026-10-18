# OpenIsland K8 — Odak köprüsü çalkantısı, K7-P'nin gerçek kazancı ve CPU süresi (2026-10-18)

Dal: `local/k8-focus-churn-20261018` (worktree `OpenIsland-k8-dev`), başlangıç `08a3d53`. Deney ağaçları:
`OpenIsland-k7-exp` (tanı), `OpenIsland-k7d-exp` (K7-P + K8). Kurulu `/Applications/OpenIsland.app`, `main`, uzak depo,
v0.1.0 ve kullanıcı verileri değişmedi; push yok.

**Karar: K8 → NEEDS_FIXES.** Talimat −%12–16, enerji tahmini −%15–28, piksel/AX/klavye tabanla birebir aynı,
bütün testler PASS; ancak 80 ms hızlı geçişte Animation Hitches **+%11,6** (650 ms'de fark yok), "80/50 ms'de
kötüleşme yok" ölçütünü karşılamıyor (§7.1). **K7-P (K7D) → EXPERIMENTAL_ONLY** (ilk kare gecikmesini yarıya
indiriyor; AX sırası açık; 80/50 ms'de CPU süresi +%11–12).

## 1. Talimat azalması neden CPU süresine yansımıyor

`proc_pid_rusage` sayaçları (talimat, çevrim, P-çekirdek talimat/çevrim, P-çekirdek CPU süresi, enerji tahmini)
ölçülen değerlerdir; frekans = çevrim / CPU süresi ve IPC = talimat / çevrim bunlardan türetilir.

| Ölçü (80 ms, 480 seçim) | K7T öncesi taban | K7T | K8 öncesi taban | K8 |
|---|---|---|---|---|
| Ekran | kilitli | kilitli | açık/karışık | açık/karışık |
| Talimat/seçim | 200,6M | 150,8M (−%24,8) | 178,3M | 152,2M (−%14,6) |
| P-çekirdek talimat payı | %49 | %28 | %88 | %85 |
| P / E IPC | 2,68 / 1,45 | 2,81 / 1,34 | 2,46 / 0,99 | 2,27 / 0,96 |
| P / E etkin frekans | 4,21 / 2,56 GHz | 4,20 / 2,57 | 2,24 / 2,46 | 2,10 / 2,50 |
| CPU süresi/seçim | 36,3 ms | 35,2 (−%3) | 37,4 | 36,7 (−%1,9) |
| Enerji tahmini/seçim | 56,7 mJ | 30,3 (−%47) | 33,0 | 27,2 (−%17,6) |

İki ayrı mekanizma:

1. **Çekirdek türü (K7T):** iş P-çekirdekten E-çekirdeğe kaydı (P talimatı −%58, E +%7). E-çekirdek ≈ 3,7 G
   talimat/sn, P ≈ 11,3 G: aynı iş E'de ~3× sürer ama talimat başına ~5× az enerji harcar.
2. **Frekans (K8):** iş P'de kaldı, ama P-çekirdek frekansı 2,24 → 2,10 GHz'e indi. Kare temposundaki (80 ms) iş
   için sistem işi yetiştirecek kadar frekans veriyor; iş azalınca CPU süresi değil frekans/gerilim düşüyor.

Sınama (doygun, 20 ms aralık, frekans iki tarafta 4,1 GHz): K8 talimat −%12,1, çevrim −%8,5, **CPU süresi −%7,4**,
enerji −%11,8. Frekans sabitken CPU süresi işle orantılı düşüyor; 80 ms'de düşmemesi ölçüm yöntemi değil,
kare temposunda frekans yönetiminin sonucu. Sistem CPU (sys) payı seçim başına ~2–3 ms (80 ms) ve değişmedi;
"runnable" bekleme ≤ 2 ms. Termal durum ve diğer süreçlerin yükü A/B/B/A sırasıyla dengelendi; CPU yüzdesi farklı
yük koşulları arasında karşılaştırılmadı.

## 2. Kök neden: başlık kayması her karede bütün key-view döngüsünü yeniden kuruyordu

- Taban profilinde (80 ms) ana thread'in %11,4'ü `FocusBridge.preferencesDidChange → updateDefaultKeyViewLoop`;
  seçimden sonra 0–90 ms'nin her 10 ms'lik kovasında.
- Tanı sayacı (yalnız tanı derlemesi, KeyViewProxy `setFrameSize`): Nook'a geçişte vekil başına 16–18 güncelleme,
  konum ve boyut değişmeden; Notes'a geçişte sekme düğmesi vekili (14×24 pt = `tabButtonSize`) 488 → 485 pt kare
  kare kayıyor; Media ↔ System'de 1.
- K5 `headerRowShift` dar gövdelerde `.offset(x:)` ile yay boyunca canlanıyor; odaklanabilir sekme düğmeleri her
  karede yer değiştirdiği için SwiftUI bütün döngüyü ve bütün vekilleri (başlık + panel, ~31) yeniden kuruyor.
- Doğrulama: kayma kapalı tanı varyantında (NOSHIFT) her geçişte vekil başına 1 güncelleme.

## 3. K8 çözümü

```swift
header(...)
    .offset(x: headerPlacement.shift)
    .layoutWithoutAnimation()          // yerleşim (odak/AX/isabet) tek adımda
// TabButton ve IslandIconButton etiketlerinde:
    .restoringLayoutAnimation()        // görünen ikon, kapsül, ton ve pin özgün eğriyle kayar
```

`layoutWithoutAnimation` transaction animasyonunu bir `TransactionKey`'e saklar ve kapatır; `restoringLayoutAnimation`
yalnız o anahtar doluyken geri yükler. SwiftUI geometri animasyonunu geometrisi değişen görünümün kendi
transaction'ıyla yaptığı için etiketlerin görünen konumu kayarken düğmenin kendisi son konuma tek adımda geçer.
Anahtar yalnız başlık kayması transaction'ında dolu; diğer 9 `IslandIconButton` kullanımında etkisiz.

Denenen ve reddedilen yollar: `Animatable` + `.animation(nil){}` + `visualEffect` (churn sürdü),
dış nil + bütün içeriğe geri yükleme (içerik geometrisi canlandı, churn sürdü), `visualEffect` farkı (V2) ve
`GeometryEffect.ignoredByLayout()` farkı (V3) (churn yok ama ilk karede +3 pt sapma: p95 0,39–0,40).

### Animasyon eşdeğerliği (kare kare)

Tanı derlemesinde her ekran karesinde panelin katman ağacı 2× bitmap'e çizildi; başlık şeridinin (üst 44 pt) sütun
profili 650 ms aşamasındaki 54 geçişte 700 ms boyunca (~40 kare/geçiş) kaydedildi ve zamanca ara değerlenerek
karşılaştırıldı (normalleştirilmiş L1).

| Karşılaştırma | Kare | Medyan | p95 | En büyük | Son kare |
|---|---|---|---|---|---|
| Taban – taban (gürültü tabanı) | 2077 | 0 | 0,115 | 0,32 | 0 |
| **Taban – K8 (iki çift koşu)** | 2077–2088 | 0 | **0,103–0,109** | 0,29–0,42 | **0** |
| Taban – V2 (`visualEffect`) | 2079 | 0,0001 | 0,386 | 0,69 | 0 |
| Taban – pozitif kontrol (kapsül canlanmıyor) | 2096 | 0,0003 | 0,285 | 0,52 | 0 |

Ayrıca ikon küme merkezleri kare kare tabanla aynı (ör. Media→Shelf: 213,37 → 221,25 → 222,86 → 212,04 pt;
taban 213,37 → 220,98 → 223,18 → 212,04); pin düğmesi tabandaki gibi kayıyor (547,39 → 547,18 → 546,50 → 545,99).

## 4. Ölçümler (A/B/B/A, taban `08a3d53` = BASE)

### Hız matrisi (n=4/4)

| Aralık | Talimat/seçim | CPU süresi/seçim | Enerji tahmini/seçim | Uyanma/s | Bellek |
|---|---|---|---|---|---|
| 650 ms | 323,5M → 272,6M (−%15,7) | −%3,5 | −%30,6 | ±0 | ±0 |
| 300 ms | 292,7M → 237,5M (−%18,9) | −%4,8 | −%29,0 | −%1,2 | +%0,3 |
| 150 ms | 226,6M → 183,3M (−%19,2) | −%3,6 | −%28,4 | ±0 | −%0,3 |
| 80 ms | 178,5M → 151,5M (−%15,2) | −%3,2 | −%19,2 | −%3,9 | −%1,2 |
| 50 ms | 166,2M → 141,3M (−%15,0) | −%2,9 | −%19,0 | −%1,8 | −%0,7 |
| 80 ms, 480 seçim | 178,3M → 152,2M (−%14,6) | −%1,9 | −%17,6 | −%2,5 | −%0,8 |
| 20 ms doygun, 480 seçim (n=2/2) | 146,8M → 129,0M (−%12,1) | **−%7,4** | −%11,8 | +%3 | ±0 |
| Genişletilmiş boşta (n=2/2) | %0,002 CPU, 0,1 uyanma/s → eşdeğer | | | | 29,0 MiB |
| Kompakt boşta (n=2/2 + 2/2) | %0,001 CPU, 0 uyanma/s → eşdeğer | | | | 20,9 MiB |

WindowServer CPU'su A/B/B/A'da gürültü içinde (±%8); GPU süreç sayacı yok (NOT_TESTED).

### Yönlü sekme çiftleri (tanı derlemeleri, iki çift koşu)

| Çift | 650 ms talimat | 80 ms talimat |
|---|---|---|
| Notes → Nook | 435M → 315M (−%27,7) | 233M → 162M (−%30,6) |
| Nook → Notes | 381M → 264M (−%30,7) | 192M → 116M (−%39,9) |
| Notes → Clipboard | 454M → 373M (−%18,0) | 174M → 108M (−%37,8) |
| Clipboard → Notes | 381M → 304M (−%20,2) | 184M → 130M (−%29,5) |
| Shelf → Clipboard | 419M → 351M (−%16,1) | 186M → 149M (−%20,3) |
| Clipboard → Shelf | 259M → 196M (−%24,3) | 146M → 102M (−%30,3) |
| Notes → Media | 242M → 166M (−%31,3) | 154M → 98M (−%36,5) |
| Media → Notes | 322M → 231M (−%28,3) | 145M → 96M (−%33,8) |
| Media → Shelf | 149M → 114M (−%23,2) | 95M → 80M (−%16,4) |
| System ↔ Media, Nook → System | ±%1 | −%12 … +%9 (taban–taban gürültüsü %30) |

En pahalı çift tabanda Nook → System (650 ms 474M; System'in canlı örneklemesi dahil) ve Notes → Nook (435M).
Kayma olmayan geniş gövdeler arası geçişlerde değişiklik yok (beklenen).

**İlk kare gecikmesi** (seçimden ilk Core Animation commit'ine): K8 ilk kareye iş eklemiyor (ilk kare talimatı
çiftlerde ±%3), kısaltmıyor da. Bazı çiftlerde medyan 1–4 ms uzuyor; ilk kare sayaçları bunun nedenini gösteriyor:
aynı iş daha sık E-çekirdekte yürüyor (ör. Notes → Nook 80 ms: P çevrim payı %100 → %85, çevrim 37,6M → 45,2M).

## 5. K7-P ile K8 (K7D) — kalıcı panel host'ları

K7T sahnesi K8 üzerine, Notes düzeltmesiyle (`skeletonWidth`) uygulandı (`OpenIsland-k7d-exp`, `K7D.diff`).

| Aralık (K8 → K7D, n=2/2) | Talimat | Enerji tahmini | Uyanma/s | CPU süresi | Bellek |
|---|---|---|---|---|---|
| 650 ms | −%16,8 | −%36,7 | −%4,6 | −%3,2 | +3,6 MiB |
| 300 ms | −%16,7 | −%38,7 | −%5,5 | +%0,4 | +3,6 MiB |
| 150 ms | −%23,8 | −%54,6 | −%6,5 | +%3,2 | +4,1 MiB |
| 80 ms | −%33,1 | −%57,8 | −%26,5 | **+%11,2** | +2,4 MiB |
| 50 ms | −%39,2 | −%61,3 | −%17,9 | **+%12,3** | +1,8 MiB |
| 80 ms, 480 seçim | −%32,4 | −%56,8 | −%27,4 | **+%11,8** | +3,2 MiB |

İlk kare gecikmesi (medyan):

| Çift | K8 650 ms | K7D 650 ms | K8 80 ms | K7D 80 ms |
|---|---|---|---|---|
| Shelf → Clipboard | 42,0 | **17,8** | 30,1 | **10,2** |
| Notes → Nook | 44,6 | **22,4** | 20,7 | **8,7** |
| Nook → System | 44,1 | **21,2** | 15,9 | 14,0 |
| Clipboard → Notes | 34,9 | **20,5** | 12,9 | 12,0 |
| System → Media | 17,4 | **10,9** | 4,8 | 3,8 |

İlk kare talimatı %50–77 azalıyor; K7-P kullanıcının gördüğü tepki süresini gerçekten kısaltıyor. CPU süresinin
80/50 ms'de artması işin E-çekirdeğe kaymasından (§1); enerji tahmini yarıdan fazla düşüyor (süreç modeli; sistem
güç ölçümü `powermetrics` yönetici izni gerektirdiği için yapılmadı).

### K7-P regresyonlarının durumu

| Regresyon | Kök neden | Durum |
|---|---|---|
| Notes 3 pt | Taban iç ZStack çocuklarına kendi boyutunu önerir: genişlik = max(gövde, iskelet). Dar gövdede iskelet satırı (L + boşluk + T + 2·dolgu) gövdeden geniştir; içerik farkın yarısı kadar sola kayar. K7T gövde genişliğini kullanıyordu | **Çözüldü (K7D):** `skeletonWidth = 2·dolgu + max(gövde − 2·dolgu, L + boşluk + T)`. Gerçek SwiftUI yerleşimiyle 2.520 yapılandırmada (1×/2×, gövde 300–560 pt, 3 dolgu, 3 boşluk, 4 satır genişliği) birebir aynı. Piksel doğrulaması ekran açılınca |
| AX sırası (Pano/Notlar/Sistem) | Ayrı host'un en üst düzeyinde SwiftUI öğeleri konuma göre sıralıyor; tabandaki `.contain` kökü ağaç sırası veriyor. `.contain` eklemek ara grup yaratıyor (K7Y) | Açık. Seçenekler: yalnız tek sütunlu panellerde kalıcı host (K7Z kümesi), panel sütunlarında ağaç sırasını koruyan `accessibilitySortPriority` (doğrulanmadı) |
| Klavye (K7Z'de odak "OpenIsland" grubunda) | Düzenekte iç içe host'ta Tab/Shift-Tab zinciri düz yerleşimle aynı (TextField ve `.focusable`). K7Z bulgusunun AX raporlama yan etkisi (host `isAccessibilityElement = false`) olduğu hipotezi | Açık: gerçek uygulamada first-responder izi gerekiyor; "Klavyeyle gezinme" ve ekran kilidi açık olmalı |
| İç içe host'ta odak taraması | K7T'de odak payı %11,4 → %19,2 (`_recursiveSetDefaultKeyViewLoop`); cmux/bonsplit'teki mekanizmanın aynısı | K8 ile kök host'taki kare başı churn kalktı; host takma anındaki tarama sürüyor |
| Bayat ilk kare | CodexBar #2546: `rootView` değişimi bir kare geç commit | K7-P'de `rootView` yalnız girdi değişince atanıyor; kare doğrulaması CA opaklığı nedeniyle `render(in:)` ile yapılamıyor, ekran kaydı gerekiyor |

## 6. Araştırma ve tersine mühendislik

| Kaynak | Bulgu | Kanıt | OpenIsland'daki karşılığı |
|---|---|---|---|
| manaflow-ai/cmux #10315 (açık), #16393, #10311 | İç içe NSHostingView'da her mount key-view döngüsünü yeniden kuruyor; tarama her seviyede katlanıyor | PR/issue + örnek yığınlar | K7T'deki odak artışı |
| manaflow-ai/bonsplit #283 (merge `ad450a5bf`), #284 (merge), MIT | `acceptsFirstResponder` önbelleği ~%10; asıl çözüm host'ları kardeş yapmak, host'u bir kez kurup `rootView`'u değiştirmek (16 derinlikte 28 s → 0,00 s) | Merge edilmiş PR + ölçüm tablosu | K7-P'nin kalıcı host fikrini doğruluyor; iç içe yerine kardeş host görsel kırpma nedeniyle bizde uygulanamıyor |
| outof-place/claude-acc #154 (merge, lisans belirtilmemiş) | `updateDefaultKeyViewLoop` render'ın %24'ü; host bölme + uzun animasyonu kısaltma (52 → 16 ms/s) | Merge edilmiş PR | Aynı darboğaz; K8 animasyonu kısaltmadan çözdü |
| spokvulcan/tesseract #512 (merge, lisans yok) | macOS 27'de ilk yerleşimden sonra beliren odaklanabilir Button ile döngü | Merge edilmiş PR | Sistemimiz macOS 27; odak köprüsü maliyeti bu sürümde öne çıkıyor |
| jizhi0v0/macos27-beta-issues #29 (açık) | Apple NotificationCenter FocusBridge/KeyViewProxyCache'te %100 CPU | Issue | Sistem düzeyi davranış |
| steipete/CodexBar #2546 (merge, MIT) | `rootView` değişiminde bir kare bayat içerik; aynı CATransaction'da layout+display | Merge edilmiş PR | K7-P riski |
| Ebullioscopic/Atoll `ede16f930` (GPL-3.0) | Açılışta mount patlamasını bir kareye bölme, zaman çizelgelerini 30 fps | Commit farkı | İlk karede görsel fark yarattığı için uygulanmadı |
| TheBoredTeam/boring.notch (GPL-3.0) | Sekme görünümü her seçimde yeniden kuruluyor (önceki tur) | Kaynak | Taban ile aynı |
| NotchNook 1.6.5 | Ayrı `NSHostingView<ExpandedNoteView>` yalnız ayrı not penceresi için; ana görünüm tek `NotchView` kökü | Statik semboller (`nm` + `swift demangle`) | Kalıcı sekme host'u kanıtı yok |
| Alcove 1.7.7 | `NSHostingViewSuppressingSafeArea` var; ikili sembolsüz, kurulum yerleri Ghidra ile statik çözülemedi | Ghidra 12.1.4 (REA, arayüzsüz) | NOT_VERIFIED |

Araçlar: REA + Ghidra 12.1.4 (headless) kullanıldı; Binary Ninja Free kurulu ama REA sağlayıcısı değil
(arayüzsüz API'si yok); Hopper lisans penceresi nedeniyle kullanılmadı; IDA kurulu değil. LLDB: tanı kopyası
`get-task-allow` ile imzalandı ama Developer Mode kapalı olduğundan bağlanmak yönetici onayı isterdi, denenmedi.
Time Profiler (12–36 s, disk korumalı), `proc_pid_rusage`, `nm`/`swift demangle` kullanıldı. Rakip kodu kopyalanmadı;
lisanssız/GPL kaynaklardan yalnız mekanizma öğrenildi.

## 7. Testler ve doğrulama

| Kapsam | Sonuç |
|---|---|
| `swift test` | 179 test / 28 suite PASS |
| `check-*.sh` (7) | 6 PASS; `check-controls` ekran kilitliyken tabanda da aynı ön koşulda duruyor (gerçek pencere + HID tıklama) → ekran açıkken tekrar |
| K5Checks | PASS (180 yapılandırma, 2.254 ara kare, 0 uyuşmazlık) |
| K4 TabIconTintCheck | PASS (≤1/255) |
| Başlık animasyonu kare eşdeğerliği | PASS (gürültü tabanı içinde, §3) |
| KeyViewProxy churn | Bütün çiftlerde vekil başına 1 |
| Pencere düzeyi ekran görüntüsü (6 sekme × soğuk/dönüş, BASE/K8) | PASS: 10/12 0 piksel; Sistem'deki 2 fark yalnız canlı CPU/bellek değerleri (satır ≥ 121, başlık bölgesi aynı) |
| AX ağacı (rol, etiket, yardım, seçili, sıra; 12 döküm) | PASS: 12/12 birebir aynı |
| Klavye, tam klavye erişimi açık (⌃⌥⌘J ile açılış, 5 sekme × 14 Tab + 14 Shift-Tab) | PASS: 145 adımın tamamı tabanla aynı |
| Klavye, tam klavye erişimi kapalı (Tab ile metin alanına giriş) | İlk K8'de **FAIL** (Nook alanı ve Notes düzenleyiciye girilemiyordu) → `2a8d5cf` ile PASS (§7.2) |
| `check-controls` (ekran açık) | PASS (taban ve K8; boşta %0,028–0,029) |
| Animation Hitches (ekran açık) | 650 ms eşdeğer; **80 ms +%11,6** (§7.1) |
| Spotify/Music | K8 medya koduna dokunmuyor; K6 sonuçları geçerli |

### 7.1 Animation Hitches (ekran açık, 10 s kayıt, A/B/B/A)

| Karşılaştırma (80 ms) | Hitch sayısı | Ortalama | Hitch süresi toplamı | Kare/s |
|---|---|---|---|---|
| BASE / K8 (n=4/4) | 60, 51, 54, 59 / 70, 54, 61, 65 | 56,0 / 62,5 (**+%11,6**) | 946 / 1125 ms | 57,2 / 56,4 |
| K8 / K8b (n=4/4) | 66, 73, 71, 68 / 64, 73, 69, 64 | 69,5 / 67,5 | 1238 / 1217 ms | 56,5 / 56,3 |
| BASE / K8b, 650 ms (n=2/2) | 14, 11 / 13, 13 | 12,5 / 13,0 | 408 / 383 ms | 50,7 / 50,8 |

Aralıklar örtüşüyor, ama K8 dört eşleşmenin dördünde de tabanın üstünde. Key-view düzeltmesi hitch'e etki etmiyor.
İlk kare sayaçlarıyla tutarlı açıklama: toplam iş azalınca seçim anındaki kurulum patlaması daha sık düşük frekansta
veya E-çekirdekte yürüyor ve bazen kare süresini kaçırıyor (hitch en çok 33,3 ms = 2 kare). Uygulama düzeyinde
çekirdek seçimi zorlanamaz; yol, patlamanın kendisini küçültmek (K7-P ilk kare talimatını %50–77 azaltıyor).

### 7.2 Klavye regresyonu ve düzeltmesi

İlk K8'de tam klavye erişimi kapalıyken (varsayılan) Tab, Nook'taki metin alanına ve Notes düzenleyicisine
giremiyordu. Tanı derlemesindeki key-view zinciri dökümü: K8'de zincir bu panellerin platform görünümleri
(`AppKitTextField`, `PlatformTextView`) olmadan kuruluyor. SwiftUI döngüyü seçim karesinde, yeni panelin platform
görünümleri pencereye takılmadan önce kuruyor; tabanda başlık kayması döngüyü her yay karesinde yeniden kurduğu için
bu görünümler tesadüfen sonradan zincire giriyordu (kaymanın değişmediği geçişlerde aynı açık tabanda da olabilir).
Düzeltme (`2a8d5cf`): sekme değişiminde bir sonraki run-loop turunda bir kez `recalculateKeyViewLoop()` (AppKit'in
belgelenmiş yolu; SwiftUI odak köprüsünü `_recursiveSetDefaultKeyViewLoop` ile günceller; odak taşımaz, girdi
yönlendirmez; hızlı geçişte birleşir). Maliyet K8'e göre talimat +%0,7…+%4, CPU süresi ±%1, hitch değişmedi.

| Aralık | K8 → K8b talimat | CPU süresi | Enerji tahmini |
|---|---|---|---|
| 650 ms | +%0,65 | +%1,1 | −%2,5 |
| 150 ms | +%3,4 | +%0,5 | +%5,7 |
| 80 ms | +%3,2 | −%0,4 | +%4,9 |
| 50 ms | +%4,0 | −%2,2 | +%7,4 |
| 80 ms, 480 seçim | +%3,2 | −%0,3 | +%3,8 |

Olay: AX ağacı aracı kilitli ekranda döngülü bir ağaçta sonsuz çıktı üretti (15 dosya × 2,7 GB, yalnız kendi kanıt
klasörümde). Süreçler durduruldu, dosyalar silindi; araca derinlik/öğe sınırı ve döngü denetimi, betiğe 5 MB çıktı
sınırı eklendi.

## 8. Commit'ler ve geri alma

| Commit | İçerik |
|---|---|
| `60c1f27` | K8: başlık kaymasının yerleşimi tek adımda, etiketleri canlı (`Components.swift`, `ExpandedIslandView.swift`) |
| `de7b322` | Rapor (ilk sürüm) |
| `2a8d5cf` | K8: sekme değişiminden sonra key-view döngüsünü bir kez yeniden kur (`IslandViewModel.swift`, `NotchWindowController.swift`) |
| (bu güncelleme) | Rapor: canlı doğrulama, hitch, klavye |

Geri alma: `git revert 2a8d5cf 60c1f27` (dört dosya, 51 satır); `2a8d5cf` tek başına geri alınmamalı. K7D yalnız `OpenIsland-k7d-exp` deney ağacında ve
`apps/K7D.diff` olarak duruyor; commit'lenmedi.

## 9. Kalan riskler ve sonraki adım

1. 80 ms hitch artışı (+%11,6): ürüne alınmadan önce giderilmeli. Aday yollar: seçim anındaki kurulum patlamasını
   küçültmek (K7-P'nin kalıcı host'ları ya da panel bazında mount maliyeti), ölçümü daha uzun kayıtlarla tekrarlamak.
2. K8 transient: canlanma süresince (≤ 0,5 s) düğmenin isabet/AX çerçevesi son konumda, görünen etiket ≤ 3 pt
   geride. Durağan halde birebir aynı.
3. İkinci aşama hedefi: panel kurulumu (ilk 30 ms; AttributeGraph %30, CA commit %18, metin %12,6, platform
   görünümleri %12,4). K7-P bunu yarıya indiriyor; ürüne alınması için AX sırası ve klavye zinciri çözülmeli.
