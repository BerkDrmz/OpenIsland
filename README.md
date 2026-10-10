# OpenIsland

OpenIsland, MacBook için geliştirilen ücretsiz ve açık kaynaklı bir Dynamic Island uygulamasıdır.
Müzik kontrollerini, bildirimleri ve günlük araçları ekranın üst kısmında bir araya getirir.
Swift ve SwiftUI ile geliştirilmiştir; boşta gereksiz işlem yapmamaya odaklanır.

| Özellik | Uygulama |
|---|---|
| Medya + ses nabzı | Spotify, Müzik, tarayıcılar (MediaRemote / adapter / AppleScript), albüm kapağı, tıklanıp sürüklenebilen süre çubuğu (desteklemeyen kaynakta salt okunur), ses kaydetmeyen ve analiz etmeyen, Core Animation ile çalışan tahmini ve organik amber müzik nabzı, kapağa/başlığa tıklayınca çalan uygulamaya geçiş |
| Ses göstergesi | Jest ve kaydırıcıyla yapılan ses değişimi adada görünür; ses, parlaklık ve klavye ışığı tuşları macOS'un kendi göstergesine bırakılır (tuş yakalama ve parlaklık için private çerçeve yok) |
| Quick Mirror | FaceTime kamerası, aynalı daire önizleme |
| Hover ile açılma | Ön ayarlar: Kapalı / Hızlı (60 ms) / Normal (100 ms) / Rahat (250 ms); ayrılınca söner; ⌃⌥⌘I ile klavyeden, Esc ile kapanır |
| Geçici bildirimler | Pil/şarj (adaptör, %20, %10, %100), AirPods/kulaklık bağlandı-ayrıldı, parça değişimi, toplantı hatırlatması, Pomodoro, indirme/aktarım sonucu, AirDrop, kilit açma, ağ yolu değişimi, harici ekran — tek sunum modeli, deterministik öncelik |
| Canlı etkinlikler | Kanatlarda indirme/aktarım halkası ve yüzde (App Store dahil, macOS ilerleme yayını sağladığında), Pomodoro geri sayımı, çalan müzik |
| Dosya rafı | Çift bölge (raf + AirDrop), çoklu seçim, Quick Look, topluca sürükleme, yeniden açılışta kalıcı, Fotoğraflar/Mail'den file promise; dosya işlemleri: Zip'le, Arşivi aç, Resmi sıkıştır, Yolu kopyala |
| Araçlar | Pano geçmişi + renk damlalığı, Pomodoro, takvim (etkinlik → Takvim'de açılır, Katıl → toplantı), Apple Anımsatıcılar (bugün, tamamla, ekle; başlık → Anımsatıcılar), Quick Notes, uygulama/bağlantı/Shortcuts başlatıcı; isteğe bağlı kaldırıcı, önbellek temizleyici ve güncelleme kontrolü |
| Sistem | Eşit yükseklikte CPU/GPU, bellek ve ekran kontrol sütunları; disklerin kullanılabilir alanı. Sıcaklık, eşleşen sensör grubunun son okumadaki en yüksek geçerli değeridir; ortalama veya geçmiş tepe tutulmaz. CPU/GPU sensör gruplaması belgelenmemiştir. Canlı ölçüm yalnızca sekme görünürken çalışır; desteklenmeyen sensörler değer uydurmadan gösterilir |
| Ses Mikseri | Çıkış, sistem sesi ve mikrofon aygıtları; uygulama bazında ses seviyesi ve çıkış yönlendirme. macOS 14.2+ Core Audio desteği ve sistem sesi izni gerekir; ses dosyası kaydedilmez. Varsayılan seviyede ses işleme yolu kurulmaz |
| Son pencerede çıkış | Ayarlar → Genel'den yönetilir. Erişilebilirlik izniyle son pencerenin kırmızı düğmesi uygulamadan normal çıkış ister; diğer pencereler, kaydetme uyarıları ve Finder korunur |
| Dock pencere önizlemeleri | Dock simgesinde kısa süre durunca uygulamanın açık ve küçültülmüş pencereleri görünür; önizlemeye tıklayınca seçili pencereye geçilir. Ayarlar → Genel'den kapatılabilir. Erişilebilirlik ve ekran erişimi gerekir; gösterilen kartlar için tek kare alınır, ses/video/dosya kaydı ve boşta pencere taraması yapılmaz. Panel kapanınca görüntüler bırakılır |
| Jestler | İki parmak yatay: parça (yön ters çevrilebilir); dikey: ses |
| Ada menüsü | Sağ tık: adayı aç/kapat, açık tut, demo modu (ekran kaydı için ada kendiliğinden kapanmaz), Ayarlar, Çık |
| Çentiksiz ekranlar | Harici monitör ve çentiksiz Mac'lerde menü çubuğunun hemen altında yüzen ada |
| Tam ekran | Akıllı (varsayılan) / Her zaman göster / Her zaman gizle |
| Ayarlar | Canlı ada önizlemesi (bu Mac'in ölçülen çentiğiyle), Hareket (Canlı ~0,25 sn açılış / Sakin / Azaltılmış), Nook düzeni (Sade / Dengeli / Üretkenlik), modül aç/kapa |
| Albüm renginde nabız | Müzik nabzı çalan parçanın kapak rengini alır (siyah üzerinde okunur kalacak kadar açılır; gri kapakta amber); ayarla kapatılabilir |
| Pil tasarrufu | Düşük Güç Modu açıkken veya Mac ısındığında müzik nabzı sabitlenir, hareket kısalır (ayarla kapatılabilir) |

Boşta düşük CPU kullanımı hedeflenir. Animasyonlar ve aktif özellikler işlem gerektirir;
CPU, GPU ve pil tüketimi cihaz, macOS sürümü ve kullanım koşullarına göre değişir.
Dock önizlemeleri görünür kart başına küçük bir tek kare alır; statik paneli tekrar yakalamaz.
Ses mikseri varsayılan %100 seviyede ve varsayılan çıkışta ses işleme yolu kurmaz; ara seviyelerde
ses örneklerini işlemek gereklidir. Aktif animasyon veya ses işlemi için sıfır tüketim garanti edilmez.

10 Ekim 2026'da M4 MacBook Air / macOS 27.0.1 üzerinde, 20 gerçek aç/kapa çevrimi sonrasındaki
45 saniyelik boşta ölçümde ortalama CPU %0,0061, en yüksek yaklaşık bir saniyelik örnek %0,0587
ve fiziksel bellek ayak izi 35,88 MiB oldu; disk okuma/yazma sıfırdı. Aç/kapa testinde ortalama CPU
%0,3555 çıktı. İlerleme ve müzik nabzındaki gereksiz render/yeniden başlatma işleri azaltıldı.
Bu bir cihaz ölçümüdür; tüm Mac'ler, milisaniyelik tepeler veya aktif özellikler için garanti değildir.
CPU/GPU incelemesi, aktif senaryoların ölçümleri ve yeniden ölçme komutları:
[Performans raporu](Docs/PERFORMANCE.md). CPU tepe değerleri örnekleme aralığına bağlıdır;
WindowServer'ın toplam GPU yükü uygulamaya özel tüketim değildir.

App Store indirmeleri, sistemin `NSProgress` yayını üzerinden olay tabanlı izlenir; sürekli
klasör taraması veya ağ sorgusu yapılmaz. TestFlight indirmesinde başlangıç, ilerleme ve bitiş
doğrulandı. macOS/App Store'un bu yayını sağlamadığı durumlarda yüzde gösterilemez.

Ayrıntılı teknik mimari: [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md)

## Gereksinimler

- macOS 14 Sonoma veya üzeri.
- Varsayılan uygulama derlemesi Apple Silicon (M serisi, arm64) içindir.
- Çentiksiz MacBook ekranlarında yüzen kapsül görünümü desteklenir.
- Intel için Universal 2 derleme seçeneği vardır; Intel cihazlarda ve tüm cihaz/macOS
  kombinasyonlarında çalışma henüz doğrulanmamıştır.
- Spaces sabitleme davranışı özel macOS API'lerinden yararlanır. Bu API'ler kullanılamazsa
  public pencere davranışına geçilir; geçiş animasyonundaki sabitlik macOS sürümüne göre değişebilir.
- Xcode 26+ veya yalnızca Command Line Tools. macOS 27 SDK'sında SwiftUI'nin `@State`'i bir
  makrodur ve eklentisi (`SwiftUIMacros`) yalnızca Xcode ile gelir; Xcode yoksa `build-app.sh`
  kaynakların `.build/clt-compat` altındaki bir kopyasında `@State`'i aynı property wrapper'a
  işaret eden bir typealias ile değiştirip onu derler. Xcode'da açmak için Xcode gerekir; `IslandCore`
  testleri Command Line Tools ile de çalışır (aşağıda).

## Derleme ve çalıştırma

```bash
./Scripts/build-app.sh
open build/OpenIsland.app
```

Betik, anahtar zincirinde bir "Apple Development" kimliği varsa onunla imzalar (yeniden derlemede
Erişilebilirlik/Kamera izinleri korunur); yoksa ad-hoc imzalar ve uyarır. Apple Developer hesabı
olmadan izinlerin her derlemede sıfırlanmaması için bir kez `./Scripts/create-dev-identity.sh`
çalıştırın: yerel, kendinden imzalı bir kimlik oluşturur ve betik sonraki derlemelerde onu kullanır.

Adanın Space/tam ekran geçişlerinde kayıp kaymadığını ölçmek için `./Scripts/space-probe.sh 120`
çalıştırıp dört parmakla kaydırın; sonunda her ada penceresi için "SABİT ✅ / KAYDI ❌" yazılır
(bkz. [Docs/ARCHITECTURE.md §4.1.1](Docs/ARCHITECTURE.md)). Universal 2 için
`ARCHS="arm64 x86_64" ./Scripts/build-app.sh`. Xcode'da açmak için `Package.swift` dosyasını açın ve
`OpenIsland` şemasını çalıştırın. Dağıtım (Developer ID, notarizasyon, Sparkle 2 planı) için
[Docs/ARCHITECTURE.md §8](Docs/ARCHITECTURE.md). İmzalı bir sürüm için:

```bash
CODESIGN_IDENTITY="Developer ID Application: Ad Soyad (TEAMID)" ./Scripts/build-app.sh
```

Durum makinesi, yerleşim motoru, güç/tam ekran kuralları, özel API hata politikası ve müzik nabzı deseni testleri:

```bash
swift test
```

Yalnızca Command Line Tools varsa uygulama hedefi (`@State` makrosu) derlenemez; yalnızca test hedefini
derleyip çalıştırın (Swift Testing eklentisinin yolu verilmelidir):

```bash
swift build --target IslandCoreTests -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

```bash
swift test --skip-build -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

## Bakım araçları

Menü çubuğu → **Araçlar…**, adanın sağ tık menüsü veya Nook → Kısayollar başlığındaki araç simgesi aynı pencereyi açar. Adanın boyutu ve mevcut sekmeler korunur.

- **Kaldırıcı:** `/Applications` ve `~/Applications` içindeki uygulamayı seçip **Kalıntıları tara**. Uygulama kimliğiyle eşleşen önbellek, tercihler, günlükler ve kaydedilmiş pencere durumu listelenir. Kişisel uygulama verileri ve yalnızca ada göre eşleşen klasörler ayrıca seçilir. Açık uygulamalar, OpenIsland, sistem uygulamaları, sembolik bağlantılar ve paylaşılan grup klasörleri kaldırılmaz. Ayrıcalıklı yardımcılar veya kimliği doğrulanamayan özel dizinler otomatik kaldırılmaz.
- **Önbellek temizleyici:** yalnızca `~/Library/Caches` taranır. Başlangıçta hiçbir öğe seçili değildir. **Tümünü seç**, yalnızca temizlenebilen öğeleri seçer; açık uygulamalarla eşleşen bilinen önbellekler ve OpenIsland'in raf çalışma dosyaları korunur. Tanınmayan önbellekleri temizlemeden önce ilgili uygulamaları kapat. Seçilen dosyalar onaydan sonra **Çöp Sepeti'ne taşınır**, kalıcı silinmez. Alan kazanmak için Çöp Sepeti'ni kendin boşaltmalısın; APFS ve yeniden oluşan önbellekler nedeniyle gösterilen dosya boyutu ile kazanılan alan farklı olabilir.
- **Uygulama güncelleyici:** bu bölüm açılınca kurulu uygulamaların App Store sürümleri, HTTPS Sparkle appcast'leri veya [Homebrew sürüm kataloğu](https://formulae.brew.sh/docs/api/) bir kez otomatik denetlenir. Chrome, Spotify, Discord, Claude, VS Code ve diğer eşleşen uygulamalar için Homebrew kurulumu gerekmez; yalnızca küçük uygulama metadata cevabı okunur, paket veya komut çalıştırılmaz. Katalog eşleşmesi tam bundle kimliğiyle doğrulanır; beta, aynı adlı başka uygulama, karşılaştırılamayan sürüm ve uyumsuz katalog kaydı güncelleme sayılmaz. Mac desteğini belirten birleşik App Store ürünleri de tanınır. Güncelleme bulunanlar varsayılan olarak ayrı listelenir; güncel, desteklenmeyen ve denetlenemeyen uygulama sayıları da gösterilir. **Tüm sonuçları göster** veya **Yalnızca güncellemeler** filtresini kapatınca bütün sonuçlar görülebilir. Kaynağı olmayan uygulama güncel olarak işaretlenmez; her uygulamanın güncelliği evrensel olarak doğrulanamaz. Sekmeye tekrar girmek tamamlanmış sonuçları yeniden sorgulamaz; **Yeniden tara** listeyi ve sürümleri yeniler. Seçtiğin uygulamalar **Seçilenleri onayla… → Onayla ve Aç** sonrasında geliştiricinin indirme veya App Store sayfasına yönlendirilir. Tarama indirme başlatmaz, otomatik seçim yapmaz ve paketleri sessizce değiştirmez. App Store kurulumunu mağazada, diğer kurulumları uygulamanın imzalı güncelleyicisinde veya yayımladığı indirme üzerinden tamamlarsın. App Store bölgesi nedeniyle bulunamayan uygulamalar mağazada denetlenebilir. Apple katalog sorguları [yaklaşık 20/dakika sınırına](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/Searching.html) uygun şekilde yalnızca aktif tarama sırasında aralıklı gönderilir.

Tarama ana arayüzden ayrı, iptal edilebilir bir görevde yapılır; güncelleyici bölümünden çıkınca tarama iptal edilir, pencere kapanınca görev ve iki çalışma durumu gözlemcisi bırakılır. Timer, sürekli disk taraması ve periyodik güncelleme sorgusu yoktur. Tarama ve kullanıcı tarafından başlatılan indirme sırasında işlem ve disk/ağ maliyeti oluşur.

Bakım kontrolü: `./Scripts/check-maintenance.sh`. İsteğe bağlı gerçek sürüm kaynağı kontrolü: `OPENISLAND_UPDATE_CHECK=1 ./Scripts/check-maintenance.sh` (Wireshark ve Xcode kuruluysa yalnızca sürüm bilgilerini okur).

Ses işleme ve gözlemci yaşam döngüsü kontrolü: `./Scripts/check-controls.sh`. Sistem ölçümleri ve kapandıktan sonra görevlerin durması: `./Scripts/check-system.sh`. Sıcaklık, parlaklık ve klavye ışığı desteği macOS sürümüne ve donanıma bağlıdır; Ayarlar → Modüller'den kapatılabilir.

Dock önizlemelerinin olay süzme ve gözlemci yaşam döngüsü: `./Scripts/check-dock-previews.sh`.
Mevcut erişim izinleriyle üç geçici test penceresinde gerçek görüntü ve küçültülmüş pencereye geçiş: `./Scripts/check-dock-previews.sh --live` (imleci kullanır ve test bitince eski yerine döndürür). Dock sağda/solda ve çoklu ekran yerleşimleri ayrıca saf geometri testleriyle doğrulanır. macOS'un görüntüsünü paylaşmadığı korumalı pencerelerde başlıkla seçim kullanılabilir.

## İzinler

Hiçbiri zorunlu değildir; izin verilmeyen özellik sessizce geriler. Menü çubuğundaki kapsül simgesi ›
**Ayarlar… › Sistem Erişimi** sekmesi her iznin durumunu (İzin verildi / İzin verilmedi / Kullanımda
sorulur / Desteklenmiyor) ve nedenini gösterir:

- **Erişilebilirlik**: Dock simgelerini/pencerelerini tanımak ve seçili pencereye geçmek, son pencerenin kırmızı düğmesinde normal çıkış istemek, ⌘C/⌘X pano olayları için.
- **Ekran erişimi**: yalnızca Dock önizlemelerinde gösterilen pencerelerin küçük görüntülerini almak için. Ses veya video kaydedilmez; görüntü dosyaları oluşturulmaz. İzin verilmezse pencere başlıklarıyla seçim yapılabilir.
- **Kamera**: Quick Mirror için.
- **Otomasyon (Spotify, Müzik)**: parça bilgisi ve oynatma kontrolü için.
- **Takvimler / Anımsatıcılar**: yaklaşan etkinlikler ve bugünkü anımsatıcılar için.
- **Pano, Bildirimler**: pano geçmişi ve Pomodoro bildirimi için.

## macOS 15.4+ ve web oynatıcılar (isteğe bağlı)

Apple, macOS 15.4'ten itibaren "Şimdi Çalıyor" bilgisini üçüncü taraf uygulamalara kapattı.
Spotify ve Müzik AppleScript ile her zaman çalışır. YouTube veya Safari gibi web oynatıcılar için
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3) derleyin ve
çıktıları şu yapıya koyun:

```
Vendor/MediaRemoteAdapter/
├── mediaremote-adapter.pl
└── MediaRemoteAdapter.framework
```

`build-app.sh` bu klasörü paketin içine kopyalayıp imzalar; uygulama onu otomatik olarak kullanır.

## Proje yapısı

```
Sources/
├── IslandCore/            Saf mantık (AppKit yok, test edilir)
│   ├── IslandMachine.swift      Durum makinesi (reducer + efektler)
│   ├── IslandLayout.swift       Görünüm başına boyut ve köşe yarıçapları
│   ├── PowerRules.swift         Pil/şarj bildirim geçişleri
│   ├── FullscreenRules.swift    Tam ekran algılama kuralı
│   ├── LevelControl.swift       Ses seviyesi yazımı için hata politikası
│   ├── ShelfOperations.swift    Raf dosya işlemlerinin kuralları
│   ├── BackendHealth.swift      Arka uç sağlığı + sınırlı geri çekilme
│   └── CompactPulse.swift       Tahmini müzik nabzı desenleri
└── OpenIsland/
    ├── App/               Giriş noktası, DI kökü, koordinatör
    ├── Window/            NotchPanel (+ tracking area), ScreenManager, NotchWindowController
    ├── Island/            IslandViewModel (animasyon + efekt çalıştırıcı)
    ├── UI/                IslandDesign (token/yaylar), IslandShape, CA bileşenleri, görünümler
    ├── Features/          Media, HUD, Shelf, Mirror, Clipboard, Focus, Notes, Gestures, Events
    └── System/            İzinler, ayarlar, yardımcılar
Support/                   Info.plist, entitlements
Scripts/build-app.sh       .app paketleme ve imzalama
```

## Lisans

MIT — bkz. [LICENSE](LICENSE).
