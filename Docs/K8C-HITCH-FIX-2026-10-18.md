# OpenIsland K8c — 80 ms Animation Hitches regresyonunun giderilmesi (2026-10-18)

Dal: `local/k8-focus-churn-20261018` (worktree `OpenIsland-k8-dev`), başlangıç `0ceace3` (K8b). Deney ağacı:
`OpenIsland-k7d-exp` (detached; önceki K7D farkı `apps/K7D.diff` ve `h9/K7D-tree-before-h9.diff` olarak saklı, ağaç
şimdi K8c durumunda). Kanıt: `OpenIsland-Evidence/20261017-k7` (`h9/`, `prof/*-h9*`, `runs/*-h9*`, `vis/*-h9*`,
`kb/*-h9*`). `/Applications/OpenIsland.app`, `main`, uzak depo, v0.1.0 ve kullanıcı verileri değişmedi; push yok.

**Karar: K8c → READY_FOR_REVIEW.** 80 ms'de hitch tabana göre **−%91** (57,3 → 5,0), K8b'ye göre −%95; talimat ve
süreç enerji tahmini K8'den de düşük. AX (12/12), klavye (tam klavye erişimi kapalı ve açık, 145/145), `swift test` ve
`check-*.sh` PASS (`check-controls` için §7 notu). Kalan ödünleşimler §5–6.

## 1. Hipotezin sınanması: hitch nerede ve neden

Araç: Animation Hitches kaydına sekme seçimi signpost'ları eklendi (`tools/hitchsp.sh`: `--instrument "Points of
Interest"`); her hitch seçim penceresine bağlandı (`hitchdrill.py`), seçim → ilk uygulama güncellemesi ön fazı ayrıca
çözümlendi (`prephase.py`, `prediff.py`). Kayıtlarda zaman profili, çekirdek türü ve thread durumu da var.

Regresyon yeniden üretildi: BASE 55, 56, 63, 57 / K8b 65, 63, 66, 66 hitch (+%12,6; 4/4 eşleşme).

| Geçiş (80 ms, n≈80) | BASE hitch/seçim | K8b | BASE ön faz (ms) | K8b ön faz | BASE P payı | K8b P payı |
|---|---|---|---|---|---|---|
| Medya → Raf | 0,16 | 0,35 | 9,1 | 9,1 | %2 | %3 |
| Nook → Sistem | 0,62 | 0,71 | 13,8 | 16,7 | %98 | %99 |
| Notlar → Nook | 0,79 | 0,80 | 16,8 | 18,1 | %96 | %86 |
| Raf → Pano | 0,94 | 0,94 | 25,3 | 28,6 | %49 | %36 |
| Pano → Notlar | 0,25 | 0,28 | 13,1 | 16,2 | %80 | %87 |

Ön faz koşudan koşuya tutarlı (Raf → Pano BASE 24,4–25,6 ms, K8b 28,5–29,4 ms). Üç bileşen:

1. **K8b'nin key-view yeniden hesaplaması ilk kareden önce koşuyor:** `DispatchQueue.main.async` bloğu aynı ana kuyruk
   boşaltmasında, yeni panelin ilk commit'inden önce çalışıyor (Raf'ta seçim başına 1,26 ms, çoğu E-çekirdekte).
2. **Aynı iş daha yavaş:** Pano/Nook'ta panel yerleşimi semboller düzeyinde birebir aynı, ama her kalemde ~%13 daha uzun;
   P-çekirdek payı düşüyor (Raf → Pano %49 → %36). Verilen hipotez doğru: toplam iş azalınca ana thread daha sık
   E-çekirdekte/düşük frekansta.
3. **İlk karede başlık işi:** Sistem'de commit/görüntü döngüsü +2,5 ms (`NSWindow layoutIfNeeded`, `NSHostingView.layout →
   render`); K8'de düğmelerin yerleşimi ilk karede tek adımda değişiyor.

**İşi azaltmak tek başına yetmiyor (H1/H3 deneyi):** Pano satır önizlemesinde CoreText 8–14 KB'lık dizgilerin tamamını
şekillendiriyordu (ilk karede seçim başına ~12 ms). Önek ile Raf → Pano ön fazı 28,5 → 20,9 ms'ye indi, ama zamanlayıcı
ana thread'i E-çekirdeğe kaydırdı (P payı %33–44 → %7–11; ardından gelen Notlar %77 → %40) ve toplam hitch değişmedi
(BASE 56,0 / H3 67,8; K8b 66,0 / H3 63,3). Ayrıca 10.240 karakterden uzun dizgiler SwiftUI/CoreText'te farklı yoldan
çiziliyor; önek bunlarda alt piksel kenar farkı (≤128/255, 6× büyütmede görünmez) üretiyor. **Reddedildi**, yalnız deney
ağacında kaldı (`h9/H4-clip-lazy.diff`, piksel aracı `ClipPreviewCheck` dahil).

Sonuç: ilk kare işi, E-çekirdekte bile tek kareye sığacak kadar küçülmeli. K7-P (kalıcı host) bunu yapıyor:
BASE 56, 62, 54, 48 / **K7D 5, 6, 3, 7** hitch (−%90). K7-P'nin önceki engelleri AX sırası ve klavyeydi (§3).

## 2. K8c çözümü (`df99809`)

| Parça | Ne | Neden |
|---|---|---|
| `PanelStage` (K7-P, K7D'den) | Her sekme kalıcı `NSHostingView`'da; gizlenen host pencereden çıkar (`onAppear/onDisappear` özgün anlarda), saydamlık aynı süre/eğriyle CA'da; `skeletonWidth` ile Notlar 3 pt düzeltmesi | İlk kare kurulum patlaması kalkar |
| Ağaçtaki yer | Sahne başlıktan sonra, HUD'dan önce | AX sırası başlık → panel → HUD (tabanla aynı) |
| `PanelHostingView` | `isAccessibilityElement = false`, `acceptsFirstMouse = true`, safe-area sıfır | Ara grup yok; kök host'la aynı tıklama/safe-area davranışı |
| `PanelAXOrder` | Sütunlara azalan `accessibilitySortPriority` (Pano, Notlar, Nook medya, Sistem) | Ayrı host en üst düzeyi konuma göre sıralıyor; öncelik ağaç sırasını geri getiriyor |
| Tembel key-view döngüsü | Sekme değişiminde yalnız "bayat" işareti; Tab/Shift-Tab pencereye ulaşmadan ve panel key olmadan hemen önce bir kez `recalculateKeyViewLoop()` | Yeniden hesaplama artık ilk kareyi geciktirmiyor; hızlı geçişte hiç koşmuyor |
| Tab sırası (§3) | Kök host halkaya önce platform görünümlerini (panel sahnesi), sonra başlık vekillerini koyuyor; sahne bölümü Tab'dan hemen önce halkanın sonuna taşınır (`nextKeyView`) | Tabandaki sıra: başlık → panel |
| AX odağı (§3) | İlk yanıtlayıcı panel host'unun SwiftUI odak vekiliyse `NotchPanel.accessibilityFocusedUIElement` host'un odaklı öğesini döndürür | AX'te görünmeyen host yüzünden odak kök kapsayıcıya düşüyordu |

Denenen AX yolları: kök `.contain` (fazladan grup), `.contain` + host'ta çocukları düzleştirme (ağaç aynı, ama
öğelerin `AXParent`'ı görünmeyen kapsayıcı: tabanda 0, burada 3–17 uyuşmazlık → VoiceOver riski, reddedildi), yalnız
host'u gizleme (Medya/Raf aynı, sütunlu panellerde sıra farklı). Seçilen yol: gizleme + sütun öncelikleri.

## 3. Eşdeğerlik

| Kontrol | Sonuç |
|---|---|
| AX ağacı (rol, etiket, yardım, seçili, sıra; 6 sekme × soğuk/dönüş) | **12/12 birebir aynı** |
| AX ebeveyn zinciri ve isabet testi (`harness10/axparent`) | 6 sekmede tabanla aynı (0 uyuşmazlık; Pano'daki 2 isabet dışı satır tabanda da aynı) |
| Klavye, tam klavye erişimi kapalı (⌃⌥⌘J, 5 sekme × 14 Tab + 14 Shift-Tab) | PASS: 145 adım beklenen referansla (önceki FBc-kl) aynı; Nook alanına ve Notlar düzenleyicisine Tab ile giriliyor. Not: bu turda tanı tabanı FBc iki panelde metin alanına giremedi (K8 raporu §7.2'deki zamanlama açığı tabanda da var) |
| Klavye, tam klavye erişimi açık (kullanıcı ayarı açtı; `fka=true`) | İlk K8c'de **FAIL**: (1) ilk Tab başlık yerine panele gidiyordu (halka aynı, giriş noktası farklı); (2) panelin üst düzey öğeleri odaktayken AX odaklı öğe `AXGroup|OpenIsland` bildiriyordu (öğenin `AXFocused`'ı doğruyken; K7Z'deki belirti). Düzeltmeden sonra **3 turun 3'ünde FBc ve K8c 145/145 adım referansla (`kb/FBc-fka`) birebir aynı**: başlık, Medya, Nook medya/takvim/anımsatıcılar, Notlar menüsü ve düzenleyici, Pano renkleri. Denenen ve reddedilen: host'un AX alt ağacında `AXFocused` araması (SwiftUI `AccessibilityNode` Swift'te `NSAccessibilityProtocol`'e dönüşmüyor; yeniden girişte özyineleme çökmesi), her durumda host'un odaklı öğesini döndürmek (açılır düğmede etiketsiz ham görünüm) |
| Pencere görüntüsü (6 sekme × soğuk/dönüş) | Medya/Raf/Pano/Nook **0 piksel**; Sistem yalnız canlı CPU/bellek çubukları (taban–taban koşularında da aynı bölge); **Notlar 122 piksel, ≤3/255** başlatıcı simgelerinin içinde dağınık (kayma değil, gözle görülmez). Elenen nedenler: sekme sırası, `scaleEffect`, `compositingGroup`, `wantsLayer`; kök neden belirlenmedi |
| Başlık animasyonu | Değişmedi (K8 kare eşdeğerliği geçerli); K5Checks PASS (2.216 ara kare, 0 uyuşmazlık), TabIconTint ≤1/255 |
| Panel geçişi | `PanelStageCheck` (gerçek pencere) PASS: ilk gösterim opak ve son dikdörtgende, eski host donuk söner ve çıkar, yeniden kullanımda `onAppear`, sönme sırasında dönüş, isabet testi, söküm, yeniden açılış taze. Saydamlık eğrisi/süresi SwiftUI geçişiyle aynı (easeOut 0,12/0,15/0,10 s, easeIn 0,08/0,10/0,06 s) |

Bilinen anlamsal farklar (K7-P'den, değişmedi): sönmekte olan panele süre dolmadan geri dönülürse tabanda yeni kopya
belirirken eski kopya söner, K8c'de aynı host'un saydamlığı geri döner (≤ 0,1 s, yalnız çok hızlı geri dönüşte); panel
içi `@State` (kaydırma, hover) aynı açık oturumda korunur, ada kapanınca sıfırlanır.

## 4. Ölçümler (A/B/B/A, ekran açık)

### Animation Hitches (80 ms, 10 s kayıt, iki çift)

| Karşılaştırma | Hitch sayısı | Ortalama | Hitch süresi toplamı (ortalama) | Kare/s |
|---|---|---|---|---|
| BASE / K8c | 57, 68, 49, 55 / 5, 3, 9, 3 | 57,3 / **5,0 (−%91)** | 967 / 83 ms | 57,5 / 58,3 |
| K8b / K8c | 64, 63, 59, 61 / 4, 2, 4, 2 | 61,8 / **3,0 (−%95)** | 1.125 / 50 ms | 56,6 / 58,1 |
| BASE / K7D (referans) | 56, 62, 54, 48 / 5, 6, 3, 7 | 55,0 / 5,3 | | |

Geçiş başına (BASE → K8c, hitch/seçim): Raf → Pano 0,85 → 0,09; Notlar → Nook 0,70 → 0,06; Nook → Sistem 0,52 → 0,01;
Pano → Notlar 0,32 → 0,05; Medya → Raf 0,23 → 0,01; Sistem → Medya 0 → 0.

### İlk kare gecikmesi (seçim → ilk uygulama güncellemesinin sonu, medyan ön faz + medyan güncelleme, ms, 80 ms)

| Geçiş | BASE | K8b | K8c |
|---|---|---|---|
| Raf → Pano | 34,1 | 37,1 | **19,7** |
| Notlar → Nook | 32,6 | 34,0 | **17,8** |
| Nook → Sistem | 26,1 | 28,1 | **15,6** |
| Pano → Notlar | 25,7 | 33,9 | **19,9** |
| Medya → Raf | 15,9 | 13,4 | 14,4–15,4 |
| Sistem → Medya | 11,0 | 11,3 | 8,7–9,8 |

### Hız matrisi (tab-speeds, n=4/4) ve 480 seçim

| Aralık | Talimat/seçim BASE → K8c | K8b → K8c | Enerji tahmini BASE → K8c | K8b → K8c | CPU süresi BASE → K8c | Bellek |
|---|---|---|---|---|---|---|
| 650 ms | 321,4M → 217,2M (−%32,4) | −%21,1 | −%54,5 | −%41,9 | −%7,7 | +4,4 MiB |
| 300 ms | 291,3M → 191,4M (−%34,3) | −%21,1 | −%57,7 | −%47,1 | −%7,0 | +4,5 MiB |
| 150 ms | 226,9M → 131,8M (−%41,9) | −%29,6 | −%69,1 | −%58,9 | −%1,6 | +4,5 MiB |
| 80 ms | 177,7M → 97,7M (−%45,0) | −%37,4 | −%65,5 | −%60,8 | **+%9,5** | +2,8 MiB |
| 50 ms | 166,9M → 83,4M (−%50,0) | −%43,5 | −%69,3 | −%64,8 | **+%9,6** | +1,8 MiB |
| 80 ms, 480 seçim | 178,7M → 99,4M (−%44,4) | −%36,4 | −%64,5 | −%56,1 | +%7,6 | +3,7 MiB |

Uyanma/s 80 ms'de −%27. CPU süresinin 80/50 ms'de artması işin E-çekirdeğe kaymasından (frekans BASE 2,19 → K8c
1,90 GHz; §1 ve K8 raporu §1); enerji tahmini yarıdan fazla düşüyor. Enerji değerleri `proc_pid_rusage` süreç
tahminidir; sistem gücü (`powermetrics`) yönetici izni gerektirdiği için ölçülmedi.

## 5. WindowServer

tab-speeds kipinde WindowServer CPU'su K8c'de tutarlı olarak yüksek: 80 ms'de BASE 31,3–31,5 / K8c 37,0–37,5 (+5,8
puan); 150 ms +4,2; 300 ms +2,8; 650 ms +0,4 (gürültü içinde). profile-rapid kipinde (41 s sürekli 80 ms) fark +0–2
puan ve koşudan koşuya tutarsız; WindowServer ölçümü ekran/sistem durumuna göre iki düzey arasında dolaşıyor (≈16 ve
≈31–44), karşılaştırmalar aynı düzeyin içinde yapıldı.

Teşhis (tanı derlemesi `HX`, tab-speeds, 80 ms, iki koşu): BASE 30,4/31,8 · K8c 36,0/35,4 · solmasız 34,6/35,5 ·
host'ları pencerede tutan 32,7/31,5. Ek yük solmadan veya grup opaklığından değil, gizlenen host'ların pencereden çıkarılıp
yeniden eklenmesinden (katman ağacının render sunucusuna yeniden aktarılması). Host'ları pencerede tutmak WindowServer'ı
taban düzeyine indiriyor, ama `onAppear/onDisappear` anlamını bozuyor (Sistem örneklemesi, kamera vb.) ve uygulama işini
artırıyor (650 ms'de CPU süresi +%16; K7V'de talimat +%31); eşdeğer olmadığı için uygulanmadı.

## 6. Kalan riskler

1. Tab sırası düzeltmesi SwiftUI'nin kurduğu `nextKeyView` bağlarını yeniden düzenler (public API); SwiftUI halkayı yeniden
   kurarsa bir sonraki Tab'da yeniden uygulanır. Tam klavye erişimi kapalıyken son derlemeyle klavye testi tekrar edilmedi
   (bu turda ayar açıktı); önceki K8c derlemesinde PASS.
2. WindowServer CPU'su hızlı geçişte +3–6 puan (§5); normal hızda (650 ms) fark yok. Sistem düzeyi net enerji etkisi
   yönetici izni olmadan ölçülemedi.
3. Notlar başlatıcı simgelerinde 122 piksel ≤3/255 fark (kök neden bulunamadı; gözle görülmez).
4. Bellek +2–4,5 MiB (açık oturum boyunca ziyaret edilen panellerin host'ları; ada kapanınca bırakılıyor).
5. VoiceOver ile canlı sesli gezinme ve sürükle-bırak canlı denemesi yapılmadı. Bırakma hedefi yalnız kök host'ta
   (`.onDrop`); iç içe host kendi hedefi olmadığından AppKit sürüklemeyi üst görünüme iletir (kod incelemesi).

## 7. Testler

| Kapsam | Sonuç |
|---|---|
| `swift test` | 179 test / 28 suite PASS |
| `check-*.sh` (7; `check-controls` ekran açık, gerçek pencere + HID) | 7/7 PASS (`df99809`, tam klavye erişimi kapalıyken; `PanelStageCheck` dahil). Son durumda 6/6 PASS; `check-controls` tam klavye erişimi **açıkken** hem K8c'de hem tabanda (`08a3d53`) aynı yerde duruyor (test uygulamasının kırmızı kapatma düğmesine HID tıklaması); derlediği kaynaklar K8c'de değişmedi → ortam kaynaklı, ayar kapatılınca tekrar edilmeli |
| K5Checks, TabIconTintCheck | PASS |
| AX, piksel, klavye | §3 |

## 8. Commit'ler ve geri alma

| Commit | İçerik |
|---|---|
| `df99809` | K8c: kalıcı panel host'ları, ağaç sıralı erişilebilirlik, tembel key-view döngüsü (10 dosya) |
| `3774a40` | Bu rapor (ilk sürüm) |
| `9424041` | Tam klavye erişimi: Tab sırası ve AX odağı düzeltmesi, `check-performance` derleme satırı |
| (bu commit) | Rapor güncellemesi |

Geri alma: `git revert 9424041 df99809` (K8b'ye döner; `9424041` tek başına geri alınabilir, `df99809` tek başına alınmamalı). Reddedilen deneyler yalnız kanıt klasöründe: `h9/H4-clip-lazy.diff`
(Pano önizleme öneki + `ClipPreviewCheck`), tanı derlemeleri `HX`, `HNS`/`BNS`, `H7b`.
