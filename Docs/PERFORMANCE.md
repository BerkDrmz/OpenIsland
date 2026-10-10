# Performans incelemesi — 9–10 Ekim 2026

OpenIsland boşta sürekli veri taramadan çalışır. Bu incelemede kapalı ada, statik açık panel,
gerçek aç/kapa geçişleri, görünür Sistem sekmesi ve aktif uygulama ses işleme yolu ayrı ölçüldü.
Sonuçlar bu cihaz ve test koşulları içindir; tüm cihazlarda tepe CPU, GPU veya pil tüketimi için
garanti değildir.

## Cihaz ve yöntem

- MacBook Air, Apple M4, 10 CPU çekirdeği, 16 GB bellek.
- macOS 27.0.1 (26A434), arm64 release derlemesi, yerel kalıcı kod imzası.
- CPU: `proc_pid_rusage(RUSAGE_INFO_V2)` kullanıcı + sistem CPU süresi / geçen süre.
  **%100 bir CPU çekirdeğidir.** Farklı çekirdeklerin hızları aynı olmadığından toplam işlemci gücünü
  yalnızca çekirdek sayısına bölerek kesin enerji tüketimi çıkarılmaz.
- Tepe sütunu yaklaşık bir saniyelik örneklerin en yükseğidir; milisaniyelik anlık tepe değildir.
  Ortalama CPU da tek bir animasyon karesinin maliyeti değildir.
- Bellek: sürecin fiziksel ayak izi (`ri_phys_footprint`), toplam Mac RAM kullanımı değil.
  Bellek boyutları MiB olarak verilir (1 MiB = 1.048.576 byte).
- Uyanma: `ri_pkg_idle_wkups`; bu sayaç bütün olayları, iş parçacığı uyanmalarını veya GPU işlerini saymaz.
- Uygulama CPU ölçümü sırasında Instruments çalıştırılmadı. Metal izi ayrı bir çalıştırmada alındı.
  Core Audio, WindowServer ve diğer uygulamaların maliyetleri aşağıdaki süreç CPU'suna dahil değildir.

## CPU ve bellek

| Senaryo | Kullanılan ölçüm süresi | Ortalama CPU | En yüksek ~1 sn CPU | Fiziksel ayak izi |
|---|---:|---:|---:|---:|
| Normal açılış, tanılama kapalı, boşta | 60,01 sn | %0,0001 | %0,0019 | 32,47 MiB |
| 40 gerçek aç/kapa geçişi | 32,13 sn | %0,3586 | %0,4222 | 49,25 MiB |
| Statik açık Nook | 27,10 sn | %0,0001 | %0,0014 | 48,92 MiB |
| Sistem sekmesi, canlı sensörler | 16,07 sn | %0,0268 | %0,1010 | 53,52 MiB |
| %50 ses seviyesi, aktif Core Audio yolu | 17,05 sn | %0,0042 | %0,0047 | 53,64 MiB |
| Bu işlemlerden sonra yerleşmiş tanılama oturumu | 54,22 sn | <%0,0001 | %0,0012 | 52,80 MiB |

Normal boşta ölçümde disk okuma/yazma ve paket boşta uyanma sayacı sıfırdı; fiziksel ayak izi
yalnızca yaklaşık 0,02 MiB arttı. Yüzdeler küçük olsa da mutlak sıfır tüketim anlamına gelmez.

Aç/kapa testi gerçek uygulama panelini 40 kez açıp kapattı; her döngüde genişlemiş ve kapalı durumlar
doğrulandı. Döngü başına yaklaşık 0,4 sn açık + 0,4 sn kapalı bekleme kullanıldı. Hızlı 1.000 giriş/çıkış
olayından sonra bekleyen model görevi sıfırdı. Hareket stili Canlı, sistem Düşük Güç Modu kapalıydı.
Bu test programatik açma/Esc kapamadır; insanın fiziksel trackpad hareketini veya her UI içeriğini temsil etmez.

Statik paneller ve ses testinde giriş/çıkış geçişleri dışarıda bırakılarak yerleşmiş aralıklar seçildi.
Ses testi ayrı bir test uygulamasının düşük seviyeli, stereo 48 kHz sinüs sinyaliyle yapıldı; Chrome,
çok sayıda eşzamanlı uygulama, Bluetooth veya bütün çıkış aygıtları için aynı tüketim beklenmemelidir.
Ses yolu her iki kontrol noktasında aktifti ve hata bildirmedi. Seviye %100'e dönünce yol sayısı sıfıra,
Sistem sekmesi kapanınca sensör görevi duruma göre sıfıra indi.

Yerleşmiş tanılama aralığında disk okuma/yazma sıfır, paket boşta uyanma sayacı sıfırdı; ayak izi
yaklaşık 0,02 MiB azaldı. 178 saniyelik bütün oturumun açılıştan itibaren bellek büyümesi, uygulama
başlatma ve ilk kullanım maliyetini de içerir; bellek sızıntısı diye yorumlanmadı. Tanılama günlüğü
açık olduğundan aç/kapa evresinin disk yazımı normal uygulamanın boşta disk yazımı değildir.

## GPU ve pil

Apple'ın [Metal araçları](https://developer.apple.com/metal/tools/) içinde bulunan Instruments
Metal System Trace kullanıldı. İz, ayrı bir aç/kapa çalıştırması sırasında 12 saniye alındı;
dışa aktarılan tabloda 20.962 GPU aralığı vardı. Bunlarda OpenIsland adına bir aralık atfedilemedi;
kompozisyon işleri WindowServer ve başka süreçlerde göründü. Metal komut tamponu gönderim tablosu
da bu hedef için boştu. Bu sonuç **GPU %0** anlamına gelmez. SwiftUI/Core Animation çizimi
başka süreçte de iş yapabilir; bu ölçümle uygulamaya özel GPU yüzdesi doğrulanamadı.

Pil tüketimi için kontrollü saatler süren açık/kapalı karşılaştırması yapılmadı. CPU verilerinden
günlük pil yüzdesi veya “hiç pil tüketmez” sonucu çıkarılmıyor. Animasyon, kamera, ekran yakalama,
aktif ses işleme ve zaman göstergeleri çalışırken enerji gerekir.

Kodda gereksiz yeniden çizimleri azaltmak, görünmeyen kamerayı durdurmak ve olay tabanlı izlemek
tercih edildi. Bu yaklaşım Apple'ın [çizim verimliliği](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency)
ve [enerji verimliliği](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/BestPractices.html)
önerileriyle uyumludur; tek başına bir pil ölçümü değildir.

## Kod ve yaşam döngüsü incelemesi

| Alan | Çalışma koşulu | Boştayken davranış |
|---|---|---|
| Pil/şarj | IOKit güç kaynağı bildirimi | Pil yoklama zamanlayıcısı yok; eşik bildirimleri durum değişiminde |
| Ağ | NWPathMonitor | Ping, Wi-Fi taraması veya düzenli HTTP isteği yok; aynı durum tekrar bildirilmez |
| Bluetooth | IOBluetooth bağlantı olayları | Sürekli keşif/pil taraması yok |
| Ekran | Mevcut ekran bildirimleri | Ayrı ekran taraması yok; değişmeyen konfigürasyon bildirilmez |
| Aktarım | NSProgress + KVO | Aktif aktarım yoksa ilerleme görevi yok; güncellemeler en fazla 10/sn/aktarım |
| Hover | NSTrackingArea | Sürekli imleç konumu yoklaması veya display-link yok |
| Dock önizlemesi | Gelen fare olayında kenar/AX kontrolü | Duran imleç için zamanlayıcı yok; açık statik panel tekrar yakalanmaz |
| Sistem sekmesi | Görünürken 2 sn örnekleme; tasarrufta 4 sn | Sekme kapandığında görev ve termal istemci bırakılır |
| Ses Mikseri | Ara uygulama seviyesi veya özel çıkış | %100 + varsayılan çıkışta ses işleme yolu yok; aktif ses yokken yol durur |
| Müzik nabzı | Oynatma durumunda Core Animation | Duraklatma, Hareketi Azalt ve tasarrufta yinelenen hareket durur |
| Medya süre metni | Medya görünür ve çalarken 1 Hz | Duraklatılmış medyada TimelineView zamanlaması durur |
| Pomodoro | Bitiş için tek bekleyen görev | Aktif zamanlayıcı yoksa periyodik kontrol yok |
| Bakım araçları | Kullanıcı tarama/güncelleme isterken | Kapanınca görev ve liste/görüntü kaynakları bırakılır |
| Tam ekran geçişi | Space/uygulama olayı ardından kısa doğrulamalar | Bekleyen geçiş yokken sürekli pencere taraması yok |

Gerekli zamanlayıcılar kaldırılmadı: canlı sensör örneklemesi, aktif süre metni, hover toleransı,
geçici bildirim ömrü, tam ekran yerleşme doğrulaması ve sınırlı hata yeniden denemeleri korunur.
Görünen UI ve mevcut özellikler performans sayısını düşürmek için kapatılmadı.

Önceki optimizasyonda ses çıkışının tamamen yazıldığı stereo tamponlarda gereksiz ilk sıfırlama
kaldırıldı. Eksik/kısa tamponlarda sıfırlama ve gain rampası korunur; 1.920 eski/yeni karşılaştırmada
çıkış byte düzeyinde aynıydı. 1.024 karelik mikrobenchmark'ta yaklaşık %8–9 daha az CPU süresi
görüldü; bu **tüm uygulamanın CPU'sunda %8–9 iyileşme** demek değildir.

9 Ekim incelemesinde üretim davranışını değiştiren yeni bir darboğaz düzeltmesi gerekmedi. Geliştirici
aç/kapa aracı, açılmayı gerçekten doğrulayacak şekilde güçlendirildi; kullanıcının kayıtlı ayarlarını
değiştirmez ve normal açılışta çalışmaz. Eski GPU/yoklama açıklamaları ölçümün sınırlarıyla güncellendi.

## Doğrulamalar ve sınırlar

- 172 otomatik test / 27 test grubu geçti; release derlemesi ve kurulu uygulamanın imzası doğrulandı.
- Performans kontrolleri: 1.000 hover çevrimi, 9.999 KVO güncellemesi, aktarım sonu deduplication,
  ağ monitor lifecycle, 200 kamera aç/kapa, 500 aynı kapak kullanımı ve diğer olay yaşam döngüleri geçti.
- 1.000 CPU + 1.000 bellek okumasında Mach host send-right sayısı değişmedi.
- Isınma sonrasında 400 termal sensör aç/oku/kapat çevriminde yaklaşık 295 KB büyüme gözlendi;
  bu kısa test kalıcı bellek sızıntısı göstermedi, saatler süren kullanım garantisi değildir.
- Dock: 100 etkinleştir/kapat çevriminde 2 fare izleyicisi / 7 observer, kapatınca sıfır;
  10.000 ekran ortası hareketinde pencere/AX/yakalama sorgusu yok. Gerçek üç pencere önizlemesi,
  küçültülmüş pencereye geçiş, statik panelde tekrar yakalamama ve kaynak temizliği geçti.
- Ses düzeyi, kısa tampon, gain rampası ve bütün stereo kanal düzenleri kontrolleri geçti;
  100 Ses Mikseri aç/kapa çevriminde observer sayısı sabit kaldı ve kapanınca sıfırlandı.
- Gerçek kırmızı düğme testleri son pencerede normal çıkış, kaydetme/iptal davranışı ve gecikmiş
  kapanışı doğruladı. Space sağlayıcı/ekran geometrisi kontrolleri geçti.
- Bakım aracında 100 aç/kapa, iptal edilen tarama ve yalnızca onaylanan güncellemenin açılması;
  raf testlerinde 42 paralel dosya temsili, zip/unzip bütünlüğü ve aktarım kaynaklarının korunması geçti.

Bu turda fiziksel kablo çıkarma/takma, gerçek düşük pil, gerçek uyku/uyanma ve insan trackpad
hareketleri yeniden yapılmadı. Bunların hepsi test edildi veya her Mac'te kusursuzdur denmiyor.
App Store/bakım işlemleri ve Kamera aktifken tüketim boşta tablosuyla temsil edilmez.

## Yeniden ölçmek

Normal kurulu uygulamada ada ve araç pencerelerini kapatıp aktif aktarım/ses yönlendirmesi olmadan:

```bash
python3 Scripts/resource-probe.py --seconds 60 --output /tmp/openisland-idle.json
```

Tek bir OpenIsland süreci beklenir; birden fazla varsa `--pid <PID>` açıkça verilir. Python yalnızca
geliştirici ölçüm aracı içindir; uygulamanın çalışması Python'a veya ek Python paketine bağlı değildir.

Gerçek panel üzerinde geliştirici aç/kapa ve görünür Sistem sekmesi kontrolü için önce çalışan
OpenIsland'i normal Çık komutuyla kapatın, ardından:

```bash
OPENISLAND_DIAGNOSTICS=/tmp/openisland-performance.log \
OPENISLAND_GEOMETRY_PROBE=0 OPENISLAND_PERFORMANCE_SCRIPT=1 \
/Applications/OpenIsland.app/Contents/MacOS/OpenIsland
```

Başka bir Terminal'den `resource-probe.py` ile ölçün. Tanılama açıkken günlük dosyası yazılır;
normal boşta ölçümü için uygulamayı yeniden normal başlatın. `OPENISLAND_PERFORMANCE_AUDIO_PID`
yalnızca bilerek başlatılmış, ses çalan bir test uygulamasının PID'siyle aktif ses yolunu sınar;
istemeden normal uygulamaların ses seviyesini değiştirmek için kullanılmamalıdır.

GPU incelemesi, CPU ölçümünden ayrı bir oturumda:

```bash
xcrun xctrace record --template 'Metal System Trace' --attach <PID> \
  --time-limit 12s --output /tmp/openisland-metal.trace
```

Ham Instruments izleri ortam değişkenleri ve diğer süreç bilgileri içerebilir; depoya eklenmedi.
Ölçüm sonuçları cihaz, içerik, erişim izinleri, yenileme hızı ve sistem yüküyle birlikte değerlendirilmelidir.


## 10 Ekim: ses yolu onarımı ve ek render optimizasyonu

Görünüm, ada geometrisi, açılma animasyonu ve mevcut özellikler korunarak şu işler azaltıldı:

- Chrome gibi uygulamaların Core Audio yolu yeniden kurulurken HAL'in geçici geçersiz nesne/
  format cevabı yalnızca sınırlı başlangıç denemeleriyle ele alınır. Özgün ses, örnekler gerçekten
  gelene kadar susturulmaz. Bozulmuş aygıt yolu, yardımcı süreç değişimi ve uyanma olayında
  yeniden kurulur; sürekli ses taraması veya yeni boşta zamanlayıcı eklenmedi.
- Medya/Pomodoro ilerlemesi, sürekli kare enterpolasyonu yerine fiziksel piksele bağlı ayrık
  Core Animation anahtar kareleri kullanır. Saat ve bitiş zamanı korunur; tipik 264 pt medya
  çubuğu/180 sn örneğinde yaklaşık 11,56 değişim/sn, 600 fiziksel piksel/25 dk halkada 1,6
  değişim/sn planlanır. Bunlar GPU yüzdesi veya bütün uygulamanın kare hızı değildir.
- Müzik nabzının beş çubuğu aynı 24 Hz zaman ızgarasını paylaşır. Ada boyut değişiminde
  mevcut ritim ve giriş bitiş zamanı korunur; yerleşmiş nabız için beş yeni giriş animasyonu
  yeniden başlatılmaz. Hareketi Azalt, pil tasarrufu, duraklatma ve yeniden oynatma korunur.
- Değişmeyen ilerleme renkleri katmanlara tekrar yazılmaz. Görünüm kaldırılınca ilerleme/nabız
  animasyonları bırakılır; piksel örnek dizileri en fazla 8.193 değerle sınırlıdır.
- Boş Dock önizlemesine gelen kapatma/Space/tıklama olayları artık boş listeleri yeniden
  temizlemez veya gözlemlenen duruma tekrar yazmaz. Etkin önizlemenin iptali ve kaynak
  temizliği korunur. 10.000 boş kapatma çağrısında temizleme sayısı artmadı.
- Sistem sekmesinin dakika hassasiyetindeki çalışma süresi yazısı yalnızca dakika değişince
  yayınlanır. CPU/GPU ve sıcaklık örnekleme aralıkları değiştirilmedi.

Aynı iki katman uygulamasının (nabız ve ilerleme) önceki/yeni sürümüyle alınan ayrı powermetrics
karşılaştırmasında, ilk iki örnek dışarıda bırakıldığında 18'er örnekte **tüm sistem** GPU donanım
aktifliği ortalama %7,52 → %3,92, tahmini GPU gücü 10,78 → 6,39 mW çıktı. Bu kontrollü küçük
pencere denemesidir; OpenIsland'e özel GPU yüzdesi veya günlük pil kazancı değildir. Diğer süreçler
çalıştığından tek sıralı karşılaştırma nedensel bir kazanç garantisi sağlamaz. Bu ölçüm, ilerleme/nabız
zamanlama değişikliklerine aittir; sonraki Dock/çalışma süresi değişiklikleri için aynı kazanç iddia edilmez.

Son release üzerinde ayrıca IORegistry'nin belgelenmemiş `Device Utilization %` sayacı birer saniye
aralıkla 30 kez okundu. İlk açık oturumda ortalama %64,70 / tepe %72 görüldü; uygulama tamamen
kapalıyken %10,47 / %56; yeniden normal açılınca %10,77 / %26 görüldü. Diğer uygulamalar ve sistem
kompozisyonu denetim altında değildi. Bu yüzden ilk yüksek değerin OpenIsland'den kaynaklandığı
veya kapatarak bu farkın kazanıldığı sonucu çıkarılmadı. Son iki aralıkta uygulama kapalı/açıkken
benzer toplam değerler görüldü; bunları çıkararak OpenIsland GPU yüzdesi hesaplamak geçerli değildir.
IORegistry sayacı powermetrics donanım aktifliğiyle aynı ölçüm değildir. Uygulamaya özel GPU ve
kontrollü saatlik pil tüketimi bu turda da doğrulanamadı.

Son doğrulamalar:

- 172 test / 27 grup; imzalı release derlemesi ve kurulu binary/imza doğrulaması geçti.
- Yerel performans, Sistem, Ses Mikseri/kırmızı düğme, Dock ve Space/tam ekran kontrolleri geçti.
- Gerçek Dock: üç kart/üç küçük görüntü, küçültülmüş pencereye geçiş ve kaynak temizliği geçti.
- 1.000 değişmeyen + 1.000 değişen nabız yerleşimi ritmi korudu; yerleşmiş boyut değişiminde
  ek giriş animasyonu kurulmadı. İlerleme saati, renk değişimi, resize, pause ve cleanup geçti.
- 400 termal sensör çevriminde ısınma sonrası fiziksel ayak izi artışı 114.688 byte oldu; kısa
  testte büyüyen istemci sızıntısı görülmedi. 1.000 CPU + 1.000 bellek okuması Mach haklarını korudu.
- 100 Ses Mikseri çevriminde 13 listener sabit kaldı; kapanınca sıfır. Kırmızı düğmede son pencere,
  kaydetme iptali ve geciken kapanış gerçek test pencereleriyle doğrulandı.
- 20 gerçek klavye aç/Esc kapa çevriminde görünmez sensör geometrisi her defasında açık/kapalı
  olarak doğrulandı. 24,01 sn aralıkta CPU ortalaması %0,3555, ~1 sn tepe %0,4419;
  ayak izi 36,14 MiB ve aralık içi artış 0,45 MiB. Milisaniyelik CPU tepeleri ayrıca ölçülmedi.

Üç parmak masaüstü geçişi macOS'un Trackpad ayarına aittir. Kullanıcı ayarı tamamladı;
OpenIsland'e sistem jestini yakalayan yeni monitor eklenmedi. Fiziksel kablo, uyku ve düşük pil
senaryoları bu turda yeniden yapılmadı. Aktif özellikler kapatılarak performans sayısı düşürülmedi.


10 Ekim normal çalıştırma CPU aralıkları (`proc_pid_rusage`, 1 sn örnek):

| Aralık | Süre | Ortalama CPU | En yüksek ~1 sn CPU | Fiziksel ayak izi | Disk okuma/yazma |
|---|---:|---:|---:|---:|---:|
| Önceki kurulu sürüm, boşta | 45,00 sn | %0,0016 | %0,0297 | 82,00 MiB | 0 / 0 |
| Yeni derleme, açılış yerleştikten sonra boşta | 45,00 sn | %0,0067 | %0,0727 | 23,14 MiB | 0 / 0 |
| Yeni derleme, 20 aç/kapa sonrasında boşta | 45,00 sn | %0,0061 | %0,0587 | 35,88 MiB | 0 / 0 |

Önceki süreç uzun süre çalışmış ve farklı panelleri kullanmıştı; yeni süreç önce yeniden başlatıldı.
Bu nedenle bu üç satır nedensel CPU/bellek kazancı karşılaştırması değildir; yeni optimizasyonlar
sayesinde ortalama CPU'nun azaldığı iddia edilmez. Son boşta aralıkta bellek 0,05 MiB azaldı,
paket boşta uyanma sayacı 91 arttı. Sayılan uyanmalar sıfır olmadığından “boşta hiç çalışmıyor” veya
“hiç pil tüketmez” denmez. Gözlemlenen süreç CPU'su düşük, disk işlemleri sıfır ve kısa testte sürekli
bellek büyümesi yoktur. Tarayıcı, WindowServer ve başka süreçlerin maliyetleri bu CPU'ya dahil değildir.
