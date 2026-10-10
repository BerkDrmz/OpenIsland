import AppKit
import IslandCore
import SwiftUI

/// Sistem sekmesi: sıcaklıklar · kullanım · ekran ve klavye ışığı. Sekme görünürken ölçer, kapanınca durur.
struct SystemPanel: View {
    let system: SystemMonitor

    var body: some View {
        let widths = IslandLayoutEngine.System.columnWidths
        VStack(alignment: .leading, spacing: IslandLayoutEngine.System.sectionGap) {
            HStack(alignment: .top, spacing: IslandLayoutEngine.columnGap) {
                TemperatureColumn(system: system).frame(width: widths[0], height: IslandLayoutEngine.System.columnHeight, alignment: .topLeading)
                Rectangle().fill(IslandPalette.separator).frame(width: 0.5, height: IslandLayoutEngine.System.columnHeight)
                UsageColumn(system: system).frame(width: widths[1], height: IslandLayoutEngine.System.columnHeight, alignment: .topLeading)
                Rectangle().fill(IslandPalette.separator).frame(width: 0.5, height: IslandLayoutEngine.System.columnHeight)
                ControlsColumn(system: system).frame(width: widths[2], height: IslandLayoutEngine.System.columnHeight, alignment: .topLeading)
            }
            Rectangle().fill(IslandPalette.separator).frame(height: 0.5)
            StorageSection(system: system).frame(height: IslandLayoutEngine.System.storageHeight, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { system.start() }
        .onDisappear { system.stop() }
    }
}

private struct TemperatureColumn: View {
    let system: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SICAKLIK").font(IslandType.sectionLabel).foregroundStyle(IslandPalette.tertiary).frame(height: 12, alignment: .leading)
            HStack(spacing: 8) {
                tile("CPU", system.temperatures?.cpu)
                tile("GPU", system.temperatures?.gpu)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Image(systemName: "clock").font(.system(size: 9)).accessibilityHidden(true)
                Text("Çalışma süresi \(Self.uptimeText(system.uptime))").lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(IslandType.caption2)
            .foregroundStyle(IslandPalette.secondary)
        }
    }

    private func tile(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(IslandType.caption2).foregroundStyle(IslandPalette.secondary)
            Text(value.map { "\(Int($0.rounded()))°" } ?? "—").font(IslandType.numericLarge)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(IslandPalette.fill))
        .accessibilityElement(children: .ignore)
        .help("\(title) için eşleşen sensörlerin son okumadaki en yüksek değeri. Ortalama değildir. Yaklaşık 2 saniyede yenilenir; güç tasarrufunda 4 saniye. Sensör gruplaması macOS tarafından belgelenmemiştir.")
        .accessibilityLabel("\(title) sensör grubu, son okumadaki en yüksek sıcaklık")
        .accessibilityValue(value.map { "\(Int($0.rounded())) derece" } ?? "okunamıyor")
    }

    private static func uptimeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400, hours = total % 86_400 / 3_600, minutes = total % 3_600 / 60
        if days > 0 { return "\(days)g \(hours)s" }
        return hours > 0 ? "\(hours)s \(minutes)dk" : "\(minutes)dk"
    }
}

private struct UsageColumn: View {
    let system: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DONANIM").font(IslandType.sectionLabel).foregroundStyle(IslandPalette.tertiary).frame(height: 12, alignment: .leading)
            row("CPU", fraction: system.cpu, text: system.cpu.map(Self.percent) ?? "—")
            row("GPU", fraction: system.gpu, text: system.gpu.map(Self.percent) ?? "—")
            if let memory = system.memory {
                row("Bellek", fraction: memory.usedFraction, text: "\(Self.bytes(memory.usedBytes)) / \(Self.bytes(memory.totalBytes))",
                    tint: pressureTint)
                    .help("Mac'in toplam RAM kullanımıdır; OpenIsland'in kendi kullanımı değildir. Bellek basıncı: \(pressureDescription).")
                    .accessibilityHint("Mac'in toplam RAM kullanımı. Bellek basıncı: \(pressureDescription).")
                Text("Sıkıştırılmış \(Self.bytes(memory.compressedBytes)) · Takas \(Self.bytes(memory.swapUsedBytes))")
                    .font(IslandType.caption2).foregroundStyle(IslandPalette.tertiary).lineLimit(1).minimumScaleFactor(0.8)
            } else {
                row("Bellek", fraction: nil, text: "—")
            }
            Spacer(minLength: 0)
        }
    }

    private var pressureTint: Color? {
        switch system.pressure {
        case .normal: nil
        case .warning: .yellow
        case .critical: .red
        }
    }

    private var pressureDescription: String {
        switch system.pressure {
        case .normal: "Normal"
        case .warning: "Yüksek"
        case .critical: "Kritik"
        }
    }

    private func row(_ title: String, fraction: Double?, text: String, tint: Color? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title).font(IslandType.caption).foregroundStyle(IslandPalette.secondary).frame(width: 38, alignment: .leading)
            LevelBar(level: fraction ?? 0, tint: tint ?? .white).frame(height: 4)
            Text(text).font(IslandType.numericSmall).foregroundStyle(IslandPalette.primary)
                .lineLimit(1).minimumScaleFactor(0.7).frame(width: 66, alignment: .trailing)
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) kullanımı")
        .accessibilityValue(text)
    }

    private static func percent(_ value: Double) -> String { "%\(Int((value * 100).rounded()))" }

    private static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: Int64(value))
    }
}

private struct ControlsColumn: View {
    let system: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EKRAN").font(IslandType.sectionLabel).foregroundStyle(IslandPalette.tertiary).frame(height: 12, alignment: .leading)
            slider("Parlaklık", symbol: "sun.max.fill", value: system.brightness, enabled: system.canAdjustBrightness,
                   set: system.setBrightness)
            slider("Klavye ışığı", symbol: "light.max", value: system.keyboardBacklight, enabled: system.canAdjustKeyboard,
                   set: system.setKeyboardBacklight)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func slider(_ title: String, symbol: String, value: Float?, enabled: Bool, set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IslandPalette.secondary).frame(width: 14).accessibilityHidden(true)
            if let value, enabled {
                Slider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }), in: 0...1,
                       onEditingChanged: { system.setAdjusting($0) })
                    .controlSize(.small)
                    .tint(IslandPalette.primary)
                    .accessibilityLabel(title)
                    .accessibilityValue("%\(Int((value * 100).rounded()))")
            } else {
                Text("\(title): kullanılamıyor").font(IslandType.caption2).foregroundStyle(IslandPalette.tertiary).lineLimit(1)
            }
        }
        .frame(height: 22)
    }
}


private struct StorageSection: View {
    let system: SystemMonitor
    @State private var selectedID = "/"
    private var selected: StorageVolume? { system.storage.first { $0.id == selectedID } ?? system.storage.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("DEPOLAMA").font(IslandType.sectionLabel).foregroundStyle(IslandPalette.tertiary)
                if let volume = selected {
                    if system.storage.count > 1 {
                        Picker("Disk", selection: Binding(get: { volume.id }, set: { selectedID = $0 })) {
                            ForEach(system.storage) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().pickerStyle(.menu).controlSize(.mini).frame(maxWidth: 145)
                        .help("Dahili veya harici disk seç")
                    } else {
                        Label(volume.name, systemImage: volume.isInternal ? "internaldrive" : "externaldrive")
                            .font(IslandType.caption).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button { system.refreshStorage() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Depolama bilgisini yenile").accessibilityLabel("Depolama bilgisini yenile")
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Storage-Settings.extension") { NSWorkspace.shared.open(url) }
                } label: { Image(systemName: "arrow.up.forward.square") }
                    .help("macOS Depolama ayarlarını aç").accessibilityLabel("macOS Depolama ayarlarını aç")
            }
            .buttonStyle(.plain).font(IslandType.caption).frame(height: 18)
            if let volume = selected {
                HStack(spacing: 10) {
                    LevelBar(level: volume.usedFraction).frame(height: 4)
                    Text("\(bytes(volume.used)) / \(bytes(volume.total))").font(IslandType.numericSmall)
                    Text("\(bytes(volume.available)) boş").font(IslandType.numericSmall).foregroundStyle(IslandPalette.secondary)
                }
                .frame(height: 18)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(volume.name) depolama alanı")
                .accessibilityValue("\(bytes(volume.used)) kullanılıyor, \(bytes(volume.available)) boş, \(bytes(volume.total)) toplam")
            } else {
                Text("Depolama bilgisi okunuyor veya disk kullanılamıyor.")
                    .font(IslandType.caption2).foregroundStyle(IslandPalette.secondary).frame(height: 18)
            }
        }
        .onChange(of: system.storage) { _, volumes in
            if !volumes.contains(where: { $0.id == selectedID }) { selectedID = volumes.first?.id ?? "/" }
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
