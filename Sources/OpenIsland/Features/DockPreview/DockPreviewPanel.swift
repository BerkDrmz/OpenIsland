import AppKit
import ApplicationServices
import IslandCore
import SwiftUI

struct DockPreviewWindow: Identifiable {
    let id = UUID()
    let title: String
    let frame: CGRect // AX / Core Graphics top-left coordinates
    let minimized: Bool
    let element: AXUIElement
}

@MainActor @Observable
final class DockPreviewModel {
    var applicationName = ""
    var applicationIcon: NSImage?
    var windows: [DockPreviewWindow] = []
    var images: [UUID: NSImage] = [:]
    var unavailable: Set<UUID> = []
    var needsScreenAccess = false
    @ObservationIgnored var requestImage: ((UUID) -> Void)?
    @ObservationIgnored var selectWindow: ((UUID) -> Void)?
    @ObservationIgnored var requestPermission: (() -> Void)?

    func clear() {
        windows.removeAll()
        images.removeAll()
        unavailable.removeAll()
        applicationIcon = nil
        applicationName = ""
        requestImage = nil
        selectWindow = nil
        requestPermission = nil
    }
}

struct DockPreviewPanel: View {
    let model: DockPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let icon = model.applicationIcon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                Text(model.applicationName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(model.windows.count) pencere").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(model.windows) { window in
                        Button { model.selectWindow?(window.id) } label: { card(window) }
                            .buttonStyle(.plain)
                            .modifier(DockPreviewHover())
                            .accessibilityLabel("\(window.title)\(window.minimized ? ", simge durumunda" : "")")
                            .help("Bu pencereye geç")
                            .onAppear { model.requestImage?(window.id) }
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(height: DockPreviewRules.cardRowHeight)
            if model.needsScreenAccess {
                HStack(spacing: 8) {
                    Text("Önizleme için ekran erişimi gerekiyor.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("İzin ver") { model.requestPermission?() }.controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.10), lineWidth: 1))
    }

    private func card(_ window: DockPreviewWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.05))
                if let image = model.images[window.id] {
                    Image(nsImage: image).resizable().scaledToFit().padding(2)
                } else if model.needsScreenAccess || model.unavailable.contains(window.id) {
                    VStack(spacing: 6) {
                        Image(systemName: window.minimized ? "minus.rectangle" : "macwindow").font(.system(size: 18))
                        Text(window.minimized ? "Simge durumunda" : "Görüntü alınamıyor").font(.system(size: 10))
                    }.foregroundStyle(.secondary)
                } else {
                    Text("Önizleme hazırlanıyor…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(width: DockPreviewRules.cardWidth, height: DockPreviewRules.cardImageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 4) {
                if window.minimized { Image(systemName: "minus.square").font(.system(size: 9)).foregroundStyle(.secondary) }
                Text(window.title).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            }.frame(height: 16)
        }
        .frame(width: DockPreviewRules.cardWidth, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct DockPreviewHover: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(hovered ? 0.22 : 0), lineWidth: 1))
            .onHover { hovered = $0 }
    }
}
