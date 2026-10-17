# OpenIsland — Klavye odağı ve medya konum eşitlemesi (2026-10-16, 2. tur 2026-10-17)

Dal: `local/k5k6-perf-20261015` (yerel; `main`, uzak depo, kurulu `/Applications/OpenIsland.app` ve v0.1.0 değişmedi).
Taban: K5 (`bb2c583` + rapor commit'leri, aday K5F). Yeni aday: `69c44fe` (K6C).

## 1. Özet

| Konu | Sonuç |
|---|---|
| Klavyeyle açılan adanın odak kaybı | Kök neden kanıtlandı, **düzeltildi** (`f62923c`) |
| Spotify/Music: panel açık + iğneliyken oynatıcıda sarma | Olay güdümlü düzeltme (`69c44fe`); **canlı PASS** (Spotify çubuğuna gerçek tıklama, 0,72–0,76 sn) |
| Canlı testte bulunan 2 yeni Spotify hatası | Yanlış toplam süre (parça değişiminde 6,3 sn) ve uygulama düğmesiyle baştan başlatma — **düzeltildi** (`4df4507`), canlı PASS |
| Hızlı sekme CPU | Profil: maliyet SwiftUI/AppKit yerleşim-çizim-odak işinde; görsel eşdeğer tek gerçek tekrar eden iş (LaunchServices başlık sorgusu) kaldırıldı (`dfac1bd`, −%0,6…−%0,9) |
| 1/2/5 sn görünür doğrulama (yoklama) | Ölçüldü, **ürüne alınmadı** |
| Medya senaryo matrisi | 14 senaryo deterministik PASS; canlı pasif parça geçişi PASS |
| Ek hipotezler | 4 hipotez ölçüldü; hiçbiri ürüne alınacak kazanç vermedi (§5) |
| Performans (80 ms / 650 ms / kompakt boşta) | K5 ile eşdeğer (§5) |

Karar: **READY_FOR_REVIEW** — dört ürün düzeltmesi kanıtlı ve regresyonsuz. 80 ms için %25 CPU hedefi görsel/animasyon
değiştirmeden **ulaşılamadı** (§9). Açık kalanlar §7.

## 2. Klavye odağı

### Yeniden üretim (tanılama derlemesi, kurulu uygulama kapatılmadan)

- Test örneği yalnızca tanılama ortam değişkeniyle ⌃⌥⌘J kısayolunu aldı (Carbon yolu aynı; kurulu uygulama ⌃⌥⌘I'yı tutmaya
  devam etti). Tab/Shift-Tab yalnızca test sürecine (`postToPid`) gönderildi.
- Günlük: model olayları, faz değişimleri, `didBecomeKey/didResignKey`, `firstResponder` (KVO), uygulama/çalışma alanı
  etkinleşmesi, yerel `keyDown/mouseDown`, dış tıklama izleyicisi.
- "Klavyeyle gezinme" kapalıyken macOS Tab ile düğmelere hiçbir uygulamada geçmez (`AppleKeyboardUIMode=0`); süreç içi
  argüman/kanca SwiftUI'yi etkilemedi, test için ayar kullanıcı tarafından geçici açıldı ve sonra kapatıldı.

### Olay sırası (6 koşu, eski kod)

Başarısız her koşuda sıra aynıydı:

```
hotkey-pressed → event tapped (compact → expanded) → didBecomeKey panel
outside-monitor-click inside=false → event tappedOutside (expanded → compact) → relinquishKeyFocus → didResignKey
didBecomeKey panel (≈40–60 ms sonra, appActive=true)        ← kapanmış ada key'i GERİ ALIYOR
firstResponder → AppKitTextField / PlatformTextView         ← kaldırılmış içerikten bayat responder
```

- Odak "kaybı"nın tetikleyicisi, test sırasında başka bir uygulamada yapılan gerçek fare tıklamalarıydı (Antigravity,
  Sistem Ayarları etkinleşmesi günlükte). Dış tıklama adayı tasarım gereği kapatır (fareyle açılan adayla aynı).
- Tıklama olmayan koşularda Tab 10+ adım doğru ilerledi.
- **Asıl hata:** `relinquishKeyFocus` (orderOut + orderFrontRegardless) uygulama hâlâ etkinken çalışınca AppKit sıradaki
  key adayı olarak paneli yeniden seçiyordu. Kapanmış ada klavye odağını tutuyor (Escape bile kapanmış adaya gitti) ve
  first responder olarak kaldırılmış Notlar metin görünümü kalıyordu. Normal Escape kapanışında da görüldü.

### Düzeltme (`f62923c`)

- `NotchPanel.canBecomeKey` yalnızca ada genişken `true` (`acceptsKeyFocus`, kontrolcü her faz değişiminde ayarlar).
- Kapanırken key bırakılmadan önce `makeFirstResponder(nil)`.
- Zamanlayıcı, gecikme veya sürekli key zorlama yok; klavyeyle açma yolu değişmedi (`.tapped` → genişleme → aynı çağrıda
  `makeKeyAndOrderFront`).

### Doğrulama (canlı, test örneği)

| Test | Eski | Yeni |
|---|---|---|
| Dış tıklama (yalnızca test sürecine) sonrası kapanmış panelin yeniden key olması | 3/3 | **0/3** |
| Notlar'dan Escape sonrası yeniden key + bayat `PlatformTextView` | 1/1 | **0/1** |
| Tab ×12 + Shift-Tab ×12 sırası (tıklamasız) | — | eski ile birebir aynı, 3/3 |
| Notlar düzenleyicisine giriş, yazma, Ctrl-Tab ile çıkış, Shift-Tab ile dönüş | çalışıyor | aynı |

Fareyle hover/tıklama yolu kod düzeyinde değişmedi (genişken `canBecomeKey` aynı). Notlar'a gerçek fare tıklaması canlı
denenmedi (NOT_TESTED).

## 3. Spotify / Apple Music konum eşitlemesi

### Kalan sorun

Spotify (1.3.x) ve Music kendi pencerelerinde yapılan sarmada dağıtık bildirim göndermez. Önceki düzeltme (öngörülen
parça sonu, oynatıcıdan ayrılma, panel açılışı) bir durumu açık bırakıyordu: **panel açık + iğneli, kullanıcı oynatıcı
öndeyken sarıyor**. Panel, kullanıcı oynatıcıdan ayrılana veya paneli yeniden açana kadar yanlış kalıyordu.

### Seçilen çözüm (`69c44fe`) — olay güdümlü

- Süre çubuğu görünür (`onAppear/onDisappear`, ekran başına sayaçlı) **ve** kaynak çalıyorken tek bir sistem geneli
  `leftMouseUp` izleyicisi kurulur (yalnızca tıklama; fare hareketi ve tuşlar dinlenmez, Erişilebilirlik izni gerekmez).
- Bırakmada oynatıcı öndeyse 0,35 sn sonra **tek** konum okuması (`{player position, state, id}`); art arda tıklamalar
  tek okumaya iner (single-flight, generation guard). Sapma 0,75 sn'yi aşmazsa yeniden yayın yok.
- İzleyici panel gizlenince, duraklatınca, kaynak durunca/uygulama kapanınca kaldırılır. Kompakt boşta ve duraklatılmışken
  Apple Event yok.
- Oynatıcının çalma durumu, sesi veya konumu hiçbir koşulda değiştirilmedi.

### Denetimler

`ScriptedPlayerCheck` yeni senaryo 8: duraklatılmışken izleyici yok; görünür + çalarken var; öndeki oynatıcıda tıklama
→ 1 okuma ve düzeltme; arka plandaki tıklama → 0 okuma; 5 tıklama → 1 okuma; panel gizlenince/duraklatınca/durunca
izleyici kaldırılır. Önceki 7 senaryo (geri/ileri sarma, başlangıçta okuma yok, sınırlı parça sonu, duraklatma, parça
uyuşmazlığı, izin reddi) PASS.

### 1/2/5 sn görünür doğrulama deneyi (ürüne alınmadı)

Panel açık + iğneli, Medya sekmesi, Spotify çalıyor, kullanıcı sarmıyor; A-B-B-A, koşu başına 60 sn, n=2.

| Aralık | OpenIsland talimat M/s | CPU % | Uyanma/s | Enerji mJ/s | Apple Event/dk | Yapılan düzeltme |
|---|---|---|---|---|---|---|
| yok (aday) | 6,53 | 0,46 | 1,99 | 0,54 | 0,5 | 0 |
| 5 sn | 7,12 (+%9) | 0,55 | 1,62 | 0,54 | 11 | 0 |
| 2 sn | 9,94 (+%52) | 0,68 | 1,85 | 0,78 | 29 | 0 |
| 1 sn | 15,80 (+%142) | 0,98 | 2,41 | 1,17 | 57,5 | 0 |

Spotify'ın kendi CPU'su (1,9–2,2%) koşular arası gürültüde kaldı; Apple Event başına maliyeti çözülemedi. Yoklama, sarma
olmayan normal kullanımda hiç düzeltme yapmadı ve yalnızca maliyet ekledi. Olay güdümlü yol bu durumda 0 Apple Event/dk
harcar. Uzaktan sarma (ör. telefondan Spotify Connect) ve oynatıcı içinde klavyeyle sarma bu yolla yakalanmaz; bunlar
oynatıcıdan ayrılmada, panel yeniden açılışında veya öngörülen parça sonunda düzelir (bilinen sınır).

### Senaryo matrisi (deterministik denetimler, gerçek kaynak kodu, sahte Apple Event)

| Senaryo | Kapsayan denetim | Sonuç |
|---|---|---|
| Çalarken oynatıcıda sarma (bildirimsiz) | ScriptedPlayer 1, 1b, 2 | PASS |
| Panel açık + iğneli, oynatıcı önde sarma | ScriptedPlayer 8 | PASS |
| Kompakt/kapalı panelde sarma | parça sonu okuması (1, 4) + ayrılma/panel açılışı | PASS (yoklama yok) |
| Parça değişimi | ScriptedPlayer kimlik/süre senaryoları | PASS |
| Oynat/duraklat (100 hızlı geçiş) | ScriptedPlayer "rapid play/pause" | PASS, ek Apple Event yok |
| Aynı parçayı baştan başlatma | Matris 9 | PASS, okuma yok |
| Aynı adlı farklı parçalar (farklı Spotify kimliği) | "distinct IDs/durations" | PASS |
| Apple Music (bildirimde konum yok, başlığa göre kimlik) | Matris 9 Music | PASS |
| Kaynak değişimi Spotify ↔ Music | MediaArtworkCheck kaynak değişimi | PASS |
| İzin reddi / Apple Event hatası | ScriptedPlayer 7, "denied events" | PASS, yeniden deneme döngüsü yok |
| Gecikmeli metadata (başlıksız bildirim) | Matris 9 | PASS, tek yenileme |
| Uyku/uyanma (`recover`) | Matris 9 | PASS |
| Oynatıcı kapandı / uygulama çıkışı (`stop`) | Matris 9, 8 | PASS, izleyici ve görev kalmıyor |
| İki ekranda iki görünür süre çubuğu | MediaArtworkCheck | PASS |

### Canlı (test örneği, Spotify'a komut gönderilmeden)

- Pasif, 240 sn, panel açık + iğneli: 225 örnek, 1 doğal parça geçişi; panel yeni parçaya ≤1 örnek (≈1 sn) içinde geçti;
  1,5 sn'den büyük sapma yalnızca o geçiş anında 1 örnek. 4 dakikada 4 Apple Event (açılış yenilemesi, parça değişiminde
  kapak ×2, panel açılışında 1 konum).
- Kullanıcının oynatıcıda elle sarması, elle oynat/duraklat ve Music canlı denemesi bu turda yapılmadı (NOT_TESTED);
  önceki turda Music ve dış sarma canlı doğrulanmıştı (bkz. `SPOTIFY-PROGRESS-FIX-2026-10-15.md`).

## 4. Rakip ilkeleri

| İlke (kaynak) | Uygulama |
|---|---|
| No-op guard / idempotent eylem (Boring Notch) | `setPositionWatch` değişmeyen durumda iş yapmaz; izleyici kurulum/kaldırma idempotent |
| Single-flight, iptal, generation guard (Boring Notch RC) | Konum okuması tek görev; yeni bildirim/tıklama öncekini iptal eder; bayat sonuç yayınlanmaz |
| Görünürlüğe bağlı iş (Atoll panel yaşam döngüsü) | İzleyici yalnızca süre çubuğu görünürken; `.id(currentView)` kopyalanmadı (zaten `.id(tab)` var) |
| NotchNook/Alcove | Çalışma zamanı kanıtı yok, kullanılmadı |

Kod kopyalanmadı, özel API eklenmedi (tanılama derlemesindeki test kancaları ürüne girmedi).

## 5. Performans (A/B/B/A, K5F → K6C)

Uygulamanın kendi kontrollü benchmark'ı (`profile-rapid`, 480 seçim; `idle-compact` 305 sn), faz sınırında
`proc_pid_rusage`. Birincil ölçüt talimat/seçim; CPU %, ölçüm boyunca başka süreçlerin (iki python, Storage, ugrep
≈%100) yükü nedeniyle mutlak hedeflerle karşılaştırılamaz. Geçersiz koşular dışlandı.

| Faz | n (K5F/K6C) | Talimat/seçim | Çevrim/seçim | CPU % | Enerji tahmini/seçim | WindowServer % | Uyanma/s | Footprint |
|---|---|---|---|---|---|---|---|---|
| 80 ms | 4/4 | 202,7M → 201,5M (−%0,63, aralıklar örtüşüyor) | −%2,1 | 44,32 → 44,32 | −%3,1 | 41,9 → 42,4 | 106,8 → 106,4 | 54,1 → 53,2 MiB |
| 650 ms | 2/4 | 351,4M → 353,7M (+%0,63, aralıklar örtüşüyor) | +%3,6 | 17,6 → 18,0 | +%4,5 (geniş aralık) | 40,6 → 40,4 | 63,15 → 63,18 | 50,7 → 51,5 MiB |

| Kararlı durum | Talimat M/s | CPU % | Uyanma/s | Apple Event/dk | Not |
|---|---|---|---|---|---|
| Kompakt, Spotify çalıyor (K5F → K6C, n=2/2) | 3,29 → 4,02 | 0,15 → 0,20 | 2,1 → 3,05 | 0 | İki modlu: her iki sürümde bir düşük (1,2–2,6) ve bir yüksek (5,40 ↔ 5,41) koşu; Time Profiler 30 sn'de 6 örnek |
| Genişletilmiş, Medya paneli açık + iğneli, çalıyor (aday) | 6,4 | 0,35–0,46 | 1,5–2,0 | 0–1 | §3 ve H2 koşuları (n=6) |

- K5F'de 2 koşu "speed selection did not activate" ile geçersiz: ikisi de turun ilk koşusu ve ağır dış yük altında
  başladı; aynı hata önceki turda BASE'te de görüldü (1/23). Sürüme bağlı değil, kirli koşu olarak dışlandı.
- 80 ms'de %25 altı CPU hedefi bu turda da **ulaşılmadı** (değişiklikler hızlı sekme yolunu hedeflemiyordu; K5 kazancı
  korunuyor).
- GPU/enerji: yalnızca süreç enerji tahmini (`proc_pid_rusage`); GPU sayaçları ve Animation Hitches bu turda ölçülmedi.
  Değişiklikler çizim yolunu (görünümler, animasyonlar) değiştirmediği için önceki turun hitch sonucu geçerli kabul
  edildi, ancak bu tur için NOT_TESTED.

### Ek optimizasyon hipotezleri

| # | Hipotez | Ölçüm | Karar |
|---|---|---|---|
| H1 | Görünür panelde 1/2/5 sn doğrulama, sarmayı olaysız yakalar | §3 tablo: +%9 / +%52 / +%142 talimat, 11/29/57 Apple Event/dk, 0 düzeltme | **Reddedildi**; yerine olay güdümlü tıklama yolu |
| H2 | Medya panelindeki üç ayrı 1 Hz `TimelineView` (geçen, kalan, AX değeri) tek çizelgede + çubuk `Equatable` | Panel açık, çalıyor, A-B-B-A n=4/4: 6,36 → 6,35 M talimat/s, uyanma 1,55 → 1,57/s | **Reddedildi** (kazanç yok; yapı değişikliği riske değmez) |
| H3 | Kompakt halde Spotify çalarken kararlı durum maliyeti | Time Profiler 30 sn: 6 örnek (≈6 ms CPU, ≈%0,02) | Hedef yok; kompakt boşta zaten sıfıra yakın |
| H4 | Medya sekmesine her geçişte tıklama izleyicisinin kurulup kaldırılması hızlı geçişte maliyet ekler mi | 80 ms A/B/B/A (§5): talimat/seçim −%0,63 | Maliyet yok |
| — | `FocusBridge.invalidateKeyViewLoop` (önceki tur) | Hareket eden AppKit tabanlı görünümlerden; odak davranışını değiştirmeden kaldırılamıyor | Değiştirilmedi |

## 6. Testler

| Kapsam | Sonuç |
|---|---|
| `swift test` | 179 test / 28 suite PASS |
| `check-performance.sh` (ScriptedPlayer 8 senaryo + matris, MediaController kaynak değişimi dahil) | PASS |
| `check-controls`, `check-dock-previews`, `check-feedback`, `check-maintenance`, `check-space-presentation`, `check-system` | PASS |
| K5Checks (başlık kayması + animasyonlu eşdeğerlik, 2188 örnek, 0 uyuşmazlık) | PASS |
| TabIconTintCheck (K4; 70 durum, en kötü 1/255; Mikser/Pano özgün renk yolu korunuyor) | PASS |

## 7. PASS / FAIL / NOT_TESTED

| Alan | Durum |
|---|---|
| Klavye: kök neden (olay sırası günlüğü) | PASS |
| Klavye: kapanmış adanın key'i geri alması (dış tıklama 3, Escape 1) | PASS (eski 4/4 → yeni 0/4) |
| Klavye: Tab/Shift-Tab sırası (12+12, 3 koşu) | PASS, eskiyle birebir |
| Klavye: Notlar düzenleyicisine giriş/çıkış | PASS |
| Klavye: odak çalmama, bayat first responder kalmaması | PASS |
| Fareyle Notlar'a tıklayıp yazma (canlı) | NOT_TESTED (kod yolu değişmedi) |
| VoiceOver sesli gezinme | NOT_TESTED |
| Spotify: panel açık + iğneli + oynatıcı önde sarma (deterministik) | PASS |
| Spotify: aynı senaryo, Spotify çubuğuna gerçek tıklamayla canlı (2. tur) | PASS (0,72 / 0,76 sn) |
| Spotify canlı: oynat/duraklat, baştan başlatma (uygulama düğmesi), parça değişimi + toplam süre, kompakt sarma + açılış, ayrılınca düzelme | PASS (§9) |
| Spotify canlı: başka bir araçla (AppleScript) sarma/baştan başlatma, Spotify önde, tıklama yok | Bilinen sınır: sıfır sorguyla algılanamıyor; ayrılma/açılış/parça sonunda düzelir |
| Medya senaryo matrisi (14 satır, §3) | PASS |
| Canlı pasif parça geçişi ve doğruluk | PASS |
| Music canlı (bu tur) | NOT_TESTED — Music kütüphanesinde çalınacak parça yok (önceki tur PASS) |
| Uyku/uyanma canlı | NOT_TESTED (deterministik PASS) |
| 1/2/5 sn yoklama deneyi | Ölçüldü, ürüne alınmadı |
| H2 birleşik zaman çizelgesi | Ölçüldü, kazanç yok, ürüne alınmadı |
| 80 ms / 650 ms A/B/B/A | PASS (eşdeğer) |
| Kompakt boşta | PASS (eşdeğer, iki modlu gürültü) |
| `swift test` 179/28, tüm `check-*.sh`, K5Checks | PASS |
| K4 (sekme ikon tonu, Mikser/Pano renk istisnaları) ve K5 (sabit başlık, `headerRowShift`, iskelet, aynı yay) | PASS — dokunulmadı; K5Checks ve TabIconTintCheck geçti |
| Animation Hitches K5F ↔ K6C (3 tur, n=6/6) | PASS (eşdeğer, §9) |
| GPU sayaçları | NOT_TESTED (süreç başına GPU yüzdesi yok) |
| Uzun süreli RAM (3 koşu, 10–20 dk) | PASS — sızıntı yok; tek birikim SwiftUI `TextField` gözlemcileri (~60 B/Nook açılışı) |
| Kurulu uygulama, `main`, uzak depo, v0.1.0 | Değişmedi |

## 8. Commit'ler ve geri alma

| Commit | İçerik | Geri alma |
|---|---|---|
| `f62923c` | Kapanmış ada key odağını geri almaz | `git revert f62923c` |
| `69c44fe` | Görünür panelde oynatıcı tıklamasından sonra konum eşitlemesi | `git revert 69c44fe` |
| `a799df0` | Medya senaryo matrisi denetimleri (yalnızca denetim kodu) | `git revert a799df0` |
| `4df4507` | Spotify'ın sonradan düzelttiği süre + uygulama komutundan sonra tek okuma | `git revert 4df4507` |
| `dfac1bd` | Başlatıcı başlıklarını simgelerle aynı ömürde önbelleğe alma | `git revert dfac1bd` |
| `df8d552` | Yalnızca geliştirici: `OPENISLAND_BENCHMARK_PASSES` | `git revert df8d552` |

Kanıtlar özel klasörde (`OpenIsland-Evidence/20261015-k5k6/{kbtrace,pollexp,runs}`); kişisel medya/takvim metni içerir,
paylaşılmaz.

## 9. İkinci tur (17 Ekim): canlı testler, CPU ve RAM

### Canlı Spotify (kullanıcı izniyle AppleScript + Spotify çubuğuna gerçek tıklama; başlangıç durumu geri yüklendi)

| Senaryo | Önce (K6C) | Sonra (`4df4507`) |
|---|---|---|
| Panel açık + iğneli, Spotify çubuğuna tıklama (%25 / %70) | 0,70 / 0,71 sn | 0,72 / 0,76 sn |
| Oynat/duraklat (düğme) | 0,37 / 0,09 sn | 0,37 / 0,13 sn; duraklatınca süre donuk |
| Adanın "Önceki parça" düğmesiyle baştan başlatma | — | **0,73 sn** (önce düzelmiyordu: bildirim yok) |
| Parça değişimi ve geri dönüş (geçen + toplam süre) | **Toplam süre 6–7 sn yanlış kalıyordu** | 1,81 / 1,23 sn |
| Kompakt sarma, 12 sn sonra panel açılışı | — | 0,25 sn |
| AppleScript ile sarma/baştan başlatma, Spotify önde değil, tıklama yok | 15 sn içinde düzelmedi | Aynı (bilinen sınır); Spotify'dan ayrılınca 0,25 sn |

Kök neden (yeni süre hatası): Spotify yeni parçada önce bildirimdeki süreyi verir, ≈0,45–0,5 sn sonra gerçek süreyi
bildirimsiz düzeltir (3/3 parçada tam 6,286 sn fark; kontrol API'si de ilk anda eski değeri döndürür). Düzeltme: yeni ve
çalan Spotify parçasında 1,5 sn sonra tek okuma; konum + süre aynı Apple Event'te. Uygulamanın kendi medya komutlarından
sonra bildirim gelmezse tek okuma (kuşak komuttan önce eşzamanlı yakalanır; denetim bir yarışı yakaladı ve düzeltildi).
Parça başına 1, komut başına en çok 1 Apple Event; yoklama yok. Music: kütüphanede parça olmadığı için bu turda canlı
denenemedi.

### Animation Hitches (80 ms, 10 sn, A/B/B/A × 3, kirli koşu yok)

| | Kare/sn | Kare ömrü p50 | p95 | Hitch/sn | En uzun hitch |
|---|---|---|---|---|---|
| K5F | 57,87 [57,2–59,2] | 45,99 ms | 61,27 ms | 3,52 [3,04–3,90] | 25,0 ms |
| K6C | 57,25 [56,8–57,8] | 45,94 ms | 61,69 ms | 3,78 [3,44–4,46] | 30,5 ms |

Aralıklar örtüşüyor; eşdeğer.

### Hızlı sekme CPU: profil ve denemeler

Güncel aday profili (80 ms, 6 sekme): seçim başına ana thread →Notlar 44,5, →Pano 40,2, →Nook 34,9, →Raf 32,6, →Sistem
32,2, →Medya 23,8 ms. Bizim kodumuzun payı her biri %1'in altında; maliyet SwiftUI yerleşimi, CA commit ve odak işinde.

| Deney | Sonuç | Karar |
|---|---|---|
| Başlatıcı başlığı önbelleği (Notlar'da LaunchServices `displayName` %3,2) | notes↔nook −%0,94, 6 sekme −%0,62 talimat/seçim (n=4/4, aralıklar kısmen örtüşüyor) | **Kabul** (`dfac1bd`), görünüm/ipucu/AX etiketi aynı |
| X1: içerik çerçevesinin yerleşim animasyonunu kapatma (FocusBridge üst sınırı, yalnız tanı) | Talimat +%3,1 (daha kötü), görsel değişir | Ret — FocusBridge %10,6 bu yolla düşmüyor |
| Pano: 40 öğe × ortalama 10 KB metnin tek satırlık ölçümü (%28–30) | Önizleme kısaltma önceki turda 26 piksel fark verdi; sabit satır yüksekliği yedek fontlarda değişir | Tekrarlanmadı |
| ColorSync / RenderBox yol çizimi (%2–4), `.help` ipuçları (%2–3), `NSSlider` yerleşimi (%1,7) | Çerçeve içi veya özellik | Değiştirilmedi |

80 ms'de %25 altı CPU hedefi bu turda da **ulaşılmadı**. Kalan büyük kalemler (FocusBridge, metin dizgileme, yerleşim
animasyonu) görünümü veya animasyonu değiştirmeden azaltılamıyor; bu istemin yasakladığı bir ödünleşim.

### Uzun süreli RAM

| Koşu | Süre / seçim | Ayak izi |
|---|---|---|
| AX ile sürülen, K5F ve aday paralel | 20 dk / ~3500 | Her ikisinde doğrusal artış: 51,8 → 57,7 ve 51,7 → 59,2 MiB |
| Uygulama içi döngü (AX yok), 150 ms | 11 dk / 4200 | 50,4 → 55,0 MiB; malloc toplamı −1,6 MB (artış malloc dışı) |
| Uygulama içi döngü + `vmmap`, 150 ms | 7,5 dk / 3000 | **Kararlı**: 49,2 → 51,0 → 49,5 MiB |

`heap` + `MallocStackLogging` ile tek doğrulanmış birikim: SwiftUI'nin Nook'taki "Yeni anımsatıcı" `TextField`'ı pencereye
her takıldığında eklediği `NSNotificationCenter` gözlemcileri (`AppKitTextField.viewDidMoveToWindow →
AppKitTextInputSource.updateObservation`); metin alanı nesneleri birikmiyor. Boyut ≈60 bayt/Nook açılışı (4200 seçimde
≈0,25 MB); çerçeve davranışı. Ayak izindeki artış her koşuda görülmüyor ve tabanda da var; sızıntı olarak doğrulanmadı.
