import AppKit
import CoreAudio
import SwiftUI

struct AudioMixerPanel: View {
    let mixer: AudioMixerController
    let settings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SES MİKSERİ").font(IslandType.sectionLabel).foregroundStyle(IslandPalette.secondary)
                Spacer()
                if mixer.activeRouteCount > 0 {
                    Text("\(mixer.activeRouteCount) özel ses yolu").font(IslandType.caption2).foregroundStyle(IslandPalette.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    deviceControl("Çıkış", symbol: "speaker.wave.2", id: mixer.output,
                                  selector: kAudioHardwarePropertyDefaultOutputDevice, input: false, level: mixer.outputLevel)
                    deviceControl("Sistem sesleri", symbol: "bell", id: mixer.systemOutput,
                                  selector: kAudioHardwarePropertyDefaultSystemOutputDevice, input: false, level: nil)
                    deviceControl("Mikrofon", symbol: "mic", id: mixer.input,
                                  selector: kAudioHardwarePropertyDefaultInputDevice, input: true, level: mixer.inputLevel)
                    Divider().overlay(IslandPalette.separator)
                    if !mixer.supportsApplicationMixer {
                        Text("Uygulama başına ses kontrolü macOS 14.2 veya üstünü gerektirir.")
                            .font(IslandType.caption).foregroundStyle(.secondary)
                    }
                    ForEach(mixer.applications) { app in
                        applicationRow(app)
                    }
                }
                .padding(.trailing, 3)
            }
            if let error = mixer.error {
                HStack(alignment: .top) {
                    Text(error).font(IslandType.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button { mixer.clearError() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Hata mesajını kapat")
                }
            }
            HStack {
                Button(action: settings) { Label("Ayarlar", systemImage: "gearshape") }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("Çık", systemImage: "power") }
            }
            .font(IslandType.caption).buttonStyle(.plain)
        }
        .onAppear { mixer.showPanel() }
        .onDisappear { mixer.hidePanel() }
    }

    private func deviceControl(_ title: String, symbol: String, id: AudioObjectID, selector: AudioObjectPropertySelector,
                               input: Bool, level: Float?) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Label(title, systemImage: symbol).font(IslandType.caption).frame(width: 94, alignment: .leading)
                Picker(title, selection: Binding(get: { id }, set: { mixer.selectDevice($0, selector: selector) })) {
                    ForEach(mixer.devices.filter { input ? $0.input : $0.output }) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden().controlSize(.small).frame(maxWidth: .infinity)
            }
            if let level {
                HStack {
                    Slider(value: Binding(get: { Double(input ? mixer.inputLevel ?? level : mixer.outputLevel ?? level) },
                                          set: { mixer.setDeviceLevel(Float($0), input: input) }), in: 0...1)
                        .controlSize(.small).accessibilityLabel(title + " seviyesi")
                    Text("\(Int((level * 100).rounded()))%")
                        .font(IslandType.numericSmall).frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    private func applicationRow(_ app: MixerApplication) -> some View {
        let volume = mixer.volumes[app.id] ?? 1
        let direct = DirectApplicationVolume.kind(for: app.bundleID)
        let hasAudio = direct != nil || (mixer.supportsApplicationMixer && !app.processes.isEmpty)
        return HStack(alignment: .top, spacing: 10) {
            Group {
                if let icon = app.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "app").resizable() }
            }
            .aspectRatio(contentMode: .fit).frame(width: 26, height: 26)
            VStack(spacing: 4) {
                HStack {
                    Text(app.name).font(IslandType.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    Picker("\(app.name) ses çıkışı", selection: Binding(get: { mixer.routes[app.id] ?? "" },
                                                                         set: { mixer.setApplicationOutput($0, pid: app.id) })) {
                        Text("Varsayılan").tag("")
                        ForEach(mixer.devices.filter(\.output)) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden().controlSize(.mini).frame(maxWidth: 142)
                    .disabled(!mixer.supportsApplicationMixer || !hasAudio)
                    .help(direct != nil ? "Farklı çıkış aygıtı macOS Sistem Sesi Kaydı izni gerektirir" : "Uygulama ses çıkışı; sistem sesi erişimi gerektirir")
                    Menu {
                        Button("Varsayılan sesi geri yükle") { mixer.restoreApplication(app.id) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().help("\(app.name) ses seçenekleri")
                }
                HStack {
                    Slider(value: Binding(get: { Double(mixer.volumes[app.id] ?? 1) },
                                          set: { mixer.setApplicationVolume(Float($0), pid: app.id) }), in: 0...1)
                        .controlSize(.small).disabled(!hasAudio).accessibilityLabel(app.name + " ses seviyesi")
                        .help(direct?.isBrowser == true ? "Açık sekmedeki video ve müzik oynatıcıları" :
                              direct != nil ? "Uygulamanın kendi ses seviyesi" : "Uygulamanın tüm sesi; sistem sesi erişimi gerektirir")
                    Text("\(Int((volume * 100).rounded()))%")
                        .font(IslandType.numericSmall).frame(width: 38, alignment: .trailing)
                    Button { mixer.setApplicationVolume(volume == 0 ? 1 : 0, pid: app.id) } label: {
                        Image(systemName: volume == 0 ? "speaker.slash" : "speaker.wave.2")
                    }
                    .buttonStyle(.plain).disabled(!hasAudio)
                    .accessibilityLabel(app.name + (volume == 0 ? " sesini aç" : " sesini kapat"))
                }
                if !hasAudio {
                    Text("Ses oturumu yok").font(IslandType.caption2).foregroundStyle(IslandPalette.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
