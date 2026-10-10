import AppKit
import IslandCore
import SwiftUI

/// A normal native window gives file review room without altering notch geometry or its tabs.
struct MaintenanceView: View {
    @Bindable var controller: MaintenanceController

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Araçlar", systemImage: "wrench.and.screwdriver").font(.headline).padding(.bottom, 12)
                ForEach(MaintenanceController.Section.allCases) { section in
                    Button { controller.select(section) } label: {
                        Label(section.rawValue, systemImage: section.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(controller.section == section ? Color.accentColor.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.busy && !controller.isScanningUpdates)
                    .accessibilityAddTraits(controller.section == section ? .isSelected : [])
                }
                Spacer()
                Text("Yalnızca ihtiyaç olduğunda çalışır.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16).frame(width: 220).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(controller.section.rawValue).font(.title2.bold())
                    Spacer()
                    if controller.section != .cleaner {
                        Button(controller.section == .updater ? "Yeniden tara" : "Listeyi yenile", systemImage: "arrow.clockwise", action: controller.loadApplications)
                            .disabled(controller.busy)
                    }
                }
                Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                switch controller.section {
                case .uninstaller: uninstallContent
                case .cleaner: cacheContent
                case .updater: updaterContent
                }
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    if controller.busy { ProgressView().controlSize(.small) }
                    ScrollView {
                        Text(controller.status.isEmpty ? "Hazır." : controller.status)
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 54)
                    if controller.busy { Button("Durdur", action: controller.cancel) }
                }
            }
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var description: String {
        switch controller.section {
        case .uninstaller:
            "Uygulamayı seç, kalıntılarını tara ve kaldırılacak öğeleri denetle. Kişisel veriler ve ada göre eşleşen klasörler ayrıca seçilir. Paylaşılan grup klasörlerine ve sistem yardımcılarına dokunulmaz."
        case .cleaner:
            "Kullanıcı önbelleklerini isteğe bağlı tara. Açık uygulamalara ait bilinen önbellekler korunur. Önce ilgili uygulamaları kapat; önbellekler daha sonra yeniden oluşabilir."
        case .updater:
            "Bu bölümü açınca mağaza, uygulama kaynağı ve ek sürüm kataloğu denetlenir. Güncelleme bulunanları seçip onayla; indirme veya mağaza sayfaları açılır. Sürümü doğrulanamayanlar güncel sayılmaz."
        }
    }

    private var uninstallContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Uygulama", selection: Binding(get: { controller.applicationID ?? "" }, set: { id in
                    if let app = controller.applications.first(where: { $0.id == id }) { controller.choose(app) }
                })) {
                    if controller.applications.isEmpty { Text("Uygulama bulunamadı").tag("") }
                    ForEach(controller.applications) { Text("\($0.name) — \($0.version)").tag($0.id) }
                }
                .disabled(controller.busy)
                Button("Kalıntıları tara", systemImage: "magnifyingglass", action: controller.scan)
                    .disabled(controller.busy || controller.selectedApplication == nil)
            }
            if let app = controller.selectedApplication {
                HStack {
                    Text(app.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(app.url.path)
                    Spacer()
                    if controller.runningBundleIDs.contains(app.bundleID) {
                        Label("Önce uygulamadan çık", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            fileList
            trashControls
        }
    }

    private var cacheContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("~/Library/Caches", systemImage: "folder").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Önbellekleri tara", systemImage: "magnifyingglass", action: controller.scan).disabled(controller.busy)
            }
            fileList
            trashControls
        }
    }

    private var fileList: some View {
        Group {
            if controller.files.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: controller.section.symbol).font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("Dosyaları görmek için taramayı başlat.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(controller.files) { file in
                    HStack(alignment: .center, spacing: 10) {
                        Toggle(isOn: Binding(get: { controller.selectedFiles.contains(file.id) }, set: { selected in
                            if selected { controller.selectedFiles.insert(file.id) } else { controller.selectedFiles.remove(file.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(file.url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1)
                                    Text(kind(file)).font(.caption).foregroundStyle(file.containsPersonalData ? .orange : .secondary)
                                }
                                Text(file.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(file.url.path)
                                if controller.blocked(file) { Text("Açık uygulama: korunuyor").font(.caption).foregroundStyle(.orange) }
                                else if !file.verifiedIdentity, controller.section == .uninstaller {
                                    Text("Ad eşleşmesi; başka bir uygulama ile paylaşılabilir.").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox).disabled(controller.busy || controller.blocked(file))
                        Spacer(minLength: 0)
                        Text((file.fullyMeasured ? "" : "≥ ") + MaintenanceController.size(file.bytes))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                            .help(file.fullyMeasured ? "Dosyaların toplam boyutu; fiziksel boşalacak alan farklı olabilir." : "Bazı dosyalar okunamadı; bilinen boyut gösteriliyor.")
                        Button { controller.reveal(file) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Finder'da göster").accessibilityLabel("\(file.url.lastPathComponent) öğesini Finder'da göster")
                    }.padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var trashControls: some View {
        HStack {
            Text("\(controller.selectedFiles.count) seçili · \(MaintenanceController.size(controller.selectedBytes))").font(.callout).foregroundStyle(.secondary)
            Spacer()
            if controller.section == .cleaner {
                Button("Tümünü seç", action: controller.selectAllCaches)
                    .disabled(controller.busy || controller.selectableCacheCount == 0)
                    .help("Korunan ve açık uygulamalara ait bilinen önbellekleri seçmez")
            }
            Button("Seçimi kaldır") { controller.selectedFiles = [] }.disabled(controller.busy || controller.selectedFiles.isEmpty)
            Button("Çöp Sepeti'ne Taşı", systemImage: "trash", action: controller.confirmTrash)
                .disabled(controller.busy || controller.selectedFiles.isEmpty)
        }
    }

    private var updaterContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(controller.updateSummary).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if controller.onlyAvailableUpdates {
                    Button("Tüm sonuçları göster") { controller.onlyAvailableUpdates = false }
                        .font(.caption)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 10) {
                    TextField("Uygulama ara", text: $controller.search).textFieldStyle(.roundedBorder)
                    Toggle("Yalnızca güncellemeler", isOn: $controller.onlyAvailableUpdates).font(.caption)
                        .onChange(of: controller.onlyAvailableUpdates) { _, onlyAvailable in
                            if onlyAvailable, controller.selectedApplication.map({ controller.updates[$0.id]?.status != .available }) == true {
                                controller.applicationID = controller.availableUpdateApplications.first?.id
                            }
                        }
                    if controller.visibleApplications.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: controller.isScanningUpdates ? "magnifyingglass" : "checkmark.circle").font(.title2).foregroundStyle(.secondary)
                            Text(controller.isScanningUpdates ? "Uygulamalar denetleniyor…" : "Listelenecek güncelleme yok.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Text("Tüm sonuçlar için filtreyi kapat.").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(controller.visibleApplications) { app in
                            HStack(spacing: 8) {
                                if controller.updates[app.id]?.status == .available {
                                    Toggle("\(app.name) güncellemesini seç", isOn: Binding(get: { controller.selectedUpdates.contains(app.id) }, set: { selected in
                                        if selected { controller.selectedUpdates.insert(app.id) } else { controller.selectedUpdates.remove(app.id) }
                                    })).labelsHidden().toggleStyle(.checkbox)
                                } else { Image(systemName: app.isStore ? "bag" : "app").foregroundStyle(.secondary) }
                                Button { controller.choose(app) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name).lineLimit(1)
                                        Text(controller.updates[app.id]?.message ?? app.version).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(controller.busy && !controller.isScanningUpdates)
                            }
                            .padding(6).contentShape(Rectangle())
                            .background(controller.applicationID == app.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }.frame(width: 225)
                VStack(alignment: .leading, spacing: 14) {
                    if let app = controller.selectedApplication {
                        Text(app.name).font(.title3.bold())
                        Text("Kurulu sürüm: \(app.version)").font(.callout)
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Label(app.isStore ? "App Store" : app.appcast?.scheme == "https" ? "Sparkle güncelleme kaynağı" : "Ek sürüm kataloğu",
                              systemImage: app.isStore ? "bag" : "arrow.down.app").font(.callout).foregroundStyle(.secondary)
                        if let update = controller.updates[app.id] {
                            Text(update.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                            if update.destination != nil, update.status == .available {
                                Button("Bu güncellemeyi onayla…", systemImage: "arrow.down.to.line", action: controller.openUpdate)
                                    .disabled(controller.busy)
                            }
                        }
                        Button("Sürümü denetle", systemImage: "arrow.clockwise", action: controller.checkUpdate).disabled(controller.busy)
                        Button("Uygulamada aç", systemImage: "arrow.up.forward.app", action: controller.openApplication)
                    } else { Text(controller.isScanningUpdates ? "Tarama bitince güncelleme bulunan uygulamalar burada listelenecek." : "Ayrıntılar için listeden bir uygulama seç.").foregroundStyle(.secondary) }
                    Spacer()
                    Button("App Store güncellemeleri", systemImage: "bag", action: controller.openStore)
                    Text("İndirme ve kurulum yalnızca sen başlattığında yapılır.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("\(controller.approvedUpdateApplications.count) güncelleme seçili").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Tümünü seç", action: controller.selectAllUpdates).disabled(controller.busy || controller.availableUpdateApplications.isEmpty)
                Button("Seçilenleri onayla…", action: controller.confirmSelectedUpdates)
                    .disabled(controller.busy || controller.approvedUpdateApplications.isEmpty)
            }
        }.frame(maxHeight: .infinity)
    }

    private func kind(_ file: MaintenanceFile) -> String {
        if file.isApplication { return "Uygulama" }
        switch file.kind {
        case .cache: return "Önbellek"
        case .preferences: return "Tercihler"
        case .logs: return "Günlükler"
        case .savedState: return "Pencere durumu"
        case .data: return "Kişisel veriler"
        case nil: return "Dosya"
        }
    }
}
