# OpenIsland — Hızlı sekme render darboğazı ve sekme ikonu optimizasyonu

**Tarih:** 15 Ekim 2026 · **Dal:** `local/render-cpu-20261014` · **Worktree:** `/Volumes/HIKSEMI/proje/OpenIsland-cpu-dev` · **Temel:** `d893acd`

**Karar:** Bir gerçek optimizasyon kabul edildi (sekme ikonu tonunun renk yerine opaklıkla canlanması). Davranış korunarak ölçülebilir, tekrarlanabilir kazanç sağladı. 80 ms'de %25 altı hedefine **ulaşılamadı**. Kurulu uygulama, production main ve GitHub değiştirilmedi. Production'a alınmadan önce aşağıdaki NOT_TESTED maddeleri kapatılmalı.

## 1. Ölçüm yöntemi

- Uygulamanın kendi kontrollü benchmark'ı kullanıldı: `profile-rapid` (6 sekme, 80 ms aralık, 480 seçim) ve `tab-speeds` (650/300/150/80/50 ms, her hızda 54 seçim). Fixture, defaults suite ve support kopyası önceki turlarla aynı. Release derlemeler, A/B/B/A sırası.
- **Asıl ölçüt: seçim başına süreç talimat sayısı** (`proc_pid_rusage` `ri_instructions`). Faz sınırlarında örneklendi (`tools/rusage-probe.c`). Makine ölçüm sırasında saat/güç modu değiştiriyor (2,1 ↔ 3,9 GHz). Bu yüzden CPU % ve ms/seçim aynı binary'de ±%20 oynuyor. Talimat sayısı ise aynı binary'de ±%0,5 içinde kalıyor.
- Ek olarak: CPU %, ms/seçim, `ri_energy_nj` (süreç enerji tahmini), wakeups, footprint, WindowServer CPU (`ps` TIME farkı).
- Enerji tahmini frekans moduna bağlı. Yalnızca aynı moddaki çiftler karşılaştırıldığında anlamlı. Watt veya pil yüzdesine çevrilmedi.

## 2. Kanıtlanmış ana thread darboğazı

- Örneklerin ~%97'si ana thread'de. 80 ms'de seçim başına iş: seçimden sonraki ilk 30 ms ≈ %64 (panel kurulumu, ilk layout, metin ölçümü, CPU'da çizilen katmanlar, CA commit). Kalanı animasyon kareleri.
- Ablasyon (gece oturumu, `ABL1*`): panel içeriğini boşaltmak CPU'yu değiştirmedi. **Başlık satırını (9 TabButton + Pin) kaldırmak** ise 36 → 14 ms/seçim indirdi. Darboğaz başlıkta.
- Başlık sabit tutulduğunda bile kalan iş (bu oturum, tanı yapıları):
  - İkon renk animasyonu: SwiftUI her yay karesinde dinamik `NSColor`'ı (`IslandPalette.tertiary`) yeniden çözüp ikonu CPU'da yeniden rasterize ediyor. `ShapeStyleResolver` A'da ana thread'in %5,6'sı. Statik renkle seçim başına ≈ −4,4 ms.
  - Seçim kapsülü (ekle/çıkar + matchedGeometry + opaklık geçişi): ≈ −3,7 ms (yalnızca tanı).
  - Dar gövdeli sekmelerde (W < 373 pt) başlık konumları gövde genişliğine bağlı ve gerçekten kayıyor. Her kare odak anahtar döngüsü (`FocusBridge.invalidateKeyViewLoop`, %8,6–10,8), responder ve display list güncellemesi doğuruyor. Bu görünür bir hareket, davranış değişmeden kaldırılamadı.
- `.compositingGroup()` kaldırıldığında (tanı) iş +%8, WindowServer +4 puan arttı. Yerinde kalmalı.

## 3. Değiştirilen kod yolları (commit'ler)

| Commit | İçerik |
|---|---|
| `7c7ab66` | Yalnızca geliştirici benchmark'ı: `OPENISLAND_BENCHMARK_TABS` ile sekme sırası (Focus dahil 7 sekme). Değişken yoksa özgün 6 sekme. |
| `753e316` | `TabButton`: ikon her zaman beyaz. Seçili olmayanın alfası (`tertiary` ile aynı 0,48 / Kontrastı Artır'da 0,7) **katman opaklığı** olarak, aynı transaction ve aynı yayla canlanıyor. Alfa palet ile aynı kaynaktan okunuyor, `colorSchemeContrast` değişince yenileniyor. |
| `abbd5fa` | Mixer sembolü özgün renk animasyonunda bırakıldı. Üst üste binen alt yollar renk alfasında farklı birleşiyor (16/255). `Tools/PerformanceChecks/TabIconTintCheck.swift` eklendi. |
| `4fc407c` | Pano sembolü de özgün renk yolunda (tekrarlanabilir 15/255 fark). Kalan 7 sembol ≤1/255. |

Dokunulmayanlar: spring sabitleri, matchedGeometryEffect, `.id(tab)` geçişleri, namespace, `TabButton` Equatable, hover, erişilebilirlik etiketleri ve traits, notch #000000, WaveformView, Spotify/Shelf/Launcher/Mirror/System düzeltmeleri, Dock URL normalizasyonu.

## 4. Önce/sonra (A2 = `7c7ab66`, K4 = `4fc407c`)

**profile-rapid, 80 ms, 480 seçim (A/B/B/A):**

| Ölçüt | A2 | K4 | Fark |
|---|---:|---:|---:|
| Talimat / seçim | 215,9M | 199,2M | **−%7,7** |
| CPU % | 31,9 | 30,7 | −%4 |
| Enerji tahmini / seçim | 55,8 mJ | 51,0 mJ | −%8,6 |
| WindowServer CPU | %41,8 | %42,1 | ≈ aynı |
| Footprint | 49,2 MiB | 51,1 MiB | +~1,9 MiB |

**tab-speeds, 6 sekme (2 çift ortalaması):**

| Aralık | CPU % A2 → K4 | Talimat/seçim A2 → K4 |
|---:|---:|---:|
| 650 ms | 12,8 → 11,3 (−%12) | 398,8M → 349,7M (**−%12,3**) |
| 300 ms | 19,9 → 18,6 (−%7) | 350,8M → 326,2M (−%7,0) |
| 150 ms | 26,7 → 24,8 (−%7) | 265,9M → 244,4M (−%8,1) |
| 80 ms | 30,7 → 30,7 (≈) | 214,5M → 204,1M (−%4,9) |
| 50 ms | 37,1 → 35,4 (tek çift) | 190,6M → 182,6M (−%4,2) |

Ara aday K2'de (`753e316`, pano da opaklıklı) 6 ve 7 sekmede talimat −%7…−%16 ölçüldü. K4'teki pano istisnası kazancın bir kısmını geri aldı. 7 sekmeli (Focus dahil) test K2 ile yapıldı: talimat −%6,7…−%15,1, FAIL yok. K4 ile 7 sekme **NOT_TESTED**.

**Kısa aralıklarda seçim başına işin düşmesi:** Basit model: iş ≈ sabit (kurulum + ilk kareler, ~165M talimat) + kare başına ~7,8M × kare sayısı. 650 ms'de yay oturana kadar ~27 kare çiziliyor, 50 ms'de ~3 kare. Animasyonlar bir sonraki seçimde yeniden hedefleniyor (retarget), seçim atlanmıyor (her seçim model düzeyinde doğrulandı, FAIL yok). Kısa aralıktaki düşük ms/seçim, işin ucuzladığını değil, daha az kare çizildiğini gösteriyor. Bu yüzden kazanç da en çok 650 ms'de.

## 5. Kabul edilen ve reddedilen deneyler

| Deney | Sonuç | Karar |
|---|---|---|
| K_ICON → K4 (opaklıklı ikon tonu) | Yukarıdaki tablo | **Kabul** |
| X0: içerik çerçevesi animasyonunu kapatma | Kazanç yok (gürültü), görsel fark | Red |
| K_CAPS: tek kalıcı seçim kapsülü | Kazanç yok (24,5/23,6 vs 24,1/24,4 ms) | Red |
| PE: canvas türetimini önbellekleme (önceki tur E) | 214,9/215,6M vs A 215,0M | Red (kazanç yok) |
| PFGH: önceki turun birleşik F/G/H adayı | 214,3/215,9M vs 215,0M | Red (kazanç yok) |
| B/C/D (önceki tur, gece matrisi) | A/X/X/A'da fark yok | Red |
| C1: başlığı sabit kutuya alma (gece) | Kazanç yok | Red |
| C2: başlık hep simetrik | Başlık-tek tanıda −5,5 ms. Dar sekmelerde sekme konumunu ≤3 pt değiştiriyor | Kabul edilmedi (görsel değişiklik). Tam ölçüm yapılmadı |
| Tanı: compositingGroup yok | +%8 talimat, WS +4 puan | Yerinde kalmalı |

## 6. Frame ve animasyon eşdeğerliği

- Yay, süre, transaction ve geçişler kod düzeyinde aynı. İkon tonu aynı yayla canlanıyor. Tab switch yayı (sönüm 0,95/1,0) pratikte aşım üretmiyor (<0,0001).
- `TabIconTintCheck` (2x ImageRenderer, siyah zemin, dinlenme + 8 ara alfa): opaklık yolundaki 7 sembol ≤1/255. Mixer ve pano özgün yolda kalıyor.
- Animation Hitches (15 sn, 80 ms, tek çift A2/K2): kare ömrü p50/p95 46,8/48,6 vs 47,0/48,9 ms. Hitch sayısı 10 vs 15. Önceki A-A koşularında hitch 1–9 ve 17–2750 ms arası oynadığı için tek çift sonuç vermiyor: **eşdeğerlik kanıtlanmadı**. İkinci tekrar xctrace'in takılması ve disk dolması nedeniyle tamamlanamadı.
- Gerçek ara kare piksel yakalama, retarget sırasında görsel karşılaştırma, VoiceOver ağacı, klavye odağı, hover, drag-and-drop: **NOT_TESTED**.

## 7. Spotify, idle, GPU/WindowServer/enerji sınırları

- Spotify compact/expanded ve idle compact/expanded: **NOT_TESTED** (kullanıcı isteğiyle kısa doğrulama). Değişiklik yalnızca genişletilmiş başlıktaki `TabButton`'da. Compact durumda bu görünüm kurulmuyor, bu yalnızca kod düzeyinde bir gerekçe.
- WindowServer CPU'su eşleşen çiftlerde −0,9 ile +2,3 puan arasında oynadı (ortalamada ≈0). İşin WindowServer'a kaydığına dair tutarlı bir işaret yok. Süreç başına GPU yüzdesi **N/A**.
- Enerji: `ri_energy_nj` süreç tahmini. Aynı frekans modundaki çiftlerde −%9…−%15. Sistem ölçeğinde pil kazancı ölçülmedi.

## 8. Testler ve kontroller (HEAD `4fc407c`)

- `swift test -c release`: **172 test / 27 suite PASS**.
- `check-feedback`, `check-system`, `check-dock-previews`, `check-space-presentation`, `check-maintenance`, `check-controls`: PASS.
- `check-performance`: ilk koşuda `Tools/PerformanceChecks/Main.swift:49`'da (TransferMonitor KVO zamanlaması, 150 ms bekleme) düştü. Sonraki iki koşuda PASS, baseline `7c7ab66`'da PASS. Kod yolu bu değişiklikle ilgisiz, zamanlamaya bağlı kararsız bir kontrol olarak not edildi.

## 9. Güvenlik ve operasyon notları

- `/Applications/OpenIsland.app` (PID 28695) ve production main'e dokunulmadı, push yapılmadı. Diğer worktree'ler değiştirilmedi.
- Bu oturumda Animation Hitches kaydında `xctrace` iki kez takıldı. Kullanıcının Mac'inde `$TMPDIR` altında 46 adet artık `instruments*.ktrace` (86 GB) sistem diskini doldurmuştu (boş yer 107 MB'a düşmüştü). Kullanıcı onayıyla silindi, 87 GB boş yer açıldı. Yalnızca bu ölçüm turunun kendi takılı süreçleri sonlandırıldı.
- Ham kanıt: `/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261014-cpu` (`q2-*`, `q3-*`, `prof-*`, `K*.app`, `A2.app`). Araçlar: `/Volumes/HIKSEMI/proje/OpenIsland-runner/tools`.

## 10. Üretime hazır olma

Kod küçük ve geri alınabilir. Geri almak için `4fc407c`, `abbd5fa` ve `753e316` ters sırayla revert edilir. Ölçülen kazanç tekrarlanabilir. Production entegrasyonu için önerilen son adımlar:

1. Idle ve Spotify regresyon ölçümü.
2. Hitch'in en az 3 çift ile yeniden ölçülmesi.
3. Kontrastı Artır açıkken görsel kontrol. Sistem ayarı izinsiz değiştirilmedi, **NOT_TESTED**.
4. VoiceOver ve klavye odağıyla elle kontrol.
