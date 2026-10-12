# Yerel Dock entegrasyonu — 12 Ekim 2026

## 1. Entegre edilen değişiklik

Yerel dal: `local/energy-dock-20261012`, ayrı checkout: `/Volumes/HIKSEMI/proje/OpenIsland-local-dev`.

DockPreviewController gerçek AX hedefinden gelen URL'yi artık çalışan her uygulama için tekrar normalize etmiyor; bir kez normalize edip aynı karşılaştırmalarda kullanıyor. Mevcut hedefin hızlı yolu, uygulama listeleme, bundleIdentifier fallback, pencere seçimi, yakalama izinleri ve bütün görünüm kodu korundu. Yeni timer, cache, polling, animasyon değişikliği veya özellik kapatma yok.

Yalnız canlı testin hazırlığına Dock magnification sonrasında ikon koordinatını tekrar okuyan sınırlı üç adım eklendi. Bu üretim koduna veya hover süresine eklenmedi.

Başlangıç kullanıcı değişiklikleri `81f4779` snapshot commit'iyle korundu. Ana çalışma klasörüne dokunulmadı. Ayrı `source-backup.tgz`, `user-changes.patch`, başlangıç HEAD/status ve ikili hash yedeği kanıt dizininde bulunur.

## 2. Tekrarlanabilir gerçek Dock ölçümü

Ölçüm yalnız sentetik URL listesi değildir: üretim DockPreviewController kaynakları optimize release test harness'inde derlendi; macOS Dock AX hit-test, çalışan uygulama eşleştirmesi ve gerçek üç pencereli fixture kullanıldı. Bu, kurulu uygulama ikilisinin tamamına uygulanmış A/B değildir; gerçek hizmet yolunun izole A/B testidir.

Kabul edilen sıra A6 → B6 → B7 → A7. Her tur yeni hedef yolu ve aynı hedef yolu için 150'şer gerçek AX sorgusu; tüm sorgular beklenen uygulamayla eşleşti. CPU zamanı `getrusage` ile ölçüldü. Derleme, ölçülen döngünün dışında.

| Yol | A CPU ms/sorgu | B CPU ms/sorgu | Sonuç |
|---|---:|---:|---|
| Yeni hedef / uygulama listesinden eşleştirme | 0,83367 | 0,42102 | %49,50 daha az CPU işi |
| Mevcut hedef / hızlı yol | 0,03217 | 0,03161 | Yaklaşık %1,76 fark; gürültü nedeniyle anlamlı kazanç sayılmadı |

Yeni hedefin tur bazlı CPU süreleri A: 0,131249 / 0,118853 s; B: 0,061992 / 0,064315 s (150 sorgu). A wall süreleri 0,15244 / 0,13949 s; B: 0,08618 / 0,08958 s.

Test sürecinin tepe RSS değeri A'da 60,4–61,5 MB, B'de 58,1 MB civarında. Bunlar bütün harness'in tepe değerleri, tahsis maliyeti veya kanıtlanmış kalıcı RAM kazancı değildir. Regresyon sinyali görülmedi.

İlk turlarda hedef eşleşmeyen/önizleme açılmayan denemeler oldu. Bunlar başarı veya kazanç olarak sayılmadı. Dock magnification için test koordinatı yerleşimi düzeltildi; kurulu uygulama ile testin eşzamanlı önizlemeleri ayrıldı. Bu iki koşul ayrı ayrı izole edilmediğinden ilk hatanın tek nedeni kesinleştirilmedi. Tüm loglar korundu.

## 3. Başarılı doğrulamalar

- `swift test`: 172 test / 27 suite PASS.
- `swift build -c release`: PASS.
- `Scripts/check-performance.sh`: tüm kontrol grupları ve Python sayaç kalibrasyonunun 4 testi PASS.
- `Scripts/check-dock-previews.sh`: PASS; 100 enable/disable, 10.000 iç ekran pointer olayı, 10.000 boş dismiss, observer/task temizliği.
- Entegre kaynakla canlı: üç pencere/üç snapshot, üç pencere/sıfır snapshot (izin yok fallback), tek küçültülmüş pencere/tek snapshot PASS.
- Küçültülmüş pencere geri açıldı ve odaklandı; panelde durma tekrar capture üretmedi; 10 hızlı iptal edilmiş hover capture veya açık panel bırakmadı.
- Üretim SwiftUI görünüm/animasyon kaynakları değişmedi. Canlı geometri/pencere testleri geçti; bu tur Dock için bağımsız piksel eşitliği testi yapılmadı.
- BundleIdentifier fallback kodu birebir korundu; canlı izin fallback'i ayrıca test edildi. URL eşleşmesini kasıtlı bozup bundleIdentifier fallback'ini zorlayan canlı senaryo bu tur yapılmadı.

## 4. Native mimari: ayrı tutuldu, entegre edilmedi

Notlar fixture'ında baseline/native aynı NSTextView metnini (`Controlled note\nLine two`) ve aynı geometriyi verdi. Yeniden boyutlandırmada responder, aynı NSTextView kimliği ve `{2,4}` seçimi korundu. Önceki aynı-kimlik parametre revision düzeltmesi deney alanında korundu.

Bu tur sistem AXUIElement API'siyle tam fixture ağacı okunabildi: baseline/native 13 düğümün rol, başlık, açıklama ve değer sırası aynı. TextArea içeriği, Başlatıcı menüsü ve iki düğme etiketleri dahil. Bu, VoiceOver konuşması/klavye dolaşımı ve bütün ürünün AX doğrulaması değildir.

100 adet 25 ms hızlı retarget/cache testi tamamlandı. Yerleşme sonrasında bir host ve opacity=1 kaldı; yalnız son host bildirim aldı. Stop sonrası iki observer bırakıldı, iki task iptal edilip bitti. Bu sonuç kontrollü fixture'a aittir, tüm ürün servislerinin lifecycle güvenliği değildir.

Native entegrasyonu reddedildi: tüm sekmelerin dış parametre bağımlılıkları, Media/Clipboard/Shelf/Focus gerçek işlevleri, bütün VoiceOver etkileşimleri, spring/presentation ara kare eşdeğerliği ve toplam enerji doğrulaması bitmedi. #000000 notch yüzeyi veya mevcut animasyonlara hiçbir üretim müdahalesi yapılmadı. Bu eksikleri kapatmak için özellik azaltılmadı; kanıtsız cache/surface mimarisi ana dala alınmadı.

## 5. Enerji ve ölçüm sınırları

%49,50 yalnız yeni Dock hedefi eşleştirme yolunun CPU işidir; toplam uygulama CPU'su veya pil ömrü yüzdesi değildir. Mevcut hızlı yol ve boşta iş planlama kodu değişmedi. CPU işini GPU/WindowServer'a aktaran bir değişiklik yok.

Kurulu orijinal sürüm yeniden açıldıktan sonraki 30 saniyelik gözlem: ortalama CPU %0,3643; 1 saniyelik en yüksek aralık %5,6111; fiziksel footprint 35,28 MiB, değişim −0,02 MiB; 26 package-idle wakeup, disk okuma/yazma 0 bayt. Bu yeni adayın ölçümü veya kontrollü A/B değildir; tek sıçramanın nedeni eşzamanlı stack olmadan adlandırılmadı. WindowServer süreç sayaçları izin hatası verdi; eksik değerler sıfır sayılmadı.

`powermetrics` yönetici yetkisi olmadan çalışmadı. Bu tur güvenilir GPU, toplam enerji, batarya saat kazancı veya açık/kapalı-medya-sekme enerji matrisi elde edilmedi. Bu sonuçlar tahmin edilmedi. Önceki %2,49 boşta yükselmenin kesin kök nedeni hâlâ kanıtlanmış değil. Bu tur farklı kullanıcı etkileşimli testleri idle kıyası olarak kullanmadık.

## 6. Teslim ve geri alma

Dock düzeltmesi yerel geliştirme dalında; release derlemesi ve ilgili regresyonlar başarılı. Kurulu uygulamanın ikilisi değiştirilmedi, test sonunda normal uygulama yeniden açıldı. GitHub push/release yok.

Yerel inceleme ve kullanıcı onaylı kurulum adımına hazır dar aday: Dock düzeltmesi. İmzalı yeni kurulum veya bütün gün enerji doğrulaması tamamlanmış değil. Native mimari production'a hazır değil.

Entegre kod commit'i: `3aa0628`. Geri alma: yerel geliştirme dalında `git revert 3aa0628` kullanın; `81f4779` kullanıcı değişikliklerini içeren başlangıç snapshot'ıdır. `reset --hard` veya ana çalışma klasörünü yedekle ezmek gerekmez. Başka bir klasörde geliştirmeye devam edilirse bu dar commit cherry-pick ile aktarılabilir; tüm snapshot geçmişini zorla birleştirmeyin.

Ham kanıtlar yerel ve özel: `/Volumes/HIKSEMI/proje/OpenIsland-Evidence/20261012-local-integration`. `dock-accepted-summary.json`, `A6/B6/B7/A7-dock-metrics.json`, canlı/test logları, `native-system-ax`, `native-retarget`, `integrity-final.json`. Ham kanıtlar GitHub'a eklenmedi.
