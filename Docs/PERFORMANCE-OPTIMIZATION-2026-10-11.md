# OpenIsland — performans ve enerji doğrulaması, 11 Ekim 2026

## Kapsam ve kaynak

Yetkili kaynak: kullanıcının scratch-workspace içindeki OpenIsland projesi,
HEAD `8aabe5cc2c446c1fa25dd529914999c42865ed07`.
Kullanıcının sensör filtresi, 1,5 saniyelik yeniden açılış önbelleği, sekme boyut
optimizasyonu ve singleton framework yükleme değişiklikleri korundu.
UI, notch geometrisi, hover süresi ve üretim animasyon eğrileri değiştirilmedi.
Hiçbir özellik performans sayısını düşürmek için kapatılmadı.

Cihaz: Mac16,13 / Apple M4, 10 CPU çekirdeği, 16 GiB RAM,
macOS 27.0.1 (26A434), arm64 release, OpenIsland Local Signing.

## Uygulanan lokal düzeltmeler

- CPU/GPU/bellek okumaları seri, isteğe bağlı bir actor'a; sıcaklık okuyucusu
  ayrı seri actor'a taşındı. Sensör I/O'su artık UI ana iş parçacığında değil.
  Actor'ların kendi timer/polling döngüsü yok.
- Tek örneklemenin public ve private değerleri toplanıp aynı main-actor
  dönüşünde yayımlanıyor. Değişmeyen değerler yeniden yazılmıyor.
- Panel kapanması veya private ayarın değişmesi sırasında tamamlanan eski
  okumaların UI'a yazılması generation/revision kontrolüyle engelleniyor.
  Başlamış private çağrının crash-guard temizliği iptal sonrası da tamamlanıyor.
- Depolama, panel girişinde 250 ms sonra tek kez ve gerçek volume olaylarında
  yenileniyor; hızlı gir/çık okuması iptal ediliyor. Sürekli disk taraması yok.
  Yarım kalmış, tanımsız storage zaman damgası satırı kaldırıldı.
- Kullanıcının DisplayServices/CoreBrightness singleton yüklemeleri korundu:
  kontrolün yeniden oluşturulması ek dlopen referansı biriktirmiyor.
- Dock item subrole/URL/position/size için dört AX attribute IPC sorgusu
  tek `AXUIElementCopyMultipleAttributeValues` sorgusunda toplandı.
  Güncel hit-test/ikon geometrisi korunuyor; yeni pointer timer'ı yok.
- Uygulama aktivasyonu/sonlanması, geciken fullscreen çıkış doğrulamasını
  yarıda bırakırsa mevcut güvenli doğrulama tamamlanıyor. Bu olay sınırlı
  retry'dır; boşta fullscreen sorgusu eklenmedi.
- Geliştiriciye özel performans sürücüsüne normal/hızlı sekmeler ve gerçek
  medya durumunu kaydetme senaryoları eklendi. Sadece environment flag ile
  çalışır, normal açılışta aktif değildir.
- Dock canlı testi, kilit ekranını artık başarısız pencere testi gibi
  yorumlamadan açıkça SKIP eder.

## Kritik ölçüm düzeltmesi

Eski `Scripts/resource-probe.py`, `proc_pid_rusage` CPU sayaçlarını nanosecond
kabul ediyordu. ARM üzerinde Mach absolute tick → ns dönüşümü gerekiyor.
Bu Mac'te `mach_timebase_info` oranı **125/3**; eski yüzdeler yaklaşık
**41,67 kat düşük** görünüyordu. Uygulama tüketiminin arttığı değil,
ölçümün düzeltildiği anlamına gelir.

Betik artık ham tick ve timebase'i kaydeder, tam sayılı dönüşüm yapar.
Intel 1/1, ARM 125/3, büyük sayaç hassasiyeti ve bağımsız
`getrusage` CPU süresi karşılaştırması testleri eklendi.
Eski ham dosyalar korundu; yeniden hesaplanan dosyalar ayrı adla yazıldı.
Eski belgelerdeki doğrulanmamış CPU yüzdeleri artık geçerli kanıt olarak sunulmuyor.

Yöntem:
- CPU %100 = bir çekirdek; çekirdek sayısına bölerek kesin enerji çıkarılamaz.
- Zirveler yaklaşık 250 ms örnekleme aralığının ortalamasıdır, anlık frame zirvesi değildir.
- Bellek süreç physical footprint'idir; bütün Mac'in RAM kullanımı değildir.
- `ri_pkg_idle_wkups` bir enerji/GPU yüzdesi değildir.
- CPU karşılaştırmaları sırasında Instruments çalıştırılmadı.
- Disk cache, şarkı değişimleri, başka uygulamalar ve ekran kilidi sonuçları etkiler.

## Karşılaştırmalı CPU sonuçları

### İlk uzun medya testi: açık masaüstü, farklı şarkılar

Bu koşullar birebir sabit değildir. Sonraki atomik yayınlama iyileştirmesinden
önceki yeni kodun ölçümüdür; nihai sürümün kontrollü karşılaştırması sayılmaz.

| Senaryo | Önce ort. CPU | Ara sürüm ort. CPU |
|---|---:|---:|
| Aç/kapa, 40 çevrim | %15,983 | %19,489 |
| Statik expanded, 30 sn | %0,176 | %0,206 |
| Sistem paneli, 20 sn | %1,055 | %1,367 |
| Normal sekme geçişi | %16,705 | %21,135 |
| Hızlı sekme geçişi | %34,950 | %35,479 |
| Medya paneli, 20 sn | %0,790 | %0,944 |
| Kapalı ada + müzik, 60 sn | %0,009 | %0,342 |
| Tüm 200 sn aktif test ortalaması | %4,580 | %5,591 |

Son satır idle değildir. Bu sonuçlarla genel CPU kazancı iddia edilmiyor.
Idle bölümündeki ara sürüm zirvesi %17,473 olduğundan olay/track değişimi
olmayan koşulda ayrıca doğrulama gerekiyor.

### Son tekrar: Mac kilitli — görsel kullanım kanıtı değildir

Mac 15:34:25'te kilitlenmişti. 15:35 ve 15:39 tekrarları kilitliyken yürüdü.
Sürücü state değişikliklerini doğruladı fakat bunlar açık masaüstündeki
compositor/hover davranışının yerine geçmez. Farklı Spotify şarkıları devam etti.

| Senaryo | Önce ort. CPU | Son tekrar ort. CPU | Önce / sonra 250 ms tepe |
|---|---:|---:|---:|
| Aç/kapa, 20 çevrim | %20,885 | %20,989 | %31,868 / %32,504 |
| Statik expanded, 10 sn | %0,799 | %0,535 | %14,351 / %12,544 |
| Sistem paneli, 12 sn | %2,194 | %1,780 | %47,678 / %32,299 |
| Normal sekmeler | %24,306 | %25,312 | %49,731 / %45,374 |
| Hızlı sekmeler | %44,786 | %44,278 | %53,050 / %50,283 |
| Medya paneli, 12 sn | %1,310 | %1,024 | %26,121 / %21,023 |
| Kapalı ada + müzik, 40 sn | %0,006 | %0,001 | %0,327 / %0,108 |

Son tekrar sonunda physical footprint **50,74 MiB**, önce **50,84 MiB**.
125 sn toplam ortalama önce %6,850, sonra %6,946. Toplam wakeup önce 1439,
sonra 1505. Bu tablo da tüm tüketimin azaldığını kanıtlamaz.
Açılış/ilk panel yüklemesi sonrası bellek artışı tek başına leak kanıtı değildir.

### Kurulu son sürüm, normal açılış (test sürücüsü kapalı)

Uygulama `/Applications/OpenIsland.app` yolundan, diagnostic flag olmadan açıldı.
Spotify devam ederken ve masaüstü **kilitliyken** alınan 60,01 sn ölçüm:

- Ortalama CPU: **%0,2266**; en yüksek yaklaşık 250 ms aralık: **%15,7904**.
- Physical footprint: **36,00 MiB**; aralık büyümesi **0,72 MiB**.
- Paket-idle wakeup: **17**; disk okuma **131.072 byte**, yazma **0**.

Bu gözlem, müzik/olaylarla açık bırakılan sürecin sıfır iş yapmadığını gösterir.
%0,1–0,2 hedefinin her koşulda sağlandığı iddia edilmez. Track değişimi gibi
olaylar tekil sıçramalar üretebilir; bu kayıttan sıçramanın nedenini kesin
olarak atamak mümkün değil. Tamamen durağan ve açık masaüstü testi hâlâ gereklidir.

### 11 Ekim akşamı: kilit açık, aynı Spotify parçası duraklatılmış

Kullanıcı ekranı açıp Spotify'ı duraklattı. Her iki 125 sn koşuda runtime log
`playing=false; title=Black and Yellow` doğrulandı. Başlangıç/bitiş session
kayıtlarında ekran kilidi yok. Aynı diagnostic kaynak dosyası ve aynı 20 aç/kapa,
normal/hızlı sekme, statik Sistem/medya ve kapalı ada senaryosu kullanıldı.
Düzeltilmiş Mach-timebase ölçüm betiği iki sürüm için de kullanıldı.

| Senaryo | Önce ort. CPU | Son sürüm ort. CPU | Önce / sonra yaklaşık 250 ms tepe |
|---|---:|---:|---:|
| Aç/kapa | %19.0841 | %18.6042 | %34.938 / %32.398 |
| Statik expanded | %1.1325 | %0.6269 | %25.411 / %11.123 |
| Sistem | %2.5675 | %2.8818 | %29.467 / %32.864 |
| Normal sekmeler | %25.7712 | %26.7647 | %44.365 / %46.048 |
| Hızlı sekmeler | %44.8295 | %45.0787 | %55.059 / %55.197 |
| Medya/duraklatılmış | %0.7764 | %1.1277 | %26.170 / %23.010 |
| Kapalı/duraklatılmış | %0.0027 | %0.4176 | %0.241 / %4.322 |

125 sn toplam ortalama önce **%6,6506**, sonra **%7,0449**. Toplam tepe
önce **%55,0588**, sonra **%55,1972**. Son footprint önce **55,64 MiB**,
sonra **58,06 MiB**; wakeup önce **1617**, sonra **1349**.

**Genel CPU veya bellek düşüşü doğrulanmadı.** Aç/kapa ve statik panel
bu gözlemde daha düşük; Sistem, normal sekmeler ve post-test kapalı aralık
daha yüksek çıktı. Bir çift koşu, farkın kalıcı regresyon olduğunu veya
optimizasyonun neden olduğu kesin bir kazanç olduğunu ispatlamaz. Diğer
uygulamalar, kullanıcı etkileşimleri ve CPU frekansı sabitlenmedi.
Hızlı sekmeler 80 ms aralıklarla değiştirilen stress senaryosudur.
%55 değerleri tek çekirdeğe göre 250 ms ortalaması, sürekli idle tüketim değil.

### Son kurulu sürüm: açık masaüstü, normal çalıştırma

Aynı duraklatılmış medya koşulunda diagnostic flagsiz normal kurulu uygulamadan
ayrı **45,01 sn** ölçüm alındı (önceki benchmark ile doğrudan karşılaştırma değil):

- Ortalama CPU **%0,0105**, en yüksek yaklaşık 250 ms **%0,5765**.
- Footprint **34,25 MiB**, aralık değişimi **−0,08 MiB**.
- Disk okuma/yazma **0 / 0**, paket-idle wakeup **2**.

Bu kısa durağan koşuda %0,1–0,2 idle hedefi sağlandı; sürekli/evrensel garanti değil.
Ölçüm öncesindeki ayrı 3 sn, 5 ms `sample` kaydı ana thread ve worker'ları
bekleme durumunda gösterdi. Örnekleme profili CPU sayacının ölçüm aralığına
dahil edilmedi. Saatler süren soak veya pil yüzdesi ölçümü yapılmadı.

### Açık masaüstü: Dock ve GPU canlı doğrulaması

- Dock live testi **geçti**: üç kart/üç görüntü (minimized dahil), panel üzerinde
  dururken yeniden capture olmaması, minimized pencerenin restore/focus olması,
  10 hızlı iptal edilen hover ve bütün image/task/observer temizliği doğrulandı.
  Yerel ekran görüntüsü `dock-live-unlocked.png` gözle incelendi; üç kart,
  hizalama ve başlıklar düzgün.
- Aktif aç/kapa sırasında eski/yeni sürüm için ayrı Metal System Trace kayıtları
  alındı. İkisinde de doğrudan uygulamanın Metal command-submission satırları **0**.
  Bu, GPU yüzdesinin sıfır olduğunu veya toplam WindowServer işinin azaldığını
  ispatlamaz. Uygulamaya özgü GPU yüzde ve pil/enerji miktarı yine doğrulanamadı.
- Gerçek fareye denk native event gönderimleriyle hover screenshot denemesinde
  istenen ve gerçek cursor koordinatları eşleşmedi; bu deneme hover gecikmesinin
  ölçümü/başarılı insan hover testi olarak sunulmuyor. Model/observer/animasyon
  otomatik testleri ve gerçek çizilen aç/kapa benchmark'ı geçti.

## GPU ve enerji

İki ayrı 10 sn idle Metal System Trace kaydında doğrudan OpenIsland'e ait
`metal-application-command-buffer-submissions` satırı bulunmadı.
İkinci kayıt kilitli masaüstündeydi. SwiftUI/AppKit compositing maliyetleri
WindowServer'a yazılabilir: satır bulunmaması **GPU %0** anlamına gelmez.
Activity Monitor trace sürece özel kullanılabilir GPU yüzde/enerji sütunu sağlamadı.

Süreç başına GPU yüzdesi, mW, pil yüzde/saat ve Energy Impact sayısı doğrulanamadı.
Bunlara tahmini ölçüm sayısı yazılmadı; **sıfır enerji** garantisi verilmiyor.

## Bilerek korunan zaman tabanlı işler

Kaynak taramasındaki 72 eşleşme bağımsız 72 timer değildir; yorumlar,
diagnostic beklemeleri ve tek seferlik gecikmeler de buna dahildir.

- Sistem paneli görünürken 2 sn, düşük güçte 4 sn örnekleme: CPU delta'sı ve
  güncel sensörler için gerekli; panel kapanınca Task/volume observer'ları iptal edilir.
- Hover kapanış toleransı ve notice sonlandırma: davranışı koruyan iptal edilebilir tek seferlik işler.
- Focus timer deadline: gerçek zaman tabanlı özellik; kapatılmadı.
- Kopyalama sonrası pano yazımını bekleyen sınırlı kontroller: public pano-change
  bildirimi eksikliğini karşılıyor; sürekli pano taraması yok.
- Ses route başlangıç doğrulamaları ve MediaRemote hata sonrası sınırlı retry:
  başarılı/iptal edilmiş işlemden sonra tekrar döngüsü sürmez.
- Raf işleminin stderr okuma döngüsü aktif child pipe üzerinde bloklanır;
  idle background spin döngüsü değildir.
- Mevcut network, Bluetooth, güç ve ekran olay izleme yolları yeniden
  polling'e çevrilmedi. Kullanılmadığında yeni network/disk taraması eklenmedi.

## Doğrulama ve sınırlar

- Swift: 172 test / 27 suite geçti.
- Gerçek donanım: 1000 CPU + 1000 memory okumasında Mach port referansları sabit;
  400 termal istemci create/read/release çevriminde ısınma sonrası büyüme 229.400 byte.
- Varsayılan public sensor worker'ın gerçekten çağrıldığı ve ana thread dışında
  çalıştığı doğrulandı. Bloklanan fake backend UI'ı bloklamıyor; kapanmış/ayarları
  değişmiş panel eski sonucu yayımlamıyor.
- System panel: aç/kapa, tek storage-entry read, manuel refresh, private ayar,
  observer cleanup ve iptal testleri geçti.
- Spaces: gerçek presentation controller lifecycle, fallback/wake/retry,
  geciken fullscreen çıkış ve ekran-konfigürasyonu testleri geçti.
- Performans/feedback/controls kontrolleri: hover/task cleanup, transfer/dedup,
  artwork, camera lifecycle, waveform/progress, izinler, pano, medya,
  dosya bütünlüğü ve ses gain kanal eşlemeleri geçti.
- Kırmızı düğme: çoklu pencere, son pencere, kaydetmeyi iptal ve geciken kapanış
  gerçek test uygulamalarıyla geçti; mixer listener sayısı 100 çevrimde birikmedi.
- Dock temel test: 100 lifecycle ve 10.000 idle pointer/dismiss eventinde
  gereksiz query/capture veya observer birikimi görülmedi.
  Native AX probe'da toplu ve tekil Dock attribute okumaları aynı değerleri verdi.
- Dock canlı preview testi hem eski hem yeni kodda ekran kilidi nedeniyle
  pencere/görüntü açamadı. Akşam kilit açık tekrarında **geçti** (yukarıdaki ek doğrulama).
- Saatlerce soak, fiziksel AirPods/kablo/düşük pil/uyku senaryoları bu turda yapılmadı.
  Kısa lifecycle testleri saatlerce bellek/pil kararlılığı garantisi değildir.
- Son release yeniden derlendi; kalıcı designated requirement önceki kurulu
  uygulamayla aynı. Kaynak build, SSD build ve kurulu binary SHA-256 eşleşti.
  Kaynak/SSD rsync checksum karşılaştırması dosya farkı göstermedi.
  `/Applications/OpenIsland.app` tek süreç olarak yeniden başlatıldı.

## Teslim / geri dönüş

Güncel proje: `/Volumes/HIKSEMI/proje/OpenIsland`.
Eski SSD kopyası, kullanıcının ilk kaynakları ve önceki kurulu app:
`/Volumes/HIKSEMI/proje/OpenIsland-backups/20261011-150425`.
Ham log/JSON/trace kanıtları:
`/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261011-150425`.

Kaynak scratch klasörü silinmedi. GitHub'a push veya geçmiş değişikliği yapılmadı.
