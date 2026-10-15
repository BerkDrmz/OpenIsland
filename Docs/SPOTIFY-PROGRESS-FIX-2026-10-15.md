# OpenIsland — Spotify ilerleme hatası düzeltmesi ve K5 üretim öncesi doğrulama

**Tarih:** 15 Ekim 2026 · **Dal:** `local/k5k6-perf-20261015` · **Düzeltme commit'i:** `dd34bb1`
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
| Bu aday | `dd34bb1`, staged `18cac0cb…` | K5 dalı + Spotify düzeltmesi |

`ScriptedPlayerSource`, `NowPlaying`, `MediaController` `d893acd`'den `f7a696a`'ya ve `a470b6f`'ye kadar **birebir aynı**.
K5 yalnızca `IslandLayout.headerRowShift` ekledi; F/G/H `MediaPanel`'de yalnızca kapak yuvası geometrisini değiştirdi.
İlerleme modeliyle ilişkili K4/K5 kodu yoktur.

## 2. Yeniden üretim ve kök neden

Gerçek kaynak kodla derlenen sonda (`Tools/MediaChecks/SpotifySourceProbe.swift`) ile ayrı ayrı kaydedildi: ham bildirim,
kaynağın modeli (elapsed, timestamp, duration, isPlaying), UI'nin göreceği ekstrapole değer/yüzde ve Spotify'ın gerçek konumu.

| Bulgu | Kanıt |
|---|---|
| Bildirimdeki `Playback Position` **saniye** (birim hatası değil) | `66.574`, `81.428`, … (15 bildirim) |
| **Spotify'da sarma bildirim üretmiyor** | Spotify 112,9 → 211,8 sn sıçradı, bildirim yok; model 2:02'de ilerlemeye devam: **−88,9 sn** sapma |
| Geri sarmada model süreyi aşıyor, `elapsed(at:)` kırpıyor → "4:52 / −0:00", dolu çubuk; sonraki bildirime kadar kalır | Eski kaynakla deterministik negatif kontrol: 100 sn'ye bildirimsiz geri sarmadan sonra **240,0 / 240,0** |
| "Playing" bildiriminden sonra gerçek konum 2–5 sn donuk | Oynatırken model ortanca **+4,93 sn** önde (p5–p95: 2,2–5,1 sn; 283 örnek); parça sonunda çubuk birkaç sn erken doluyor |
| Bildirimdeki `Duration` kontrol API'sinden farklı olabilir | 263,8 sn vs 257,5 sn; kod zaten kontrol API'sinin süresini kullanıyor (değişmedi) |

Yanlış değer **kaynak modelinde** başlıyor (bildirimden sonra konum hiç yenilenmiyor); `MediaPanel`/`TimeProgressView` bu modeli
doğru gösteriyor. Raporlanan durum (Spotify 102,5 ve 167,9 sn çalarken UI 4:52 / −0:00) bildirimsiz geri sarmayla birebir
uyuşuyor. **Baseline'da var:** canlı karşılaştırmada düzeltmesiz örnek (PREK4, medya kodu kurulu sürümle aynı) sarmadan sonra
ortanca −100,6 sn geride kaldı.

## 3. Düzeltme (`dd34bb1`)

`ScriptedPlayerSource`'a olay güdümlü konum eşitlemesi: tek hafif Apple Event `{player position, state, id}` yalnızca
- "Playing" bildiriminden 6 sn sonra (konum hâlâ donuksa 2 sn arayla en çok 3 deneme),
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
| `ScriptedPlayerCheck` yeni senaryolar (gerçek kaynak, sahte Apple Event) | PASS: raporlanan senaryo (uca yakın senkron → bildirimsiz geri sarma → doğru konum), panel ile ileri sarma, donuk başlangıç, uçta takılı oynatıcıda sınırlı okuma, duraklatılmışta iş yok, izin reddinde döngü yok, parça uyuşmazlığında tam yenileme |
| Negatif kontrol (eski kaynak) | Aynı senaryoda 240,0 / 240,0'da takılı |
| Canlı, gerçek MediaPanel (AX "geçen / toplam" değeri), aynı anda baseline ve aday, kullanıcı sarmaları | Sarma sonrası 60 örnek: **baseline ortanca −100,6 sn, en çok 222,6 sn**; **aday ortanca −0,4 sn, en çok 0,9 sn, |Δ|>2 sn örnek yok** |
| Canlı, sarmasız 400 sn (iki doğal parça geçişi) | İki örnek de ±1 sn (ekranın tam saniyeye kesmesi) |
| Oynat/duraklat düğmesi, artwork, süre | Duraklat/Oynat etiketi doğru; artwork (139 KB/205 KB) ve kontrol API süresi doğru yayınlandı |

Sürükleme sırasında (Spotify konumu saniyeler içinde 25 → 241 → 0,7 → 262 → 124 sn) panel ile gerçek okuma ~100 ms arayla
alındığı için anlık farklar görüldü; sürükleme bitince aday hemen eşitlendi. Music ile canlı test yapılmadı (NOT_TESTED).

## 5. K5 performansının korunması (Spotify duraklatılmış, önceki K5 ölçümleriyle aynı koşul)

| Ölçüm | K5 | K5 + düzeltme | Fark |
|---|---:|---:|---:|
| 80 ms, 480 seçim (A/B/B/A × 2) — talimat/seçim | 192,9M | 193,1M | **+%0,08** (aralıklar çakışıyor) |
| 80 ms, 480 seçim — CPU zamanı/seçim | 49,3 ms | 49,5 ms | +%0,3 |
| 80 ms, 480 seçim — enerji tahmini / RAM | 38,3 mJ / 53,3 MiB | 38,6 mJ / 52,7 MiB | +%0,7 / −0,6 MiB |
| 650 ms (A/B/B/A × 3) — talimat/seçim | 360,9 / 353,5M | 357,2 / 355,6M | −%1,0 / +%0,6 |
| 50 ms (54 seçim, ~2,9 sn faz) | 162–168M | 169–177M | +%3,3…4,4, **sonuçsuz** |

50 ms: `.onAppear` olmadan derlenen tanı varyantı K5S'den hem yüksek hem düşük çıktı; aynı binary'de 155–173M yayılım. Düzeltme
duraklatılmış oynatıcıda Apple Event göndermez; ölçüm sırasında sistem çok yüklüydü (CPU% 44 yerine 56–77; soffice, python,
mobileassetd). 50 ms farkı gürültüden ayrıştırılamadı — sakin bir aralıkta uzun bir 50 ms fazıyla tekrar ölçülmeli.
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
| VoiceOver ile sesli gezinme | **NOT_VERIFIED** (etiketlerin bulunması PASS sayılmaz) |
| Klavye odağı, Tab / Shift-Tab | **NOT_VERIFIED** |
| Kontrastı Artır canlı | 15 Ekim canlı testinde yalnızca Medya paneli geçti (bu oturumda tekrarlanmadı); diğer paneller NOT_TESTED |

## 8. Testler

`swift test -c release`: **179 test / 28 suite PASS**. `check-performance` (yeni Spotify senaryoları dahil), `check-feedback`,
`check-system`, `check-controls`, `check-dock-previews`, `check-space-presentation`, `check-maintenance`: PASS.
`Tools/K5Checks/run.sh`: PASS. İmzalı aday: `Evidence/20261015-k5k6/staged/OpenIsland.app` (`codesign --strict` geçti,
kurulu uygulamayla aynı imza gereksinimi), kurulmadı.

## 9. Üretime geçişte kalan engeller

1. 50 ms hızlı geçiş farkının sakin sistemde, uzun fazla yeniden ölçümü (şu an sonuçsuz).
2. VoiceOver sesli gezinme ve klavye Tab/Shift-Tab elle doğrulaması (NOT_VERIFIED).
3. Kontrastı Artır: Medya dışı paneller.
4. Music uygulamasıyla canlı ilerleme testi; Spotify Connect / Denetim Merkezi'nden sarma (son iki durumda düzeltme parça sonu
   denetimi ve panel açılışıyla yakalar; canlı test edilmedi).
5. Kurulu uygulamaya yükleme: ayrı onay, önce yedek.

Geri alma: `git revert dd34bb1` (yalnızca Spotify düzeltmesi), `git revert f7a696a` (K5).
