# OpenIsland — Gerçek medya, kaynak ölçümü ve güvenli yerel düzeltmeler

**Tarih:** 13 Ekim 2026 · **Genel kabul kararı: NEEDS_FIXES**

Bu karar uygulamanın bozuk olduğu anlamına gelmez: bütün modlarda minimum gerçek enerji, görsel eşdeğerlik ve uzun dönem kararlılık kriterlerini henüz kanıtlayamıyoruz. Aşağıdaki lokal doğruluk/yaşam döngüsü düzeltmeleri incelemeye hazırdır; bunlar için toplam pil tasarrufu veya sıfır regresyon garantisi verilmez.

## 1. Çalışma sınırı ve geri dönüş

- Yerel depo: `/Volumes/HIKSEMI/proje/OpenIsland-local-dev`
- Dal: `local/real-media-validation-20261013`
- Başlangıç: `de051c6f47130bedaf51fec7cad5d226dca40cb3`
- Kod/test commit'i: `c245369561bd10ff7bd9dadecba4404cc7818e8d`
- Deney kanıtları: `/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261013-real-media-validation`
- Kaynak yedeği: `/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261013-real-media-validation/source-before.tgz`
- Son takipli diff yedeği: `/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261013-real-media-validation/local-final-tracked.patch`

Kurulu `/Applications/OpenIsland.app` üzerine derleme/kopyalama yapılmadı. Deney sırasında normal uygulama kapatılıp ayrı imzalı aday çalıştırıldı; sonunda normal uygulama yeniden açıldı. GitHub'a push, yeni release, production main değişikliği yapılmadı. `/Volumes/HIKSEMI/proje/OpenIsland` içindeki önceden mevcut kirli çalışma ağacı değiştirilmedi veya geri alınmadı; temiz olduğu iddia edilmiyor.

Kurulu executable'ın önce/sonra SHA256 değeri aynı:

`269566c7ecd427ed3a0024851c82fec23c8792c61d163a047dfd7efa740fc5de`

Deneylerde kullanıcı support dosyalarının kopyaları ve ayrı defaults suite kullanıldı. Production tercih plist'i ilk kayıtla semantik olarak aynı çıktı. Spotify ses seviyesi değiştirilmedi. Son testin oynat/duraklat restorasyonunda test sürücüsünün asenkron `play track` / `pause` sırası yarıştı; bu ölçüm sonrası test altyapısı sorunu görüldü, duraklatma ve konum açıkça geri yüklenip tekrar doğrulandı. Son doğrulanmış durum başlangıçtaki aynı parça, aynı konum ve duraklatılmış durumdur. Özel medya adları/support kopyaları kanıt klasöründe tutuldu; Git commit'ine alınmadı.

Yerel değişiklikleri geri almak gerektiğinde bu dalı silmek veya kullanıcı değişikliklerini resetlemek yerine, ayrı temiz bir dalda yukarıdaki kod commit'ini `git revert` ile geri alın. Kurulu uygulama zaten eski sürümde kalmıştır.

## 2. Ölçüm güvenilirliği

### Doğru süreç ve binary

Her koşuda PID, `proc_pidpath` executable yolu, binary SHA256, süreç başlangıç kimliği ve sayaç yöntemi kaydedildi. Sayaç sıfırlanması, süreç/kimlik/yöntem değişmesi, eksik veri ve geçersiz süre `N/A` üretir; sıfır CPU olarak sunulmaz.

- İlk gerçek medya koşusu: aday PID 63764, `/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261013-real-media-validation/Validation.app/Contents/MacOS/OpenIsland`.
- Son sessiz koşu: aday PID 73888, `/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261013-real-media-validation/quiet-complete/Validation.app/Contents/MacOS/OpenIsland`.
- WindowServer: PID 405, `/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer`.

CPU, örneklerin anlık `%CPU` ortalaması değil, kümülatif süreç CPU zamanının geçen süreye bölünmesidir. Yüzdeler **bir çekirdek ölçeğinde** süreç CPU yüzdesidir. Bunlardan doğrudan batarya tüketimi hesaplanmaz. Mach sayaç dönüşümü mevcut kalibrasyon testleriyle doğrulandı.

### WindowServer'daki eski %0,0 neden geçerli değil?

Yetkisiz `proc_pid_rusage` WindowServer için `EPERM`/errno 1 döndürüyor. Eski sıfır değerler güvenilir karşılaştırma tabanı kabul edilmedi. Yeni bağımsız ölçüm, erişilemeyen rusage yerine `ps TIME` kümülatif sayacını kullanır; çözünürlük **10 ms**. Ham `ps` metni ve başlangıç/bitiş sayacı kanıtta bulunur. Bu sayaç da okunamazsa `N/A` olur.

Yeni koşularda WindowServer sıfır değildir. Ancak bu **WindowServer'ın tamamının CPU'sudur**; OpenIsland'e özel GPU/WindowServer payı değildir. Diğer pencereler, sistem ve ölçüm araçları da katkıda bulunabilir. WindowServer CPU'sunu GPU yüzdesi veya OpenIsland enerji tüketimi diye sunmuyoruz.

### Spotify / TCC / MediaRemote

Gerçek Spotify distributed notification olayları teslim edildi. Apple Events üzerinden parça/kapak/süre okuma, oynat/duraklat ve OpenIsland'in seek kontrolü çalıştı; bu işlemler için mevcut erişimin işlediği doğrulandı. TCC veritabanı değiştirilmedi, izin sıfırlanmadı.

Bu sistemde doğrudan MediaRemote okuma yolu etkin değildi. Başarılı Spotify testi, **distributed notification + Apple Events fallback** kanıtıdır; doğrudan MediaRemote tesliminin veya diğer medya kaynaklarının doğrulanması değildir.

## 3. Gerçek medya doğruluğu ve bulunan hata

### Spotify süre tutarsızlığı — yerelde düzeltildi

Üç farklı gerçek parçada distributed notification süresi Spotify kontrol API'sinin süresinden yaklaşık **6,286–6,287 saniye** fazla çıktı. Seek sonrasında kontrol API'si kullanıldığında gösterilen toplam süre değişebiliyordu. Spotify'ın iki veri yolunun neden farklı olduğu kanıtlanmadı; SwiftUI veya polling kaynaklı olduğu söylenmiyor.

Yeni parçada zaten yapılan tek kapak Apple Event'i, kapak URL'si **ve süreyi birlikte** getiriyor. Pozitif/sonlu kontrol API süresi aynı parça anahtarıyla cache'leniyor; aynı-parça duraklatma olayının farklı süresi bu doğrulanmış değeri ezmiyor. Yeni periyodik sorgu veya ek Apple Event eklenmedi. Diğer oynatıcıların artwork sorgusu korunuyor.

Gerçek adayda üç ardışık parça için başlık, sanatçı, decode edilmiş kapak ve kontrol API süresi eşleşti. Üç kapak hash'i birbirinden farklıydı. OpenIsland kontrol yoluyla 45 ve 10 saniyeye seek yapıldı: Spotify yaklaşık 45,55 / 10,56 s, model sonraki örnekte yaklaşık 45,91 / 10,91 s gösterdi ve ilerlemeye devam etti. Örnekler eşzamanlı olmadığı için bu fark sıfır gecikme iddiası değildir.

İlk sürücüde dışarıdan doğrudan Spotify seek'i ayrıca denendi. O yoldan olay teslimi görülmedi ve modelin extrapolated progress'i güncellenmedi; bu **OpenIsland'in kendi seek kontrolünün testi sayılmadı**. Sonra gerçek OpenIsland kontrol yolu ayrıca başarıyla doğrulandı.

### Waveform / compact / expanded

- Çalarken gerçek view katmanlarında 5 `pulse` animasyonu görüldü.
- Duraklatıldıktan sonra 0 `pulse` animasyonu görüldü.
- Compact ve expanded durumları model kaydı ve view/layer tanıklarıyla ayrıldı.
- Expanded ölçümde kullanıcıdaki mevcut pin davranışı kullanıldı; test sonunda önceki pin/sekme geri alındı.
- Kamera idle ve aktif ses rotası sayısı 0 kaldı; donanım özellikleri sessizce aktive edilmedi.

İlk pinsiz seek deneyi sırasında ada kapandığı için o koşu expanded UI kanıtı olarak reddedildi; düzeltilmiş test koşuluyla yeniden çalışıldı. Tanık kayıtları gerçek davranışın kanıtıdır, screenshot/piksel eşitliği veya FPS ölçümü değildir.

Kanıt: `/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261013-real-media-validation/metadata-seek/functional-validation.json`.

## 4. Medya CPU / RAM / WindowServer sonuçları

### İlk ayrıntılı gerçek medya koşusu — düzeltme öncesi

Bu koşuda saniyede bir SHA256 ve atomik tanı logu yazıldı. Aşağıdaki değerler **enstrümante süreç değerleridir**, normal ürünün boşta alt sınırı değildir. Her fazın ilk 3 saniyesi kararlı sayaç karşılaştırmasından çıkarıldı.

| Durum | Aday CPU | WindowServer toplam CPU | Son physical footprint | Kararlı ölçüm aralığı |
|---|---:|---:|---:|---:|
| Çalıyor, compact | %0,125 | %11,117 | 37,30 MiB | 58,92 s |
| Çalıyor, expanded | %0,297 | %11,705 | 40,69 MiB | 42,72 s |
| Duraklatılmış, compact | %0,231 | %7,973 | 40,42 MiB | 27,47 s |
| Duraklatılmış, expanded | %0,133 | %8,008 | 41,28 MiB | 27,47 s |
| Parça / seek fazı | %0,404 | %10,641 | 44,30 MiB | 42,10 s |
| Kesintisiz compact oynatma | %0,135 | %11,377 | 43,99 MiB | 183,80 s |

Kesintisiz fazın gerçek duvar süresi yaklaşık **188 saniye / 3 dakika 8 saniye**. Footprint farkı bu aralıkta -24 byte idi; bu bellek sızıntısı olmadığına dair uzun dönem kanıt değildir. Toplam gerçek medya akışı yaklaşık 7 dakikalık sınırlı bir koşudur; bütün gün/8 saat testi yapılmadı.

Kanıt: `/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261013-real-media-validation/media-analysis.json`.

### Son düşük tanı yükü koşusu — yerel aday

İlk sessiz koşu kullanıcı kesintisiyle eksik kaldı; kabul edilmedi. Yeniden tamamlanan koşuda faz başı/sonu **iki uygulama içi tanık** var, saniyelik uygulama içi SHA/log döngüsü yok. Dış sürücü süreçleri saniyede bir örnekledi. Mevcut waveform/progress/ürün görevleri kapatılmadı.

| Durum | Aday CPU | WindowServer toplam CPU | Son physical footprint | Kararlı ölçüm aralığı |
|---|---:|---:|---:|---:|
| Çalıyor, compact | %0,133 | %11,959 | 36,11 MiB | 28,43 s |
| Çalıyor, expanded | %0,245 | %15,335 | 40,30 MiB | 28,43 s |
| Duraklatılmış, compact | %0,746 | %19,765 | 42,47 MiB | 26,41 s |
| Duraklatılmış, expanded | %0,332 | %16,372 | 43,42 MiB | 26,38 s |

Faz başı/sonu gerçek süreleri yaklaşık 30–32 saniye. Faz başlangıcı play/pause olayını da içerir; son tanıkların tamamında beklenen kaynak, durum, artwork ve pulse sayısı doğrulandı. Faz içindeki bütün ara UI kareleri kaydedilmedi. Sürücünün miras kalan `seconds_requested=180` etiketi 4×30 s planıyla tutarsızdı; manifest'te eski etiket saklanarak 120 olarak düzeltildi. Gerçek zamanlar log/sayaçtan hesaplandı.

Bu koşu ilk ayrıntılı koşuyla farklı sistem zamanında çalıştı ve duraklatılmış değerler daha yüksek çıktı. **Az tanı kaydı = kanıtlanmış ürün CPU kazancı** denmiyor; iki tablo A/B karşılaştırması değildir. %2,49'luk önceki özel yükseliş bu koşulda tekrar üretilmedi. %0,746'nın kökü eşzamanlı stack/signpost korelasyonu olmadan Spotify'a, SwiftUI'ye veya timer'a bağlanmadı. Sürekli sıfır CPU garantisi yoktur.

Kanıt: `/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261013-real-media-validation/quiet-complete/analysis.json`.

## 5. Aynı koşulda A/B/B/A sekme karşılaştırması

A: başlangıçtaki ürün davranışı. B: yerel düzeltmeler. İkisinde aynı ölçüm/isolation kodu, aynı başlangıç Spotify parçası/konumu, aynı fixture tercihleri, aynı altı sekmeli mevcut benchmark vardı. Her koşuda 54 normal seçim (650 ms aralık) ve 90 hızlı seçim (80 ms aralık), 3 tur ve aynı warm-up kullanıldı. Benchmark'ın kontrollü/demo hold koşulu gerçek doğal hover/idle ile aynı değildir. Animasyon süreleri ve FPS değiştirilmedi. Ağır derleme bu ölçümlerle birlikte çalıştırılmadı.

Son ürün düzeltmesi sonrası A/B/B/A sonucu:

| Ölçüt | A ortalama | B ortalama |
|---|---:|---:|
| Normal sekme CPU | %13,992 | %13,661 |
| Normal seçim başına CPU işi | 94,743 ms | 92,771 ms |
| Hızlı sekme CPU | %28,353 | %28,698 |
| Hızlı seçim başına CPU işi | 24,077 ms | 24,319 ms |
| WindowServer toplam CPU (koşu genelinde) | %26,493 | %26,063 |
| Son footprint, iki koşu | 53,67 / 50,03 MiB | 49,09 / 49,38 MiB |

Normaldeki küçük düşüş hızlı seçimde tekrarlanmadı; koşuların CPU aralıkları örtüşüyor. RAM farkı da iki örnekle leak/batarya kazancı kanıtı değildir. **Tutarlı toplam CPU veya enerji kazanımı kanıtlanmadı.** Bu farklar ürün optimizasyon başarısı olarak kabul edilmedi.

Süre düzeltmesinden önce ayrıca A/B/B/A yapıldı: normal A %14,041 / B %13,658; hızlı A %28,937 / B %27,943. Son koşuyla birlikte değerlendirilince yine tek yönlü tekrarlanabilir kazanım yok. İki geçerli seride toplam 1152 programatik sekme seçimi yapıldı. İlk yarıda kalan parser hatalı koşu karşılaştırmadan çıkarıldı.

Eski yaklaşık %5,78 değeri bu medya/sistem/benchmark koşuluyla eşdeğer değildir. Bunun üstündeki yeni değerler tek başına kod regresyonu veya artışı Spotify kaynaklı diye ilan edilmedi. Yeni %5 hedef başarısı da ilan edilmedi.

Kanıt: `/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261013-real-media-validation/abba-metadata-summary.json` ve aynı klasördeki dört `abba-metadata-*/result.json` ham örnekleri.

## 6. Enerji / GPU / wakeup sınırları

- Güncel `powermetrics` denemesi yönetici yetkisi olmadan sonuç vermedi: `sudo: a password is required`.
- Uygulamaya özel GPU zamanı/yüzdesi, joule/watt, pil Wh farkı ve Energy Impact: **N/A**.
- WindowServer CPU'su yukarıda ölçüldü, fakat süreç yükünü başka yere taşımak enerji kazanımı sayılmadı.
- rusage `package_idle_wakeups` farkı kararlı aralıklarda 0 idi. Bu **toplam wakeup, interrupt veya GPU uyanması sıfır** demek değildir; diğer türler N/A.
- Kısa CPU tepelerinin dağılımından bütün gün batarya ömrü çıkarılamaz.
- Gerçek sensör testinde görünen sistem GPU yüzdesi ve toplam RAM, OpenIsland'e ait ölçüm değildir.

## 7. Gerçekten entegre edilen yerel düzeltmeler

### Kısa yollar / Notes içindeki LauncherStore

Önceki yol başarısız `shortcuts list` sonucunu başarılı boş liste gibi 5 dakika cache'leyebiliyordu; bekleyen CLI için deadline yoktu. Artık:

- Gerçek başarılı boş liste ve hata ayrılıyor; hatada son iyi liste korunuyor.
- Mevcut single-flight korunuyor; 100 eşzamanlı katılım tek fetch yapıyor, yalnızca sahibi yayımlıyor.
- Gerçek hatada 10 saniyelik **olay tetiklemeli** backoff var; sürekli retry timer yok. Manuel yenileme backoff'u aşabiliyor.
- Generation guard eski completion'ın yeni sonucu ezmesini engelliyor.
- Uygulama kapanışı store-owned task/CLI'ı iptal ediyor.
- Sadece aktif CLI için tek seferlik 10 saniye deadline var; SIGTERM'i yok sayan kendi subprocess'i için sınırlandırılmış sonlandırma var. Boşta veya sekme her kapanışında yeniden CLI başlatılmıyor.

Testler: launch/exit/UTF8 hata ayrımı, başarılı boş cache, manuel retry, hata koruma, 100 join, shutdown/stale completion ve SIGTERM'i yok sayan gerçek fixture process'i. Bunlar doğruluk ve olası gereksiz iş önleme düzeltmeleridir; gerçek kullanıcı kısa yol yükünde enerji tasarrufu nicelenmedi.

### System ve Mirror görünürlük sahipliği

Aynı shared servisi kullanan iki panelde biri kaybolunca diğer görünür panelin de servisi durabiliyordu. Panel görünürlük sayacı ilk görünümde başlatıp son görünümde durduruyor; underflow/reopen test edildi. System observer/task ve camera session çoğaltılmıyor. Normal tek panel davranışı, explicit start/stop/recovery ve shutdown korunuyor.

İki viewer aynı anda, birini kapatma, sonunu kapatma ve yeniden açma fake backend ile geçti. Fiziksel iki ekran/kamera doğrulaması yapılmadı. Bu değişiklik varsayılan tek görünüm için performans yüzdesi kazanımı iddiası değil, çoklu görünümde yanlış durma/yeniden başlama riskine karşı lokal düzeltmedir.

### Ölçüm altyapısı

Bağımsız kimlik kontrollü süreç probe'u, eksik sayaç için N/A, WindowServer ps fallback ve opt-in gerçek medya/seek/sessiz testleri eklendi. Test support/defaults yönlendirmesi yalnızca diagnostics açıkken çalışır; normal ürün çalışma yolları değişmez. Python yardımcı süreçleri uygulamanın production mimarisine eklenmedi; yalnızca geliştirme test araçlarıdır.

## 8. Dokuz sekme ve test kapsamı

| Alan | Bu turdaki kanıt | Sonuç / sınır |
|---|---|---|
| Nook | Runtime sekme hedefi; Reminders/Calendar izin, visibility ve observer fixture kontrolleri | PASS kontrollü kapsam; gerçek hatırlatıcı etkileşimleri bütünü NOT_TESTED |
| Media | Gerçek Spotify metadata/kapak/play/pause/seek/katman; aynı artwork tekrar kullanım testleri | PASS Spotify; diğer kaynak geçişleri NOT_TESTED |
| Shelf | Gerçek named pasteboard/file provider fixture, dosya adı/byte korunumu, zip/unzip/hata | PASS fixture; fiziksel notch sürükleme uçtan uca NOT_TESTED |
| Clipboard | Runtime sekme; 2000 değişmeyen kontrol, 1000 tekrar kopyada yazma/notification guard | PASS kontrollü kapsam |
| Focus | Yedi sekmeli runtime seçiminde var; timer başlatılmadı | UI model hedefi PASS; gerçek odak oturumu NOT_TESTED |
| Notes | Runtime sekme; Launcher single-flight/hata/iptal/boş sonuç testleri | PASS; native köprü TextEditor selection/focus eşitliği NOT_TESTED |
| Mirror | İki-viewer sahipliği; blocked configure, hata recovery, 200 hızlı cycle fake backend | PASS fixture; gerçek camera capture NOT_TESTED |
| Mixer | Ses aygıtı/listener math ve 100 panel lifecycle; varsayılanda capture/route yok | PASS kontrollü kapsam; güncel Chrome canlı route NOT_TESTED |
| System | Runtime ve gerçek hardware okumaları; iki-viewer/observer task fixture | PASS bu kapsam; fiziksel ekran değişimi NOT_TESTED |

Yedi sekmeli gerçek medya koşusunda Nook, Media, Shelf, Clipboard, Focus, Notes, System model hedefleri normal/hızlı seçimlerde kontrol edildi. Mirror ve Mixer sessizce eklenmedi; bu iki sekme gerçek capture yapmadan fixture ile test edildi. Altı sekmeli A/B benchmark ayrı ölçümdür; dokuz canlı donanım sekmesi ölçümü olarak sunulmaz.

Ek kontroller:

- **172 Swift test / 27 suite: PASS.** Bunlar tüm OS/UI senaryolarının testi değildir.
- Release build: PASS.
- Performance integration checks: PASS; yeni process probe için 6 Python test dahil.
- System: 1000 CPU + 1000 memory okumasında host port hakları stabil; 400 sensor aç/oku/kapat sonrasında 147456 byte büyüme gözlendi. Bu tek başına leak sınıflandırması değildir.
- Dock: mocked izin/lifecycle, 100 enable/disable, tam 2 monitor / 7 observer sonra 0; 10000 idle dismissal ve iç pointer olayında ek AX/window/capture okumaması PASS. Bu turda gerçek Dock A/B veya görsel önizleme doğrulaması yapılmadı.
- Controls: 100 panel cycle, listener sayısı stabil ve kapanışta temiz; canlı kırmızı düğme testi aktif quit monitor çakışmasını önlemek için **SKIP** edildi.
- Feedback: çoklu dosya temsilinde ad/byte korunumu, hata temizliği ve session dedup PASS.
- Spaces/fullscreen: kontrollü geometri/observer/fullscreen fixture PASS; gerçek trackpad, fiziksel uyku/uyanma ve ekran kablosu NOT_TESTED.
- Maintenance: fake home/update kaynakları ve 100 aç/kapa lifecycle PASS; gerçek app silme veya güncelleme uygulanmadı.
- Settings: persisted tercih testleri PASS; bütün gerçek ayar kontrolleriyle manuel UX turu NOT_TESTED.
- Canvas: mevcut path/hit-region ve ara morph değerleri matematiksel kontrolleri PASS; screenshot pixel eşitliği veya compositor FPS testi NOT_TESTED.

Test harness idle değerleri uygulamanın idle değeri diye raporlanmadı. Loglar özel kanıt klasöründeki `check-*.log`, `swift-test-final.log`, `build-quiet.log` dosyalarında.

## 9. Bilerek korunan işler / uygulanmayan değişiklikler

- Orijinal statik MediaPanel başlığı, TabButton Equatable, Dock URL normalizasyonu, Core Animation waveform, notch #000000, geometri, spring süreleri ve hover ayarları değişmedi.
- Equatable tab closure ve namespace mevcut çağrılarda sabit model/kimliğe bağlı: kaynak incelemesinde güncel bir bozukluk gösterilmedi. **Keyboard focus ve gerçek VoiceOver ağacı eşdeğerliği henüz kanıtlanmadı.**
- Native hibrit köprü bu tura production alternatifi olarak alınmadı. Notlar geometri/metin/focus/selection, dış rootView parametreleri, cache lifecycle ve animasyon ara kareleri için eksik eşdeğerlik kanıtını bu rapor kapatmıyor.
- Marquee ana MediaPanel'e eklenmedi; efekt, blur, çizim eksiltme, FPS düşürme ve animasyon yavaşlatma uygulanmadı.
- Yeni sürekli idle timer/polling eklenmedi. Gerekli Focus deadline, sadece görünür System sensör örnekleme ve çalarken görünür progress güncellemesi korunuyor; bunları kapatarak sahte kazanç elde edilmedi.
- Shelf thumbnail callback'inin kaldırılmış öğeye ait cache'i sonradan yeniden doldurabilmesi kaynak incelemesinde potansiyel risk olarak görüldü. Bu turda yeniden üretim/maliyet ölçümü ve güvenli düzeltme testi tamamlanmadığı için değiştirilmedi; kanıtlanmış leak diye sunulmaz.
- Normal/hızlı sekme A/B farkı tutarlı olmadığı için bunu CPU optimizasyon başarısı sayma yaklaşımı reddedildi. Başarısız native deney production'a taşınmadı.

## 10. Değişen dosyalar

Kod commit'inde 16 dosya (538 ekleme / 36 silme; önemli bölümü test ve diagnostics):

- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Scripts/check-performance.sh`
- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Scripts/process-matrix-probe.py`
- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Sources/OpenIsland/App/AppEnvironment.swift`
- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Sources/OpenIsland/Features/Media/ScriptedPlayerSource.swift`
- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Sources/OpenIsland/Features/Mirror/CameraMirror.swift`
- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Sources/OpenIsland/Features/Notes/NotesStore.swift`
- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Sources/OpenIsland/Features/System/SystemMonitor.swift`
- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Sources/OpenIsland/Features/System/SystemPanel.swift`
- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Sources/OpenIsland/System/IslandDiagnostics.swift`
- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Sources/OpenIsland/System/Preferences.swift`
- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Sources/OpenIsland/System/Utilities.swift`
- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Tools/PerformanceChecks/CameraCheck.swift`
- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Tools/PerformanceChecks/ScriptedPlayerCheck.swift`
- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Tools/PerformanceChecks/ProcessMatrixProbeCheck.py`
- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Tools/PerformanceChecks/ShortcutsCheck.swift`
- `/Volumes/HIKSEMI/proje/OpenIsland-local-dev/Tools/SystemChecks/SystemMonitorCheck.swift`

Son test edilmiş developer executable: `/tmp/openisland-media-validation-build/release/OpenIsland`. İmzalı son tanı adayı: `/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261013-real-media-validation/quiet-complete/Validation.app`. Kurulu sürüme geçiş yapılmadı; kullanıcı onayı ve normal production ayarlarıyla paketleme/son görsel-donanım kontrolü gerekir. Bu artifact'lar yayımlanmış release değildir.

## 11. Kalan kabul engelleri ve teslim kararı

**Yerelde entegre / incelemeye hazır:** Spotify süre cache doğruluğu, Launcher failure/single-flight/shutdown, System/Mirror ortak viewer sahipliği ve güvenilir ölçüm araçları.

**Henüz kabul edilmiş enerji optimizasyonu değil:** karışık sekme CPU farkları, farklı zamanlardaki idle tabloları, daha düşük process CPU'nun GPU/WindowServer/pil maliyeti karşılığında elde edilip edilmediği.

**Eksik doğrulamalar:** yetkili GPU/enerji ölçümü ve uygun açık/kapalı karşılaştırması; uzun süreli soak; canlı çoklu ekran/kamera/ses route; diğer medya kaynakları; uyku/uyanma; gerçek keyboard/VoiceOver; screenshot ve animation ara kare/FPS eşdeğerliği; gerekirse pause sonrası yükselişi eşzamanlı stack/olay korelasyonuyla yeniden üretme.

Bu nedenle tüm uygulamaya yönelik “en düşük gerçek pil tüketimi + eksiksiz eşdeğerlik” kabulü **NEEDS_FIXES**. Güvenli yerel düzeltmeler kaydedilmiş, test edilmiş ve geri alınabilir durumdadır. Kurulu uygulama/GitHub yayımlaması **bu raporla onaylanmış değildir**; mevcut sürüm korunmuştur.
