# OpenIsland — Spotify ilerleme hatası düzeltmesi ve K5 üretim öncesi doğrulama

**Tarih:** 15–16 Ekim 2026 · **Dal:** `local/k5k6-perf-20261015` · **Düzeltme commit'leri:** `dd34bb1` + `bb2c583`
**Kanıt:** `/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261015-k5k6/spotify` (kişisel medya verisi içerir; paylaşılmaz)

**Karar:** Hata gerçek kodda bulundu ve düzeltildi. Kök neden: Spotify 1.3.x, kendi penceresindeki sarmada dağıtık bildirim
göndermiyor; `ScriptedPlayerSource` konumu yalnızca bildirimden ekstrapole ediyordu. Hata kurulu baseline'da da var, K4/K5 ile
ilgisi yok. Düzeltme K5 dalında ayrı commit; kurulu uygulama, `main` ve GitHub değişmedi.

## 1. Sürüm ilişkileri (doğrulandı)

| Ad | Commit / binary | İçerik |
|---|---|---|
| Kurulu uygulama | `269566c7…` | `d893acd` dönemi baseline |
| Canlı aday (15 Ekim testi) | `08cd2555…`, `a470b6f` | `d893acd` + F/G/H; **K4/K5 yok** |
| K5 dalı | `f7a696a` (K5), `07cf7fc` (hitch raporu) | `d893acd` + K4 (`753e316`, `abbd5fa`, `4fc407c`) + K5 |
| Bu aday | `bb2c583` (+ `44d4e0a` benchmark aracı), staged `668b511a…` | K5 dalı + Spotify düzeltmesi |

`ScriptedPlayerSource`, `NowPlaying`, `MediaController` `d893acd`'den `f7a696a`'ya ve `a470b6f`'ye kadar **birebir aynı**.
K5 yalnızca `IslandLayout.headerRowShift` ekledi; F/G/H `MediaPanel`'de yalnızca kapak yuvası geometrisini değiştirdi.
İlerleme modeliyle ilişkili K4/K5 kodu yoktur.

## 2. Yeniden üretim ve kök neden

Gerçek kaynak kodla derlenen sonda (`Tools/MediaChecks/SpotifySourceProbe.swift`) ile ayrı ayrı kaydedildi: ham bildirim,
kaynağın modeli (elapsed, timestamp, duration, isPlaying), UI'nin göreceği ekstrapole değer/yüzde ve Spotify'ın gerçek konumu.

| Bulgu | Kanıt |
|---|---|
| Bildirimler arasında model doğru | Sarma yokken model − Spotify: ortanca **−0,07 sn** (p5–p95: −0,10…+0,06; 283 örnek) |
| Bildirimdeki `Playback Position` **saniye** (birim hatası değil) | `66.574`, `81.428`, … (15 bildirim) |
| **Spotify'da sarma bildirim üretmiyor** | Spotify 112,9 → 211,8 sn sıçradı, bildirim yok; model 2:02'de ilerlemeye devam: **−93,9 sn** sapma |
| Geri sarmada model süreyi aşıyor, `elapsed(at:)` kırpıyor → "4:52 / −0:00", dolu çubuk; sonraki bildirime kadar kalır | Eski kaynakla deterministik negatif kontrol: 100 sn'ye bildirimsiz geri sarmadan sonra **240,0 / 240,0** |
| Bildirimdeki `Duration` kontrol API'sinden farklı olabilir | 263,8 sn vs 257,5 sn; kod zaten kontrol API'sinin süresini kullanıyor (değişmedi) |

**Düzeltilen hata (analiz):** İlk özette "Playing sonrası konum ~5 sn donuk, model +4,93 sn önde" yazılmıştı. Bu, sonda
analizinin her tick'i bir önceki (5 sn eski) kontrol API okumasıyla eşleştirmesinden kaynaklanan bir artefakttı; doğru eşleştirmeyle
(`tools/probepair.py`) böyle bir sapma yoktur. Buna dayanan başlangıç okuması `bb2c583` ile kaldırıldı.

Yanlış değer **kaynak modelinde** başlıyor (bildirimden sonra konum hiç yenilenmiyor); `MediaPanel`/`TimeProgressView` bu modeli
doğru gösteriyor. Raporlanan durum (Spotify 102,5 ve 167,9 sn çalarken UI 4:52 / −0:00) bildirimsiz geri sarmayla birebir
uyuşuyor. **Baseline'da var:** canlı karşılaştırmada düzeltmesiz örnek (PREK4, medya kodu kurulu sürümle aynı) sarmadan sonra
ortanca −100,6 sn geride kaldı.

## 3. Düzeltme (`dd34bb1`, `bb2c583`)

`ScriptedPlayerSource`'a olay güdümlü konum eşitlemesi: tek hafif Apple Event `{player position, state, id}` yalnızca
- öngörülen parça sonu + 1,5 sn'de bildirim gelmediyse (boşta en çok 3 okuma, sonra durur),
- kullanıcı oynatıcıdan ayrıldığında (`didDeactivateApplication`),
- süre çubuğu göründüğünde, yalnızca çalarken ve en sık 10 sn'de bir.

Konum ≥0,75 sn saptıysa veya durum değiştiyse okuma anına göre yayınlanır; farklı parçada mevcut tam yenileme kullanılır.
Kapak indirmesi iptal edilmez, süre/artwork önbelleği ve nesil korumaları değişmez, sürekli yoklama yoktur. Music kaynağı aynı
kuralları (`name of current track` ile) kullanır; MediaRemote kaynakları etkilenmez. `elapsed(at:)` kırpması (görüntü değişmezi)
korunur — yalnızca modelin kendisi düzeltilir.

## 4. Spotify süre/ilerleme doğrulaması

| Kontrol | Sonuç |
|---|---|
| `ScriptedPlayerCheck` yeni senaryolar (gerçek kaynak, sahte Apple Event) | PASS: raporlanan senaryo (uca yakın senkron → bildirimsiz geri sarma → doğru konum), panel ile ileri sarma, çalma başında okuma yok, uçta takılı oynatıcıda sınırlı okuma, duraklatılmışta iş yok, izin reddinde döngü yok, parça uyuşmazlığında tam yenileme |
| Negatif kontrol (eski kaynak) | Aynı senaryoda 240,0 / 240,0'da takılı |
| Canlı, gerçek MediaPanel (AX "geçen / toplam" değeri), aynı anda baseline ve aday (`dd34bb1`), kullanıcı Spotify'da sarıp başka uygulamaya döndü | Sarma sonrası 60 örnek: **baseline ortanca −100,6 sn, en çok 222,6 sn**; **aday ortanca −0,4 sn, en çok 0,9 sn, |Δ|>2 sn örnek yok** |
| Canlı, sarmasız 400 sn (iki doğal parça geçişi) | İki örnek de ±1 sn (ekranın tam saniyeye kesmesi) |
| Canlı, `dd34bb1`'in başlangıç okuması | Parça başında yanlış bir "sapma" düzeltip adayı bir parça boyunca baseline'ın 1 sn gerisinde bıraktı → `bb2c583` ile kaldırıldı |
| Canlı, `bb2c583` adayı (116 örnek) | Durağan: aday ortanca −0,89 sn, baseline −0,90 sn (aynı). Spotify penceresinde kalınan sarmalarda Spotify'ın ardından gelen kendi bildirimi ikisini de düzeltti (ayrılma tetikleyicisi bu kayıtta sınanmadı) |
| Oynat/duraklat düğmesi, artwork, süre | Duraklat/Oynat etiketi doğru; artwork (139 KB/205 KB) ve kontrol API süresi doğru yayınlandı |

Sürükleme sırasında (Spotify konumu saniyeler içinde 25 → 241 → 0,7 → 262 → 124 sn) panel ile gerçek okuma ~100 ms arayla
alındığı için anlık farklar görüldü; sürükleme bitince aday hemen eşitlendi. Denetim Merkezi'nden sarma ve Music: iki kayıt
penceresinde gerçekleşmedi (Spotify konumu kesintisiz, Music hiç çalışmadı) → **NOT_TESTED**; deterministik testler kapsar.

## 5. K5 performansının korunması (Spotify duraklatılmış, önceki K5 ölçümleriyle aynı koşul)

| Ölçüm | K5 | K5 + düzeltme | Fark |
|---|---:|---:|---:|
| 80 ms, 480 seçim (A/B/B/A × 2) — talimat/seçim | 192,9M | 193,1M | **+%0,08** (aralıklar çakışıyor) |
| 80 ms, 480 seçim — CPU zamanı/seçim | 49,3 ms | 49,5 ms | +%0,3 |
| 80 ms, 480 seçim — enerji tahmini / RAM | 38,3 mJ / 53,3 MiB | 38,6 mJ / 52,7 MiB | +%0,7 / −0,6 MiB |
| 650 ms (A/B/B/A × 3) — talimat/seçim | 360,9 / 353,5M | 357,2 / 355,6M | −%1,0 / +%0,6 |
| 50 ms (54 seçim, ~2,9 sn faz) | 162–168M | 169–177M | +%3,3…4,4 (kısa faz) |
| **50 ms, 480 seçim** (`OPENISLAND_BENCHMARK_RAPID_MS=50`, A/B/B/A × 3, 6+6 koşu) — talimat/seçim | 185,8M [184,5–186,9] | 185,5M [184,5–186,2] | **−%0,17** |
| 50 ms, 480 seçim — CPU zamanı / enerji tahmini / wakeup / RAM | 24,91 ms / 69,6 mJ / 130,9/sn / 54,3 MiB | 24,86 ms / 69,0 mJ / 131,2/sn / 54,5 MiB | −%0,2 / −%0,9 / +%0,2 / +0,2 MiB |

Kısa 50 ms fazındaki +%3–4, 54 seçimlik fazın gürültüsüydü (aynı binary'de ±%5); 480 seçimlik fazda fark yok. Bu ölçümler
`dd34bb1` yapısıyla alındı; `bb2c583` yalnızca çalarken yapılan bir okumayı kaldırır (duraklatılmış ölçüm koşulunda iş yapmaz).
K5 başlık eşdeğerlik denetimleri (yerleşim 21.780 genişlik, ara kare 2.247 örnek, 0 fark) düzeltmeden sonra da PASS.
Animasyon, #000000 yüzey, hover ve `matchedGeometryEffect` koduna dokunulmadı.

## 6. Animation Hitches (gerçek sayılar)

20 kayıt = **5 A/B/B/A bloğu** = **10 K4–K5 çifti**: 80 ms'de 3 blok (6 K4 + 6 K5 kayıt), 650 ms'de 2 blok (4 K4 + 4 K5).
"20 eşleşmiş çift" değildir. Sonuç: regresyon görülmedi; iyileşme iddia edilmez (bkz. K5/K6 raporu §7a).

## 7. VoiceOver / klavye / kontrast

| Kontrol | Durum |
|---|---|
| AX ağacı (rol, etiket, seçili trait, yardım, çerçeve) K4 ↔ K5 | Aynı (yapı karşılaştırması) |
| Medya panelinde AX "geçen / toplam" değeri | Gerçek konumla tutarlı (düzeltmeden sonra) |
| VoiceOver ile sesli gezinme | **NOT_VERIFIED**: VoiceOver kapalı; açmak sistem ayarı değişikliğidir, yapılmadı (etiketlerin bulunması PASS sayılmaz) |
| Klavye odağı, Tab / Shift-Tab | **NOT_VERIFIED**: Tam Klavye Erişimi kapalı (`AppleKeyboardUIMode` tanımsız); bu ayar olmadan düğmeler Tab ile odaklanmaz, ayar değiştirilmedi |
| Kontrastı Artır canlı | 15 Ekim canlı testinde yalnızca Medya paneli geçti (bu oturumda tekrarlanmadı); diğer paneller NOT_TESTED |

## 8. Testler

`swift test -c release`: **179 test / 28 suite PASS**. `check-performance` (yeni Spotify senaryoları dahil), `check-feedback`,
`check-system`, `check-controls`, `check-dock-previews`, `check-space-presentation`, `check-maintenance`: PASS.
`Tools/K5Checks/run.sh`: PASS. İmzalı aday: `Evidence/20261015-k5k6/staged/OpenIsland.app` (`codesign --strict` geçti,
kurulu uygulamayla aynı imza gereksinimi), kurulmadı.

## 9. Üretime geçişte kalan engeller

1. VoiceOver sesli gezinme ve klavye Tab/Shift-Tab elle doğrulaması (NOT_VERIFIED).
2. Kontrastı Artır: Medya dışı paneller.
3. Music uygulamasıyla canlı ilerleme testi; Spotify Connect / Denetim Merkezi'nden sarma (bu durumlarda düzeltme parça sonu
   denetimi ve panel açılışıyla yakalar; canlı test edilmedi).
4. Kurulu uygulamaya yükleme: ayrı onay, önce yedek.

Geri alma: `git revert bb2c583 dd34bb1` (Spotify düzeltmesi), `git revert f7a696a` (K5). `44d4e0a` yalnızca geliştirici benchmark aracıdır.

Not: Canlı medya kayıtlarında baseline ve aday kasıtlı olarak aynı anda açıktı (kurulu uygulamayla 3 örnek); bunlar CPU ölçümü
değildir. CPU/talimat ölçümleri her zaman tek test örneğiyle koştu.
