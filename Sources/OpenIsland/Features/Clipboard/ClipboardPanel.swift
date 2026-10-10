import IslandCore
import SwiftUI

/// Pano geçmişi (sol) + renk damlalığı ve son renkler (sağ). Gövde öğe sayısına göre büyür (en fazla
/// `IslandLayoutEngine.Clipboard.visibleRows` satır; fazlası listede kayar).
struct ClipboardPanel: View {
    let history: ClipboardHistory
    let colors: ColorPickerService

    var body: some View {
        HStack(alignment: .top, spacing: IslandLayoutEngine.columnGap) {
            historyColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(IslandPalette.separator).frame(width: 0.5)
            ColorColumn(colors: colors).frame(width: IslandLayoutEngine.Clipboard.colorColumnWidth)
        }
    }

    @ViewBuilder
    private var historyColumn: some View {
        if history.isBlockedBySystem {
            placeholder(symbol: "hand.raised.fill", title: "Pano erişimi engellendi",
                        detail: "Sistem Ayarları › Gizlilik ve Güvenlik bölümünden OpenIsland'in panoya erişimine izin verin.")
        } else if history.items.isEmpty {
            placeholder(symbol: "doc.on.clipboard", title: "Pano geçmişi boş",
                        detail: history.isRunning ? "Kopyaladığınız metin, görsel ve dosyalar burada görünür." : "Pano geçmişi Ayarlar'dan kapatılmış.")
        } else {
            VStack(spacing: 6) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(history.items) { item in
                            ClipRow(item: item) { history.copy(item) } onDelete: { history.remove(item) }
                        }
                    }
                }
                HStack {
                    Text("Tıkla: kopyala").font(IslandType.caption2).foregroundStyle(IslandPalette.tertiary)
                    Spacer()
                    Button("Geçmişi temizle", role: .destructive, action: history.clear)
                        .buttonStyle(.plain)
                        .font(IslandType.caption2)
                }
            }
        }
    }

    private func placeholder(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(IslandPalette.tertiary)
            Text(title).font(IslandType.bodyEmphasized)
            Text(detail).font(IslandType.caption).foregroundStyle(IslandPalette.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Ekrandan renk damlalığı (`NSColorSampler`) ve son seçilen renkler; tıklayınca HEX kopyalanır.
private struct ColorColumn: View {
    let colors: ColorPickerService

    var body: some View {
        VStack(alignment: .leading, spacing: IslandSpacing.s) {
            Button(action: colors.pick) {
                Label("Damlalık", systemImage: "eyedropper.halffull")
                    .font(IslandType.bodyEmphasized)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: IslandSpacing.cardRadius - 4, style: .continuous).fill(IslandPalette.fill))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ekrandan renk seç, HEX kodunu kopyala")

            if colors.recentColors.isEmpty {
                Text("Seçilen renkler burada")
                    .font(IslandType.caption2)
                    .foregroundStyle(IslandPalette.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                // Tek sıra: son renkler yatay kayar (yükseklik renk sayısıyla büyümez).
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(colors.recentColors, id: \.self) { hex in
                            Button { colors.copy(hex) } label: {
                                Circle()
                                    .fill(Color(hex: hex) ?? .clear)
                                    .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .help(hex)
                            .accessibilityLabel("Renk \(hex), kopyala")
                        }
                    }
                }
                .frame(height: 20)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 10) {
            preview
            Spacer(minLength: 8)
            if isHovering {
                Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 10)) }
                    .accessibilityLabel("Geçmişten sil")
                    .buttonStyle(.plain)
                    .foregroundStyle(IslandPalette.secondary)
            }
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovering || didCopy ? IslandPalette.primary : IslandPalette.tertiary)
                .accessibilityHidden(true)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: IslandSpacing.cardRadius - 4, style: .continuous).fill(isHovering ? IslandPalette.fillHover : IslandPalette.fill))
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(IslandMotion.control) { isHovering = hovering } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Panoya kopyalar")
        // Silme düğmesi yalnızca hover'da görünür; klavye, VoiceOver ve sağ tık için aynı eylemler her zaman açık.
        .accessibilityAction(.default, copy)
        .accessibilityAction(named: "Geçmişten sil", onDelete)
        .contextMenu {
            Button("Kopyala", action: copy)
            Button("Geçmişten sil", role: .destructive, action: onDelete)
        }
        .onTapGesture(perform: copy)
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(IslandMotion.control) { didCopy = false }
        }
    }

    private func copy() {
        onCopy()
        withAnimation(IslandMotion.control) { didCopy = true }
        // The view-scoped task is cancelled when this row disappears.

    }

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .text(let text):
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(IslandType.body)
                .lineLimit(1)
        case .image(let data):
            HStack(spacing: 8) {
                if let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 30, height: 20).clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text("Görsel").font(IslandType.body)
            }
        case .files(let urls):
            Label(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) dosya", systemImage: "doc")
                .font(IslandType.body)
                .lineLimit(1)
        }
    }
}
