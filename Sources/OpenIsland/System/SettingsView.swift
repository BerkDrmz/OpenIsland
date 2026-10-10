import AppKit
import IslandCore
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    let environment: AppEnvironment

    var body: some View {
        TabView {
            // Önizleme bu Mac'in ölçülen çentiğiyle çizilir (15" Air'de 185 × 33,5; 14"/16" Pro'da 185 × 32).
            GeneralSettings(preferences: environment.preferences,
                            notchSize: environment.screens.screens.first { $0.isBuiltIn && $0.hasNotch }?.notchRect?.size)
                .tabItem { Label("Genel", systemImage: "gearshape") }
            ModuleSettings(preferences: environment.preferences)
                .tabItem { Label("Modüller", systemImage: "square.grid.2x2") }
            PermissionSettings(environment: environment)
                .tabItem { Label("Sistem Erişimi", systemImage: "lock.shield") }
        }
        .frame(width: 560, height: 600)
    }
}

extension FullscreenBehavior {
    var title: String {
        switch self {
        case .smart: "Akıllı"
        case .alwaysShow: "Her zaman göster"
        case .alwaysHide: "Her zaman gizle"
        }
    }

    var summary: String {
        switch self {
        case .smart: "Tam ekranda canlı etkinlikler ve bildirimler gizlenir (kritik pil uyarısı hariç). İmleç çentiğe gidince ada yine açılır."
        case .alwaysShow: "Tam ekran yok sayılır; ada her zamanki gibi davranır."
        case .alwaysHide: "Tam ekranda ada açılmaz. Yalnızca jestle yapılan ses değişikliği görünür."
        }
    }
}

/// Varsayılanlar çoğu kullanıcı için doğru olacak şekilde seçildi; ayrıntılı ayarlar ön ayarların arkasında.
private struct GeneralSettings: View {
    @Bindable var preferences: Preferences
    let notchSize: CGSize?

    var body: some View {
        Form {
            Section {
                IslandPreview(motionStyle: preferences.motionStyle, nookWidgetCount: preferences.nookLayout.widgetCount,
                              expandedSurfaceSize: preferences.expandedSurfaceSize,
                              notchSize: notchSize ?? IslandPreview.typicalNotch)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            } footer: {
                Text("Önizleme: üzerine gel veya tıkla; seçili hareket stiliyle açılır.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Açık ada boyutu", selection: $preferences.expandedSurfaceSize) {
                    Text("Kompakt").tag(ExpandedSurfaceSize.compact)
                    Text("Standart").tag(ExpandedSurfaceSize.standard)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Açık ada görünümü")
            } footer: {
                Text("Çentiğe kesintisiz bağlı yüzey. Kompakt görünüm çevredeki boşluğu azaltır; sekmeler ve içerikler aynı boyutta kalır.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Üzerine gelince aç", selection: $preferences.hoverPreset) {
                    ForEach(HoverPreset.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Hareket", selection: $preferences.motionStyle) {
                    ForEach(MotionStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Dokunsal geri bildirim (Force Touch trackpad)", isOn: $preferences.hapticsEnabled)
                Toggle("Düşük Güç Modu'nda pil tasarrufu", isOn: $preferences.energySaving)
                Toggle("Müzik nabzı albüm renginde", isOn: $preferences.albumColoredPulse)
            } header: {
                Text("Ada")
            } footer: {
                Text("Hızlı: 60 ms bekleme. Canlı: hızlı açılır (~0,22 sn) ve kapanır (~0,18 sn). Sakin: yumuşak ve yavaş. Sistemdeki \"Hareketi Azalt\" ayarı açıksa hareket her zaman azaltılmış olur. Pil tasarrufu: Düşük Güç Modu açıkken veya Mac ısındığında müzik nabzı sabitlenir ve hareket kısalır; seçtiğin Hareket ayarı değişmez.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Gösterilecek ekran", selection: $preferences.displayTarget) {
                    ForEach(DisplayTarget.allCases) { Text($0.title).tag($0) }
                }
                Picker("Tam ekranda", selection: $preferences.fullscreenBehavior) {
                    ForEach(FullscreenBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Ekranlar")
            } footer: {
                Text(preferences.fullscreenBehavior.summary + " Çentiksiz ekranlarda ada, menü çubuğunun altında yüzen bir kapsüldür.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Geçici bildirimler") {
                Toggle("Ağ bağlantısı kesildi / geri geldi", isOn: $preferences.networkNotices)
                Toggle("Harici ekran ve ekran düzeni değişikliği", isOn: $preferences.displayNotices)
                Toggle("Pil ve şarj (adaptör, %20, %10, %100)", isOn: $preferences.batteryNotices)
                Toggle("Ses aygıtı bağlandı / ayrıldı (AirPods, kulaklık)", isOn: $preferences.audioDeviceNotices)
                Toggle("Parça değişimi", isOn: $preferences.trackChangeNotices)
                Toggle("Toplantı hatırlatması (5 dk önce)", isOn: $preferences.meetingReminders)
                Toggle("Kilit açıldı", isOn: $preferences.unlockNotices)
            }

            Section {
                Toggle("Dock'ta pencere önizlemeleri", isOn: $preferences.dockWindowPreviews)
                Text("Uygulama simgesinde durunca açık pencereleri gösterir; tıklayınca seçili pencereye geçer. Erişilebilirlik ve ekran erişimi gerekir. Görüntüler kaydedilmez; sürekli ekran yakalama yapılmaz.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Son pencereyi kırmızı düğmeden kapatınca uygulamadan çık", isOn: $preferences.quitOnLastWindowClose)
                Text("Erişilebilirlik izni gerekir. Diğer açık pencereler ve kaydetme uyarıları korunur; Finder kapanmaz.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Klavye kısayolu ⌃⌥⌘I ile aç/kapat", isOn: $preferences.globalHotKey)
                Toggle("Oturum açılışında başlat", isOn: $preferences.launchAtLogin)
                    .disabled(!AppPaths.isRunningAsBundle)
                if preferences.launchAtLoginStatus == .requiresApproval {
                    Button("Oturum Açma Öğeleri’nde Onayla") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let error = preferences.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Demo modu (ekran kaydı ve sunum)", isOn: $preferences.demoMode)
            } header: {
                Text("Sistem")
            } footer: {
                Text("Demo modunda ada kendiliğinden kapanmaz, duraklatılan müzik kanatta kalır ve tam ekranda da görünür. Adayı kapatmak için ona sağ tıkla veya ⌃⌥⌘I kısayolunu kullan; demo modu da aynı menüden açılıp kapanır. Saklanmaz: uygulama yeniden açılınca kapalı başlar.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { preferences.refreshLaunchAtLogin() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            preferences.refreshLaunchAtLogin()
        }
    }
}

private struct ModuleSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Picker("Nook düzeni", selection: $preferences.nookLayout) {
                    ForEach(NookLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(preferences.nookLayout.summary).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Pano geçmişi ve renk seçici", isOn: $preferences.clipboardHistoryEnabled)
                Toggle("Odak: zamanlayıcı, takvim, anımsatıcılar", isOn: $preferences.focusModule)
                Toggle("Notlar ve uygulama kısayolları", isOn: $preferences.notesModule)
                Toggle("Ayna (kamera önizlemesi)", isOn: $preferences.mirrorModule)
                Toggle("Sistem: CPU, GPU, bellek, sıcaklık, parlaklık", isOn: $preferences.systemModule)
            } header: {
                Text("Sekmeler")
            } footer: {
                Text("Kapalı modülün sekmesi gösterilmez ve arka planda hiçbir şey çalıştırmaz. Nook, Medya ve Raf her zaman açıktır.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Sistem entegrasyonu") {
                Toggle("Sıcaklık, parlaklık ve klavye ışığı", isOn: $preferences.systemPrivateSensors)
                Toggle("Trackpad jestleri (yatay: parça, dikey: ses)", isOn: $preferences.gesturesEnabled)
                Toggle("Medya jestini ters çevir (sağa kaydır: sonraki parça)", isOn: $preferences.reversesMediaSwipe)
                    .disabled(!preferences.gesturesEnabled)
                Toggle("İndirme / aktarım canlı etkinliği", isOn: $preferences.transferActivity)
            }
        }
        .formStyle(.grouped)
    }
}

/// Tüm izinler tek listede. Durumlar yalnızca bu ekran açıldığında ve uygulama yeniden etkinleştiğinde
/// (kullanıcı Sistem Ayarları'ndan döndüğünde) okunur.
private struct PermissionSettings: View {
    let environment: AppEnvironment

    private var permissions: PermissionsCenter { environment.permissions }

    var body: some View {
        Form {
            Section {
                ForEach(permissions.entries) { entry in
                    PermissionRow(entry: entry) {
                        permissions.resolve(entry.kind, reminders: environment.reminders, calendar: environment.calendar)
                    }
                }
            } footer: {
                Text("Hiçbir izin zorunlu değildir. İzin verilmeyen özellik sessizce geriler; uygulamanın geri kalanı etkilenmez.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Ada penceresi") {
                SpacePresentationRow(status: SpacePresentationController.shared.status)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: permissions.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }
}

/// Space/tam ekran geçişlerindeki durum (bkz. `SpacePresentationController`): bir macOS güncellemesinden sonra
/// adanın hangi yöntemle ve nasıl çalıştığı tek bakışta görülür. Olay güdümlüdür; yalnızca doğrulamada değişir.
private struct SpacePresentationRow: View {
    let status: SpacePresentationStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Space geçişleri")
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(isPinned ? Color.green : Color.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private var behavior: SpaceBehavior? {
        if case .settled(_, let behavior) = status { behavior } else { nil }
    }

    private var provider: SpaceProviderKind? {
        if case .settled(let provider, _) = status { provider } else { nil }
    }

    private var isPinned: Bool { behavior == .pinned }

    private var title: String {
        switch behavior {
        case nil: "Denetleniyor"
        case .pinned: "Ada sabit"
        case .unverified: "Doğrulanamadı"
        case .slides: "Yedek mod"
        case .hidden: "Ada görünmüyor"
        }
    }

    private var symbol: String {
        switch behavior {
        case nil: "clock"
        case .pinned: "checkmark.circle.fill"
        case .unverified: "questionmark.circle"
        case .slides: "exclamationmark.circle"
        case .hidden: "xmark.octagon"
        }
    }

    private var method: String {
        switch provider {
        case .privateSpace: "ayrı WindowServer Space'i"
        case .publicStationary: "yalnızca public AppKit"
        case .safeFallback: "güvenli yedek"
        case nil: ""
        }
    }

    private var detail: String {
        switch behavior {
        case nil:
            "Ada penceresinin davranışı doğrulanıyor."
        case .pinned:
            "Dört parmakla kaydırmada, tam ekrana giriş ve çıkışta ve Mission Control'de ada yerinde kalır (\(method))."
        case .unverified:
            "Ada görünür; bu macOS sürümünde sabit kaldığı doğrulanamıyor (\(method))."
        case .slides:
            "Ada görünür ama Space değişirken kayabilir (\(method)). Uyanma, kilit açma veya ekran değişiminde yeniden denenir."
        case .hidden:
            "Ada bir ekranda görünmüyor; uyanma, kilit açma veya ekran değişiminde yeniden denenir."
        }
    }
}

private struct PermissionRow: View {
    let entry: PermissionsCenter.Entry
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                Text(entry.reason)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // Durum renk + simge + metin ile verilir ("Renksiz Ayırt Et" için renk tek başına anlam taşımaz).
            Label(entry.state.label, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(entry.state == .granted ? Color.green : Color.secondary)
                .fixedSize()
            if entry.isRequesting {
                Text("İzin bekleniyor…").font(.caption).foregroundStyle(.secondary)
            } else if let actionTitle {
                Button(actionTitle, action: action)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch entry.state {
        case .granted: "checkmark.circle.fill"
        case .notGranted: "xmark.circle"
        case .askOnUse: "questionmark.circle"
        case .unsupported: "minus.circle"
        case .unavailable: "exclamationmark.circle"
        }
    }

    private var actionTitle: String? {
        switch entry.state {
        case .granted, .unsupported:
            nil
        case .askOnUse:
            // Pano için önceden izin istenemez; yalnızca ilgili bölme açılabilir.
            entry.kind == .clipboard ? "Ayarlar" : "İzin İste"
        case .notGranted:
            "Ayarları Aç"
        case .unavailable:
            "Yeniden Dene"
        }
    }
}
