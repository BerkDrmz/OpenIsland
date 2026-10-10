import AppKit
import IslandCore
import SwiftUI

/// Odak zamanlayıcısı ve kalıcı odak/mola süreleri.
struct FocusPanel: View {
    let timer: FocusTimer

    var body: some View {
        HStack(spacing: IslandLayoutEngine.columnGap) {
            timerColumn.frame(width: IslandLayoutEngine.Focus.timerWidth)
            Rectangle().fill(IslandPalette.separator).frame(width: 0.5)
            VStack(spacing: IslandLayoutEngine.Focus.durationRowSpacing) {
                ForEach(FocusTimer.Phase.allCases, id: \.self) { phase in
                    durationRow(phase)
                }
            }
            .frame(width: IslandLayoutEngine.Focus.durationWidth)
            .disabled(timer.isRunning)
            .help(timer.isRunning ? "Süreyi değiştirmek için zamanlayıcıyı duraklat." : "Odak ve mola süreleri: 1–180 dakika.")
        }
        .frame(height: IslandLayoutEngine.Focus.ringSize)
    }

    private var timerColumn: some View {
        HStack(spacing: IslandSpacing.m) {
            ZStack {
                TimeProgressView(style: .ring(lineWidth: 5), timing: timer.progressTiming, tint: NSColor(timer.phase.tint))
                VStack(spacing: 0) {
                    CountdownLabel(timer: timer, font: IslandType.numericLarge)
                        .frame(width: IslandLayoutEngine.Focus.ringSize - 16)
                    Text(timer.phase.title)
                        .font(IslandType.caption2)
                        .foregroundStyle(IslandPalette.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: IslandLayoutEngine.Focus.ringSize, height: IslandLayoutEngine.Focus.ringSize)
            .fixedSize()

            VStack(spacing: IslandSpacing.s) {
                IslandIconButton(systemName: timer.isRunning ? "pause.fill" : "play.fill",
                                 label: timer.isRunning ? "Duraklat" : "Başlat",
                                 size: 15, isProminent: true) {
                    // Başlatmadan önce dakika alanında henüz uygulanmamış yazımı tamamla.
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    timer.toggle()
                }
                HStack(spacing: IslandSpacing.xxs) {
                    IslandIconButton(systemName: "arrow.counterclockwise", label: "Sıfırla", size: 10, action: timer.reset)
                    IslandIconButton(systemName: "forward.end.fill", label: "Sonraki faza geç", size: 10, action: timer.skip)
                }
                Text("\(timer.completedFocusSessions) oturum")
                    .font(IslandType.numericSmall)
                    .foregroundStyle(IslandPalette.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private func durationRow(_ phase: FocusTimer.Phase) -> some View {
        let minutes = Binding<Int>(
            get: { Int(timer.minutes(for: phase)) },
            set: { timer.setMinutes(Double($0), for: phase) }
        )
        return HStack(spacing: 4) {
            Text(phase.title)
                .font(IslandType.caption)
                .lineLimit(1)
            Spacer(minLength: 2)
            FocusDurationField(value: minutes, label: "\(phase.title) süresi, dakika")
                .frame(width: 28, height: 14)
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .background(IslandPalette.fillHover, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel("\(phase.title) süresi, dakika")
            Text("dk")
                .font(IslandType.caption2)
                .foregroundStyle(IslandPalette.secondary)
            Stepper(phase.title, value: minutes, in: 1...180)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .accessibilityLabel("\(phase.title) süresini ayarla")
        }
        .frame(height: IslandLayoutEngine.Focus.durationRowHeight)
    }
}

/// Apple Anımsatıcılar listesi: bugün ve gecikmiş olanlar, tek tıkla tamamla, satır içi ekle.
/// İzin yoksa yalnızca "Erişim ver" gösterir; adanın geri kalanını etkilemez.
struct RemindersList: View {
    let reminders: RemindersService
    let limit: Int
    @State private var draft = ""
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        VStack(alignment: .leading, spacing: IslandSpacing.xs) {
            if !reminders.hasAccess {
                Text("Bugünkü anımsatıcılarınızı görmek için erişim verin.")
                    .font(IslandType.caption).foregroundStyle(IslandPalette.secondary)
                Button("Erişim ver", action: reminders.requestAccess)
                    .buttonStyle(.plain).font(IslandType.caption2)
            } else {
                if reminders.items.isEmpty {
                    Button(action: reminders.openApp) {
                        Text("Bugün için anımsatıcı yok").font(IslandType.caption).foregroundStyle(IslandPalette.tertiary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Anımsatıcılar'da aç")
                }
                ForEach(reminders.items.prefix(limit)) { item in
                    HStack(spacing: 6) {
                        Button {
                            withAnimation(IslandMotion.control) { reminders.complete(item) }
                        } label: {
                            Image(systemName: "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(item.listColor.map(Color.init(nsColor:)) ?? IslandPalette.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.title) tamamlandı olarak işaretle")
                        // Başlığa tıklama → Reminders; daire → tamamla (hızlı işlem adada kalır).
                        Button { reminders.open(item) } label: {
                            Text(item.title).font(IslandType.caption).lineLimit(1).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Anımsatıcılar'da aç")
                        .accessibilityHint("Anımsatıcılar uygulamasında açar")
                        if item.isOverdue {
                            Text(differentiateWithoutColor ? "Gecikti ⚠︎" : "Gecikti")
                                .font(IslandType.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                TextField("Yeni anımsatıcı", text: $draft)
                    .textFieldStyle(.plain)
                    .font(IslandType.caption)
                    .onSubmit {
                        reminders.add(title: draft)
                        draft = ""
                    }
                if let error = reminders.lastError {
                    Text(error).font(IslandType.caption2).foregroundStyle(.orange)
                }
            }
        }
        .onAppear(perform: reminders.beginViewing)
        .onDisappear(perform: reminders.endViewing)
    }
}
