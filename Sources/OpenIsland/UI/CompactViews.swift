import AppKit
import IslandCore
import SwiftUI

/// Kompakt görünümün kanat ızgarası: öğeler yüzeyin gövde kenarından, dikeyde eşit boşlukla
/// (eş-merkezli) konumlanır. Medya öğeleri (kapak, dalga) kalıcı katmanda çizildiği için burada yok.
private struct WingGrid {
    let layout: IslandLayout
    let metrics: NotchMetrics
    let iconSize: CGFloat

    var sideInset: CGFloat {
        IslandLayoutEngine.bodyInset(for: layout, style: metrics.style) + (layout.size.height - iconSize) / 2
    }

    /// Donanım çentiğinin arkasında kalan (çizilmeyen) orta bölge.
    var centerGap: CGFloat {
        metrics.style == .notch ? metrics.notchSize.width : IslandSpacing.s
    }
}

/// Kapalı adanın "kanatları": donanım çentiğinin solunda ve sağında canlı etkinlik.
struct CompactActivityView: View {
    let activity: CompactActivity
    let metrics: NotchMetrics
    let environment: AppEnvironment

    var body: some View {
        let layout = IslandLayoutEngine.layout(for: .compact(activity), metrics: metrics)
        let grid = WingGrid(layout: layout, metrics: metrics, iconSize: 18)
        HStack(spacing: 0) {
            leading.frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: grid.centerGap)
            trailing.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, grid.sideInset)
        .frame(width: layout.size.width, height: layout.size.height)
        .foregroundStyle(IslandPalette.primary)
    }

    @ViewBuilder
    private var leading: some View {
        switch activity {
        case .media:
            EmptyView() // kalıcı kapak katmanı
        case .transfer:
            let transfers = environment.transfers
            TimeProgressView(style: .ring(lineWidth: 2.5),
                             timing: .init(progress: transfers.fraction, reference: .distantPast, rate: 0, isRunning: false),
                             tint: .systemBlue)
                .frame(width: 16, height: 16)
                .overlay {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.blue)
                }
                .accessibilityHidden(true)
        case .timer:
            let timer = environment.focusTimer
            TimeProgressView(style: .ring(lineWidth: 2.5), timing: timer.progressTiming, tint: NSColor(timer.phase.tint))
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        case .shelf:
            Image(systemName: "tray.full.fill")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch activity {
        case .media:
            EmptyView() // kalıcı dalga katmanı
        case .transfer:
            let transfers = environment.transfers
            Text("%\(Int((transfers.fraction * 100).rounded(.down)))")
                .font(IslandType.numeric)
                .foregroundStyle(Color.blue)
                .contentTransition(.numericText())
                .accessibilityLabel("\(transfers.primaryName ?? "Aktarım"), yüzde \(Int(transfers.fraction * 100))")
        case .timer:
            CountdownLabel(timer: environment.focusTimer, font: IslandType.numeric)
        case .shelf:
            Text("\(environment.shelf.items.count)")
                .font(IslandType.numeric)
                .accessibilityLabel("Rafta \(environment.shelf.items.count) öğe")
        }
    }
}

/// Geri sayım metni: tam saniye sınırlarında ve yalnızca sayaç çalışırken güncellenir.
struct CountdownLabel: View {
    let timer: FocusTimer
    let font: Font

    var body: some View {
        let running = timer.runState
        let anchor: Date = if case .running(let end) = running { end } else { .now }
        TimelineView(PausablePeriodicSchedule(anchor: anchor, interval: 1, isPaused: !timer.isRunning)) { context in
            let remaining = timer.remaining(at: context.date).rounded(.up)
            Text(remaining.clockString)
                .font(font)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(timer.phase.tint)
                .contentTransition(.numericText(countsDown: true))
                .accessibilityLabel("\(timer.phase.title), kalan \(remaining.clockString)")
        }
    }
}

/// Native HUD'un yerini alan kompakt gösterge: solda ikon, sağda seviye çubuğu.
struct HUDCompactView: View {
    let payload: HUDPayload
    let metrics: NotchMetrics

    var body: some View {
        let layout = IslandLayoutEngine.layout(for: .hud(payload), metrics: metrics)
        let grid = WingGrid(layout: layout, metrics: metrics, iconSize: 18)
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: grid.centerGap)
            HStack(spacing: IslandSpacing.s) {
                LevelBar(level: payload.level, tint: tint).frame(height: 5)
                Text("\(Int((payload.level * 100).rounded()))")
                    .font(IslandType.numericSmall)
                    .foregroundStyle(IslandPalette.secondary)
                    .frame(width: 22, alignment: .trailing)
            }
            .frame(width: 92)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, grid.sideInset)
        .frame(width: layout.size.width, height: layout.size.height)
        .foregroundStyle(IslandPalette.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue("%\(Int((payload.level * 100).rounded()))")
    }

    private var tint: Color {
        if case .volume(muted: true) = payload.kind { return IslandPalette.tertiary }
        return IslandPalette.primary
    }

    private var accessibilityTitle: String {
        switch payload.kind {
        case .volume(let muted): muted ? "Ses kapalı" : "Ses"
        case .brightness: "Ekran parlaklığı"
        case .keyboardBacklight: "Klavye aydınlatması"
        }
    }

    private var symbol: String {
        switch payload.kind {
        case .volume(let muted):
            if muted || payload.level == 0 { return "speaker.slash.fill" }
            if payload.level < 0.33 { return "speaker.wave.1.fill" }
            if payload.level < 0.66 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return payload.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .keyboardBacklight:
            return payload.level < 0.5 ? "light.min" : "light.max"
        }
    }
}
