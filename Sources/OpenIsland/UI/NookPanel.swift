import AppKit
import IslandCore
import SwiftUI

/// NotchNook'un ana görünümü: widget'lar yan yana. Medya widget'ı en solda sabittir (kalıcı albüm
/// kapağı katmanı `artworkSlot(.expanded(.nook))` yuvasına akar); diğer widget'lar sağda yatay kayar.
struct NookPanel: View {
    let environment: AppEnvironment
    let metrics: NotchMetrics

    var body: some View {
        let layout = environment.preferences.nookLayout
        HStack(alignment: .top, spacing: IslandSpacing.m) {
            NookMediaWidget(media: environment.media, metrics: metrics)
            divider
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: IslandSpacing.m) {
                    NookCalendarWidget(calendar: environment.calendar)
                    if layout.showsReminders {
                        divider
                        VStack(alignment: .leading, spacing: IslandSpacing.xs) {
                            // Başlık → Anımsatıcılar uygulaması; satırlar ve alan kendi işlevini korur.
                            Button(action: environment.reminders.openApp) {
                                Text("ANIMSATICILAR").font(IslandType.sectionLabel).foregroundStyle(IslandPalette.secondary)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Anımsatıcılar'da aç")
                            RemindersList(reminders: environment.reminders, limit: 2)
                            Spacer(minLength: 0)
                        }
                        .frame(width: IslandLayoutEngine.nookWidgetWidths[1])
                    }
                    if layout.showsShortcuts {
                        divider
                        NookShortcutsWidget(launcher: environment.launcher, openTools: environment.maintenance.open)
                    }
                }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(IslandPalette.separator).frame(width: 0.5).frame(maxHeight: .infinity)
    }
}

private struct NookMediaWidget: View {
    let media: MediaController
    let metrics: NotchMetrics

    var body: some View {
        let size = IslandLayoutEngine.artworkSlot(for: .expanded(.nook), metrics: metrics)?.rect.size ?? .zero
        HStack(alignment: .top, spacing: IslandSpacing.m) {
            if media.nowPlaying == nil {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(IslandPalette.fill)
                    .overlay(Image(systemName: "music.note").foregroundStyle(IslandPalette.tertiary))
                    .frame(width: size.width, height: size.height)
            } else {
                SourceAppButton(media: media) {
                    Color.clear.frame(width: size.width, height: size.height) // kalıcı kapak katmanı
                }
            }
            VStack(alignment: .leading, spacing: IslandSpacing.xxs) {
                SourceAppButton(media: media) {
                    VStack(alignment: .leading, spacing: IslandSpacing.xxs) {
                        Text(media.nowPlaying?.title ?? "Çalan yok").font(IslandType.bodyEmphasized).lineLimit(1)
                        Text(media.nowPlaying?.artist ?? "").font(IslandType.caption).foregroundStyle(IslandPalette.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: IslandSpacing.m) {
                    IslandIconButton(systemName: "backward.fill", label: "Önceki parça", size: 11, action: media.previousTrack)
                    IslandIconButton(systemName: media.isPlaying ? "pause.fill" : "play.fill", label: media.isPlaying ? "Duraklat" : "Oynat",
                                     size: 14, isProminent: true, action: media.togglePlayPause)
                    IslandIconButton(systemName: "forward.fill", label: "Sonraki parça", size: 11, action: media.nextTrack)
                }
            }
            .frame(width: IslandLayoutEngine.nookMediaTextWidth, height: size.height, alignment: .leading)
        }
    }
}

/// Takvim widget'ı: solda ay, sağda bugünü merkeze alan 5 günlük şerit (bugün sistem vurgu renginde); altta seçili
/// günün etkinlikleri. Ay adı Takvim'i, etkinlik o etkinliği açar; izin yoksa "Takvimini bağla".
/// Ölçü: 170 × 92 pt'lik Nook kolonuna sığar (şerit 5 × 24 pt, üst satır 35 pt, en fazla 2 etkinlik + "+N").
private struct NookCalendarWidget: View {
    let calendar: CalendarService
    @State private var hoveredDay: Int?

    private static let visibleDays = -2...2
    private static let maximumEvents = 2

    var body: some View {
        let today = calendar.today
        let selected = Calendar.current.date(byAdding: .day, value: calendar.dayOffset, to: today) ?? today
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: IslandSpacing.s) {
                Button(action: calendar.openInCalendarApp) {
                    Text(selected.formatted(.dateTime.month(.abbreviated)))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(IslandPalette.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Takvim'de aç")
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    ForEach(Self.visibleDays, id: \.self) { offset in dayCell(offset, today: today) }
                }
            }
            events
            Spacer(minLength: 0)
        }
        .frame(width: IslandLayoutEngine.nookWidgetWidths[0])
    }

    private func dayCell(_ offset: Int, today: Date) -> some View {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: today) ?? today
        let isToday = offset == 0
        let isSelected = offset == calendar.dayOffset
        let weekday = Calendar.current.component(.weekday, from: date)
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return Button {
            withAnimation(IslandMotion.control) { calendar.showDay(offset: offset) }
        } label: {
            VStack(spacing: 2) {
                Text(symbols[(weekday - 1) % symbols.count])
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(IslandPalette.tertiary)
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isToday ? Color.accentColor : (isSelected ? IslandPalette.primary : IslandPalette.secondary))
                    .frame(width: 22, height: 22)
                    .background {
                        if isSelected || hoveredDay == offset {
                            Circle().fill(isSelected ? IslandPalette.fillHover : IslandPalette.fill)
                        }
                    }
            }
            .frame(width: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(IslandMotion.control) { hoveredDay = hovering ? offset : nil } }
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted) + (isToday ? ", bugün" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var events: some View {
        if !calendar.hasAccess {
            // Karar verilmemişse izin sorar; reddedilmişse Sistem Ayarları › Takvimler açılır.
            Button(action: calendar.requestAccess) {
                Label("Takvimini bağla", systemImage: "calendar.badge.plus")
                    .font(IslandType.caption)
                    .foregroundStyle(IslandPalette.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if calendar.dayEvents.isEmpty {
            Button(action: calendar.openInCalendarApp) {
                Text("Etkinlik yok").font(IslandType.caption).foregroundStyle(IslandPalette.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Takvim'de aç")
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(calendar.dayEvents.prefix(Self.maximumEvents)) { event in
                    Button { calendar.open(event) } label: {
                        HStack(spacing: 6) {
                            Capsule().fill(event.calendarColor.map(Color.init(nsColor:)) ?? .blue).frame(width: 3, height: 12)
                            Text(event.isAllDay ? "Tüm gün" : event.start.formatted(date: .omitted, time: .shortened))
                                .font(IslandType.numericSmall).foregroundStyle(IslandPalette.secondary)
                            Text(event.title).font(IslandType.caption).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Takvim'de aç")
                }
                if calendar.dayEvents.count > Self.maximumEvents {
                    Button(action: calendar.openInCalendarApp) {
                        Text("+\(calendar.dayEvents.count - Self.maximumEvents) etkinlik")
                            .font(IslandType.caption2).foregroundStyle(IslandPalette.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct NookShortcutsWidget: View {
    let launcher: LauncherStore
    let openTools: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IslandSpacing.xs) {
            HStack {
                Text("KISAYOLLAR").font(IslandType.sectionLabel).foregroundStyle(IslandPalette.secondary)
                Spacer(minLength: 0)
                Button(action: openTools) { Image(systemName: "wrench.and.screwdriver") }
                    .buttonStyle(.plain).font(IslandType.caption).foregroundStyle(IslandPalette.secondary)
                    .help("Araçlar: kaldırıcı, önbellek temizleyici ve uygulama güncelleyici")
                    .accessibilityLabel("Araçlar")
            }
            if launcher.items.isEmpty {
                Text("Notlar sekmesinden öğe ekleyin").font(IslandType.caption2).foregroundStyle(IslandPalette.tertiary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 4), spacing: 8) {
                    ForEach(launcher.items.prefix(8)) { item in
                        Button { launcher.launch(item) } label: {
                            Image(nsImage: launcher.icon(for: item)).resizable().aspectRatio(contentMode: .fit).frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help(item.title)
                        .accessibilityLabel(item.title)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: IslandLayoutEngine.nookWidgetWidths[2])
    }
}
