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
                    .disabled(controller.busy)
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
                        Button("Listeyi yenile", systemImage: "arrow.clockwise", action: controller.loadApplications)
                            .disabled(controller.busy)
                    }
                }
                Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                switch controller.section {
                case .uninstaller: uninstallContent
                case .cleaner: cacheContent
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
