# OpenIsland — K5/K6 performans programı

**Tarih:** 15 Ekim 2026 · **Dal:** `local/k5k6-perf-20261015` · **Worktree:** `/Volumes/HIKSEMI/proje/OpenIsland-k5k6-dev`
**Taban:** `e87b81d` (K4: `753e316`, `abbd5fa`, `4fc407c`, `e87b81d`; yalnızca `local/render-cpu-20261014` dalında,
başka dala aktarılmamış — doğrulandı). Kanıt: `/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261015-k5k6`.

**Karar:** Bir K5 optimizasyonu kabul edildi (`f7a696a`, başlık satırının sekme geçişinde sabit kalması). İki K6 denemesi ve
bir K5 yolu kanıtla reddedildi. 80 ms hızlı geçişte %25 altı CPU hedefine **ulaşılamadı**; ölçülen kazanç talimat ve enerji
tahmininde, CPU yüzdesinde değil. `/Applications/OpenIsland.app`, production `main`, GitHub ve diğer worktree'ler değişmedi.

## 1. Ölçüm yöntemi

- Uygulamanın kendi kontrollü benchmark'ı: `tab-speeds` (6 sekme, 650/300/150/80/50 ms, hız başına 54 seçim) ve
  `profile-rapid` (80 ms, 480 seçim). Fixture/defaults önceki turlarla aynı (`20261013-rapid-tab-validation`).
- Uygulama `open -n -g --env …` ile başlatıldı (otomasyon kabuğundan doğrudan başlatma, TCC'nin sorumlu süreç kuralı nedeniyle
  `NSBluetoothAlwaysUsageDescription` SIGABRT'ı veriyor). Kurulu uygulamayla aynı imza gereksinimi.
- Faz sınırlarında `proc_pid_rusage`: talimat, çevrim, `ri_energy_nj` (süreç enerji tahmini), CPU zamanı, wakeup, footprint;
  WindowServer CPU zamanı farkı. **Birincil ölçüt talimat/seçim** (aynı binary'de ±%1); CPU% sistem yüküne çok duyarlı:
  ölçüm boyunca `ApplicationsStorageExtension` sık sık ~%90–100 CPU kullandı (sistem süreci, durdurulmadı).
- A/B/B/A, iki çift (her varyant için 4 koşu). Geçersiz koşu (FAIL) bütünüyle dışlandı.
- Time Profiler: 12 sn sınırlı kayıt (~29 MB), watchdog yalnızca kendi `xctrace` sürecini 90 sn sonra sonlandırır ve
  `$TMPDIR` 2 GiB'tan fazla büyürse durdurur. Artık ktrace oluşmadı.

## 2. Rakip mimarilerinden değerlendirilen ilkeler ve OpenIsland'daki karşılıkları

| İlke (kaynak) | OpenIsland'da durum | Sonuç |
|---|---|---|
| No-op state guard (Boring Notch) | `IslandViewModel.process` yalnızca değişen alanları yayınlar; `SystemMonitor` aynı değeri yeniden yayınlamaz; `MediaController.updateArtwork` artwork baytları aynıysa çözmez/renk türetmez; `ClipboardHistory.promote` aynı öğeyi yeniden yazmaz | Zaten var; yeniden paketlenmedi |
| Bounded cache / single-flight / generation guard / iptal (Boring Notch RC) | Shortcuts fetch single-flight + timeout, Shelf önizleme token/kimlik koruması, `SystemMonitor` nesil koruması + iptal edilebilir görevler, Spotify bayat yayın koruması (önceki turlar) | Zaten var |
| Görünürlüğe bağlı sensör/observer (Boring Notch, Atoll) | Sistem örnekleme yalnızca panel görünürken (`panelDidAppear/Disappear` sayaçlı); pano olay güdümlü, yoklamasız | Zaten var; eksik bulunmadı |
| Sekme içeriği `.id(currentView)` + kalıcı host (Atoll) | OpenIsland zaten tek kalıcı `NSHostingView` + `.id(tab)` kullanıyor | Panel ömrü (Mirror kamera, Sistem örnekleme `onAppear/onDisappear`) değiştirilmedi; kalıcı panel denenmedi |
| NotchNook/Alcove importları | Çalışma zamanı kanıtı değil | Değerlendirmeye alınmadı |

Kod kopyalanmadı; private SkyLight API eklenmedi.

## 3. Profil bulguları (BASE = K4, 80 ms)

- Ana thread örneklerin %98'i. Seçimden sonraki ilk 20 ms panel kurulumu (yığın yerleşimi, metin ölçümü); kalan süre
  animasyon kareleri (`tools/phase.py`, `tools/pertab.py`).
- **`FocusBridge.invalidateKeyViewLoop` ana thread'in ~%11'i**, animasyon karelerinin ~%16–19'u, her karede. Tanı
  ablasyonları (Media+Nook çifti): `onDrop`, `.help`, kök erişilebilirlik eylemleri, `onHover` kaldırmak etkisiz; panel
  içeriği kaldırılınca **%0**, medya katmanları kaldırılınca %8,7 → %3,8. Tetikleyici, her karede yer değiştiren AppKit
  tabanlı görünümler (Waveform/Marquee/TimeProgress `NSViewRepresentable`, ScrollView/NSTextView). Bunlar zaten
  `acceptsFirstResponder = false`. İçeriğin görünür hareketi değiştirilmeden kaldırılamadı → **uygulanmadı**.
- İzole harness: SwiftUI'de `.offset` de "salt render" değil; kare başına çocukların `AnimatableFrameAttribute` ve platform
  `setFrame` işini üretir (offset 6,63G vs geometri 6,80G talimat). SwiftUI yerleşim değişimini son konumlar arasında
  **doğrusal ilerlemeyle** interpole eder (ölçüldü: eşik geçişinde kırılma yok) — K5 eşdeğerliğinin dayanağı.
- Seçim başına en pahalı panel kurulumu: Not (~43 ms ana thread), Pano (~40 ms, bunun 10,8 ms'i metin ölçümü).

## 4. K5 — kabul edilen değişiklik (`f7a696a`)

**Sorun:** Başlık satırı (9 sekme + iğne) gövdenin yay ile genişliğe giden çerçevesinin içindeydi. Her sekme geçişinde
satırın tüm yerleşimi ve düğmelerin platform geometrisi her karede güncelleniyordu. Dar gövdelerde (W < ~373 pt) yığın
satırı en çok 3 pt kaydırıyordu (gerçek, görünür hareket).

**Değişiklik:**
1. Satır tuval genişliğinde sabit bir kutuda (geniş gövdelerdeki simetrik yerleşim).
2. `IslandLayoutEngine.headerRowShift` dar gövde kaymasını yığının dağıtım kuralıyla hesaplar, piksele yuvarlar; tam
   piksel/yuvarlama garantisi yoksa (1× ekran, tam yarım piksel) `nil` → özgün yerleşim (kutu = gövde, kayma yok).
3. Kayma `.offset` olarak aynı transaction'da, aynı yay ile canlanır.
4. İç ZStack'te başlığın görünmez, etkileşimsiz iskeleti: özgün yapıda başlık dar gövdelerde gövdeden geniş ölçülüp
   içeriğin önerilen genişliğini belirliyordu (Not panelinde içerik kenarı 8 yerine ~5 pt). İlk aday (K5A) bunu
   değiştirdiği için gerçek ekran görüntüsü karşılaştırmasında yakalandı ve iskeletle düzeltildi (K5B = commit).

Dokunulmayanlar: yaylar/süreler, `matchedGeometryEffect` kapsülü, ikonlar ve K4 tonu, `.id(tab)` geçişleri, hover,
erişilebilirlik etiketleri/trait'leri, `.help`, notch #000000, panel içerikleri.

**Eşdeğerlik kanıtı (`Tools/K5Checks/run.sh`):**
- Yerleşim: 180 yapılandırma (çentik 185/200, pill, yan boşluk 8/12, 0–5 sol, 0–4 sağ sekme) × 21.780 genişlik; tüm
  düğmeler ve içerik kenarları birebir aynı. Negatif kontroller: kaymasız 19.440, iskeletsiz 13.684 uyuşmazlık.
- Ara kareler: özgün ve aday aynı pencerede, aynı yay, 80/50/650 ms yeniden hedeflemeli dizi; 2.237–2.283 örnek, özgünün
  ~275 farklı karesi, en büyük fark **0,0 pt**. Negatif kontrol (ofset canlanmazsa) 543 örnekte 3 pt fark.
- Gerçek uygulama: 650 ms fazında çentik bölgesinin sürekli ekran görüntüleri; oturmuş karelerin **başlık şeridi tüm
  karelerde BASE ile piksel piksel aynı**; panel içindeki tek fark canlı sıcaklık değeri (BASE–BASE koşularında da var).
- `swift test -c release`: **179 test / 28 suite PASS** (7 yeni `HeaderRowShiftTests`). `check-feedback`, `check-system`,
  `check-controls`, `check-dock-previews`, `check-space-presentation`, `check-maintenance`, `check-performance`: PASS.

**Ölçüm (BASE → K5B, A/B/B/A × 2):**

| Aralık | Talimat/seçim | Çevrim/seçim | CPU % | Enerji tahmini/seçim | WindowServer % | Footprint |
|---:|---:|---:|---:|---:|---:|---:|
| 650 ms | 364,6M → 351,6M (−%3,6) | −%2,9 | 18,1 → 17,7 | −%0,4 | ≈ | +0,3 MiB |
| 300 ms | 337,3M → 319,1M (−%5,4) | −%3,6 | 31,1 → 30,2 | −%5,6 | ≈ | +0,4 MiB |
| 150 ms | 259,2M → 250,3M (−%3,4) | −%0,2 | 41,8 → 41,6 | −%7,8 | ≈ | +0,4 MiB |
| 80 ms | 211,4M → 197,7M (−%6,5) | −%4,7 | 45,3 → 44,8 | −%9,5 | +0,8 puan | +0,2 MiB |
| 50 ms | 193,0M → 184,7M (−%4,3) | −%1,5 | 46,5 → 46,3 | −%3,6 | ≈ | −0,2 MiB |
| **80 ms, 480 seçim** | **208,5M → 199,2M (−%4,5)**, aralıklar çakışmıyor | −%3,5 | 44,8 → 44,5 | **−%6,7** | +0,7 puan | +0,5 MiB |

Wakeup/sn değişmedi (±%1). İlk aday K5A'nın ayrı A/B/B/A'sı da aynı yönde (−%2,3…−%5,0; 80 ms hızlı −%4,5).
Bu turdaki CPU% değerleri, yüklü sistem nedeniyle K4 raporundaki %30,7 ile karşılaştırılamaz (aynı BASE burada %44,8).
Kısa aralıkta seçim başına işin azalması daha az kare çizilmesinden de kaynaklanır; karşılaştırmalar aynı aralıkta yapıldı.

## 5. Reddedilen / uygulanmayan deneyler

| Deney | Kanıt | Karar |
|---|---|---|
| K6-C1: pano satırı önizlemesini ilk satır sonu + 1 karaktere kısaltmak (CoreText'in 5–40 bin karakteri dizgilemesini önlemek) | 384 render'da 26 piksel farkı (devamı boş satırsa "…" kararı değişiyor) | Ret |
| K6-C2: ilk görünür karaktere kadar tutmak | Aynı 26 fark; SwiftUI ilk satırı toplam metin uzunluğuna bağlı biraz farklı konumluyor (x=216'dan itibaren kayma, 249/255) | Ret — birebir eşdeğer olamaz |
| K5 Focus: kare başı `FocusBridge` geçersizleştirmesini kaldırmak | Kök neden bulundu (hareket eden platform görünümleri); `.offset` dahil hiçbir yerleşim-dışı hareket bunu önlemiyor | Uygulanmadı (görsel/odak davranışı değişirdi) |
| Daha önce reddedilenler (Header Equatable, ByteCountFormatter cache, kalıcı kapsül, simetrik başlık C2, Canvas cache, F/G/H) | K4 raporu | Tekrarlanmadı. K5, C2'nin görsel değişikliğini ofset+iskelet ile birebir eşdeğer hale getirerek kazancın bir kısmını aldı |

## 6. K6 denetimi

Media artwork (bayt kimliği koruması), Shelf önizlemesi (token/kimlik), Dock önizleme, pano (yoklamasız, olay güdümlü,
tekrar yazmama), Notes/Shortcuts (single-flight + timeout), sistem örnekleme (görünürlük + nesil + iptal), Mirror kamera
(panel ömrüne bağlı), Mixer dinleyicileri: kod düzeyinde gereksiz tekrar bulunmadı; önceki turların düzeltmeleri yerinde.
Ölçülebilir eksik bulunan tek alan pano satırı metin ölçümüydü ve eşdeğerlik sağlanamadığı için reddedildi.

## 7. K4 regresyonları ve idle

Uygulamanın `idle-compact` / `idle-expanded` modları (her biri ~324 sn). PREK4 = K4 öncesi `7c7ab66` kaynakları, aynı
ortamda yeniden derlendi. Spotify açık ve **duraklatılmış** (`playing=false`, başlık yüklü), yani bunlar aynı zamanda
"Spotify paused compact/expanded" koşularıdır.

| Durum | PREK4 | K4 (BASE) | K5 |
|---|---:|---:|---:|
| Compact idle CPU | %0,002 | %0,003 | %0,001 |
| Compact talimat/sn | 0,029M | 0,035M | 0,025M |
| Compact footprint | 33,1 MiB | 32,9 MiB | 33,2 MiB |
| Expanded (Nook) idle CPU | %0,002 | %0,002 | %0,002 (uygulama sayacı) |
| Expanded talimat/sn | 0,083M | 0,079M | N/A (son rusage örneği kaçtı) |
| Expanded footprint | 42,3 MiB | 41,7 MiB | N/A |
| Wakeup/sn | ~0 | ~0,1 | ~0 |

Idle maliyeti üç sürümde de ölçüm çözünürlüğünde sıfıra yakın; K4 ve K5 regresyon göstermiyor (tek koşu, fark gürültü
düzeyinde). Expanded idle'da K4/K5 değişikliklerinin çalıştığı başlık hiç canlanmaz.

**Erişilebilirlik (VoiceOver yapısı):** Test uygulamasının AX ağacı programatik okundu (eylem yok). Nook açıkken BASE ve
K5'te 35 öğenin rol, etiket, seçili trait, yardım metni, çerçeve ve sırası birebir aynı. `tab-speeds` 650 ms fazında
~185 örnekle, altı sekmenin (dar gövdeli Raf/Pano/Not dahil) oturmuş başlık düğmelerinin AX çerçeveleri ve trait'leri
BASE ile aynı. Döküm kullanıcının gerçek takvim/anımsatıcı metinlerini içerdiği için yalnızca yerel kanıt klasöründedir.

## 8. Eksik doğrulamalar (NOT_TESTED)

- Spotify **çalarken** compact/expanded: kullanıcının hesabında ses başlatacak komut gönderilmedi. Spotify açık/duraklatılmış
  durumdaydı (test uygulaması `playing=false`).
- Kontrastı Artır'ın canlı açılması: sistem ayarı değiştirilmedi. K4 ikon alfası 0,7 dahil ara alfalar `TabIconTintCheck`
  ile kod/piksel düzeyinde kapsanıyor; K5 renk/kontrastla ilgili kod değiştirmedi.
- VoiceOver ile sesli gezinme ve klavye (Tab / Tam Klavye Erişimi) odağı elle denenmedi; AX ağacı yapısı ve çerçeveleri
  karşılaştırıldı (bkz. §7). İskelet `hidden` + `accessibilityHidden` + `allowsHitTesting(false)`; AX ağacında görünmüyor.
- Animation Hitches (çoklu eşleşmiş koşu): önceki turda `xctrace` takılması ve disk dolması yaşandığı için bu turda
  çalıştırılmadı; ara kare eşdeğerliği konum düzeyinde ölçüldü, kare zamanlaması ölçülmedi.
- Süreç başına GPU yüzdesi ve watt: N/A. WindowServer CPU'su toplamdır, yalnızca OpenIsland'a ait değildir.
- 1× ekran: hızlı yol devre dışı kalır (özgün yerleşim); 1× ekranda koşu yapılmadı.

## 9. Commit'ler ve geri alma

| Commit | İçerik | Geri alma |
|---|---|---|
| `f7a696a` | K5 başlık satırı + `headerRowShift` + testler + `Tools/K5Checks` | `git revert f7a696a` |
| (bu belge) | Rapor | — |

K4 commit'leri bu dalda mevcuttur (taban). Üretime aktarılabilir değişiklik: `f7a696a` (K4 ile birlikte). Kurulu uygulamanın
değiştirilmesi, `main`'e birleştirme ve push ayrı kullanıcı onayı gerektirir.

## 10. Ortam notları

- `OpenIsland-runner/runner.command`'ın iki kopyası (PID 23161, 83771) eşzamanlı çalışıyor; aynı işi iki kez
  çalıştırabilir. Dokunulmadı.
- Tanı derlemeleri ayrı geçici worktree'de yapıldı: `/Volumes/HIKSEMI/proje/OpenIsland-k5k6-diag` (silinebilir).
- Ölçüm araçları: `Evidence/20261015-k5k6/tools` (`bench.sh`, `abba.sh`, `prof.sh`, `vis.sh`, `compare.py`, `phase.py`,
  `pertab.py`, `tabtop.py`), harness'ler `Evidence/20261015-k5k6/harness`.
