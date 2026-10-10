import IslandCore
import SwiftUI

/// Quick Notes (sol) + App/Shortcuts başlatıcı (sağ). Ölçüler `IslandLayoutEngine.Notes` ile ortaktır:
/// gövde not alanı ve başlatıcının gerçekten kullandığı kadar açılır.
struct NotesPanel: View {
    @Bindable var notes: NotesStore
    let launcher: LauncherStore
    @State private var isShowingShortcuts = false

    var body: some View {
        HStack(alignment: .top, spacing: IslandLayoutEngine.Notes.columnSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hızlı Not").font(IslandType.sectionLabel).foregroundStyle(IslandPalette.secondary)
                TextEditor(text: $notes.text)
                    .font(IslandType.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: IslandLayoutEngine.Notes.editorHeight, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: IslandSpacing.cardRadius - 4, style: .continuous).fill(IslandPalette.fill))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Başlatıcı").font(IslandType.sectionLabel).foregroundStyle(IslandPalette.secondary)
                    Spacer()
                    Menu {
                        Button("Uygulama ekle…", action: launcher.addApplication)
                        Button("Bağlantı ekle…", action: launcher.addLink)
                        Menu("Kısayol sabitle") {
                            if launcher.availableShortcuts.isEmpty {
                                Text("Kısayol bulunamadı")
                            }
                            ForEach(launcher.availableShortcuts, id: \.self) { name in
                                Button(name) { launcher.pinShortcut(name) }
                            }
                        }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).accessibilityLabel("Başlatıcıya ekle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                // 3 sütun, en fazla 2 sıra görünür; fazlası dikey kayar (öğe gizlenmez).
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(IslandLayoutEngine.Notes.launcherCell),
                                                                 spacing: IslandLayoutEngine.Notes.launcherSpacing),
                                             count: IslandLayoutEngine.Notes.launcherColumns),
                              spacing: IslandLayoutEngine.Notes.launcherSpacing) {
                        ForEach(launcher.items) { item in
                            LauncherTile(item: item, icon: launcher.icon(for: item)) {
                                launcher.launch(item)
                            } onRemove: {
                                launcher.remove(item)
                            }
                        }
                    }
                }
                .scrollDisabled(launcher.items.count <= IslandLayoutEngine.Notes.launcherColumns * IslandLayoutEngine.Notes.launcherMaxRows)
            }
            .frame(width: IslandLayoutEngine.Notes.launcherWidth)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .task { await launcher.refreshShortcutsIfNeeded() }
    }
}

private struct LauncherTile: View {
    let item: LauncherItem
    let icon: NSImage
    let onLaunch: () -> Void
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onLaunch) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .scaleEffect(isHovering ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(IslandMotion.control) { isHovering = hovering } }
        .help(item.title)
        .accessibilityLabel(item.title)
        .contextMenu { Button("Kaldır", role: .destructive, action: onRemove) }
    }
}
