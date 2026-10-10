import IslandCore
import SwiftUI
import UniformTypeIdentifiers

/// Dosya sürüklenirken görünen iki bölge: "Rafa bırak" ve "AirDrop".
/// Yalnızca görseldir; bırakma işlemini kök görünümdeki tek drop delegesi yapar ve imlecin
/// üzerinde olduğu bölgeyi `zone` ile bildirir.
struct DropZoneView: View {
    let zone: DropZone?
    let metrics: NotchMetrics

    var body: some View {
        let layout = IslandLayoutEngine.layout(for: .dropTarget, metrics: metrics)
        let side = IslandLayoutEngine.contentSideInset(for: layout, style: metrics.style)
        HStack(spacing: IslandSpacing.m) {
            tile(title: "Rafa bırak", symbol: "tray.and.arrow.down.fill", isActive: zone == .shelf)
            tile(title: "AirDrop", symbol: "antenna.radiowaves.left.and.right", isActive: zone == .airDrop)
        }
        .padding(EdgeInsets(top: metrics.notchSize.height + IslandLayoutEngine.headerGap,
                            leading: side, bottom: IslandLayoutEngine.contentInset, trailing: side))
        .frame(width: layout.size.width, height: layout.size.height)
        .foregroundStyle(IslandPalette.primary)
    }

    private func tile(title: String, symbol: String, isActive: Bool) -> some View {
        let radius = IslandLayoutEngine.concentricRadius(outer: IslandLayoutEngine.expandedBottomRadius,
                                                         inset: IslandLayoutEngine.contentInset)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return VStack(spacing: IslandSpacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .symbolEffect(.bounce, value: isActive)
            Text(title).font(IslandType.bodyEmphasized)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(isActive ? IslandPalette.fillHover : IslandPalette.fill))
        .overlay(shape.strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .foregroundStyle(isActive ? IslandPalette.secondary : IslandPalette.separator))
        .scaleEffect(isActive ? 1.02 : 1)
        .animation(IslandMotion.control, value: isActive)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Genişletilmiş görünümdeki raf: çoklu seçim, Quick Look ve seçili dosyaların tek hareketle başka bir
/// pencereye/maile sürüklenmesi. Rafa bırakma kök drop delegesi üzerinden gelir.
struct ShelfPanel: View {
    let shelf: ShelfStore

    var body: some View {
        if shelf.items.isEmpty {
            VStack(spacing: IslandSpacing.s) {
                Image(systemName: "tray").font(.system(size: 24)).foregroundStyle(IslandPalette.tertiary)
                Text("Dosyaları çentiğe sürükleyin").font(IslandType.bodyEmphasized)
                Text("Raftaki dosyaları seçip Quick Look ile önizleyebilir, topluca herhangi bir uygulamaya, Finder'a veya AirDrop'a bırakabilirsiniz.")
                    .font(IslandType.caption)
                    .foregroundStyle(IslandPalette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: IslandLayoutEngine.Shelf.emptyTextWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: IslandSpacing.s) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: IslandSpacing.xs) {
                        ForEach(shelf.items) { item in
                            ShelfItemView(item: item, thumbnail: shelf.thumbnails[item.url],
                                          isSelected: shelf.selection.contains(item.id), shelf: shelf)
                        }
                    }
                }
                actionBar
            }
            .onAppear(perform: shelf.panelDidAppear)
        }
    }

    private var actionBar: some View {
        let targets = shelf.actionTargets
        let scope = shelf.selection.isEmpty ? "\(shelf.items.count) öğe" : "\(shelf.selection.count) / \(shelf.items.count) seçili"
        let operations = shelf.availableOperations(for: targets)
        return HStack(spacing: IslandSpacing.m) {
            Text(shelf.operationStatus ?? scope)
                .font(IslandType.caption2)
                .foregroundStyle(shelf.operationStatus == nil ? IslandPalette.tertiary : IslandPalette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.numericText())
            Button(shelf.selection.count == shelf.items.count ? "Seçimi kaldır" : "Tümünü seç") {
                withAnimation(IslandMotion.control) {
                    shelf.selection.count == shelf.items.count ? shelf.clearSelection() : shelf.selectAll()
                }
            }
            Spacer()
            actionButton("eye", "Önizle") { shelf.quickLook(targets) }
            actionButton("antenna.radiowaves.left.and.right", "AirDrop") { shelf.airDrop(targets.map(\.url)) }
            actionButton("doc.on.doc", "Kopyala") { shelf.copyToPasteboard(targets) }
            actionButton("trash", "Kaldır") { withAnimation(IslandMotion.control) { shelf.remove(targets) } }
            // Zip'le, arşivi aç, resmi sıkıştır, yolu kopyala: yalnızca seçime uygun olanlar listelenir.
            Menu {
                ForEach(operations, id: \.self) { operation in
                    Button(operation.title) { shelf.perform(operation, on: targets) }
                }
            } label: {
                Label("İşlemler", systemImage: "wand.and.stars").labelStyle(.iconOnly)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(operations.isEmpty || shelf.isOperationRunning)
            .help("İşlemler: zip'le, arşivi aç, resmi sıkıştır, yolu kopyala")
            .accessibilityLabel("İşlemler")
        }
        .buttonStyle(.plain)
        .font(IslandType.caption2)
        .foregroundStyle(IslandPalette.secondary)
    }

    private func actionButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

struct ShelfItemView: View {
    let item: ShelfItem
    let thumbnail: NSImage?
    let isSelected: Bool
    let shelf: ShelfStore
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IslandSpacing.cardRadius - 4, style: .continuous)
        VStack(spacing: IslandSpacing.xs) {
            Group {
                if item.isMissing {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 26))
                        .foregroundStyle(IslandPalette.tertiary)
                } else if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc.fill").font(.system(size: 28)).foregroundStyle(IslandPalette.secondary)
                }
            }
            .frame(width: 52, height: 52)
            Text(item.isMissing ? "Bulunamadı" : item.name)
                .font(IslandType.caption2)
                .foregroundStyle(isSelected ? IslandPalette.primary : IslandPalette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 68)
        }
        .padding(6)
        .background(shape.fill(isSelected ? Color.accentColor.opacity(0.28) : (isHovering ? IslandPalette.fill : .clear)))
        .overlay(shape.strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1))
        // Tıklama, çoklu sürükleme ve bağlam menüsü AppKit'te: SwiftUI'nin `.onDrag`'ı tek öğe taşır.
        .overlay {
            ShelfDragSource(
                onClick: { modifiers, clickCount in
                    if clickCount >= 2 { shelf.open(item) } else {
                        withAnimation(IslandMotion.control) { shelf.select(item, modifiers: modifiers) }
                    }
                },
                payload: { shelf.dragPayload(startingAt: item) },
                menu: { menu() }
            )
        }
        .onHover { hovering in withAnimation(IslandMotion.control) { isHovering = hovering } }
        .help(item.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.isMissing ? "\(item.name), bulunamadı" : item.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Seçmek için tıklayın, açmak için çift tıklayın, başka bir uygulamaya sürükleyin")
    }

    private func menu() -> NSMenu {
        let targets = isSelected ? shelf.actionTargets : [item]
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Aç") { targets.forEach(shelf.open) })
        menu.addItem(ClosureMenuItem("Hızlı Bakış") { shelf.quickLook(targets) })
        menu.addItem(ClosureMenuItem("Finder'da Göster") { shelf.revealInFinder(targets) })
        menu.addItem(ClosureMenuItem("AirDrop ile Gönder") { shelf.airDrop(targets.map(\.url)) })
        menu.addItem(ClosureMenuItem("Kopyala") { shelf.copyToPasteboard(targets) })
        let operations = shelf.availableOperations(for: targets)
        if !operations.isEmpty, !shelf.isOperationRunning {
            menu.addItem(.separator())
            for operation in operations {
                menu.addItem(ClosureMenuItem(operation.title) { shelf.perform(operation, on: targets) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Raftan Kaldır") { shelf.remove(targets) })
        return menu
    }
}

/// Raf öğesinin AppKit katmanı: tek/çift tıklama, ⌘/⇧ seçim, sağ tık menüsü ve **çok öğeli**
/// sürükleme oturumu (`NSDraggingItem` başına bir dosya; Mail, Finder, Slack topluca kabul eder).
private struct ShelfDragSource: NSViewRepresentable {
    let onClick: (NSEvent.ModifierFlags, Int) -> Void
    let payload: () -> [URL]
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.onClick = onClick
        view.payload = payload
        view.menuProvider = menu
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var onClick: ((NSEvent.ModifierFlags, Int) -> Void)?
        var payload: (() -> [URL])?
        var menuProvider: (() -> NSMenu)?
        private var mouseDownEvent: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = mouseDownEvent, let urls = payload?(), !urls.isEmpty else { return }
            let distance = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
            guard distance > 3 else { return }
            mouseDownEvent = nil
            let origin = convert(down.locationInWindow, from: nil)
            let items = urls.enumerated().map { index, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let offset = CGFloat(min(index, 4)) * 6 // yığın görünümü
                item.setDraggingFrame(CGRect(x: origin.x - 24 + offset, y: origin.y - 24 - offset, width: 48, height: 48), contents: icon)
                return item
            }
            let session = beginDraggingSession(with: items, event: down, source: self)
            session.draggingFormation = .pile
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        override func mouseUp(with event: NSEvent) {
            if mouseDownEvent != nil { onClick?(event.modifierFlags.intersection(.deviceIndependentFlagsMask), event.clickCount) }
            mouseDownEvent = nil
        }

        override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }
    }
}

/// Kapanış bloğu çalıştıran menü öğesi (AppKit hedef/eylem köprüsü).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) desteklenmiyor") }

    @objc private func runHandler() { handler() }
}
