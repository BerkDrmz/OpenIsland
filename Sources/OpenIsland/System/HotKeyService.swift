import AppKit
import Carbon.HIToolbox

/// Adayı klavyeden aç/kapat: ⌃⌥⌘I (varsayılan).
///
/// Carbon `RegisterEventHotKey` hâlâ macOS'un global kısayol için önerilen API'sidir: Erişilebilirlik
/// izni gerektirmez, her tuş vuruşunu dinlemez; sistem yalnızca bu kombinasyonda bizi çağırır.
@MainActor
final class HotKeyService {
    var onPressed: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func setEnabled(_ enabled: Bool) {
        enabled ? register() : unregister()
    }

    private func register() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotKeyService>.fromOpaque(context).takeUnretainedValue()
            // Carbon olayları ana iş parçacığında, uygulama olay döngüsünde gelir.
            MainActor.assumeIsolated { service.onPressed?() }
            return noErr
        }, 1, &spec, context, &handler)

        let identifier = EventHotKeyID(signature: OSType(0x4F49_534C), id: 1) // "OISL"
        RegisterEventHotKey(UInt32(kVK_ANSI_I), UInt32(cmdKey | optionKey | controlKey), identifier,
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}

/// Adadan açılan sistem arayüzleri (Quick Look, dosya seçici, AirDrop sayfası, bağlantı iletişim kutusu)
/// görünürken adanın kapanmasını geçici olarak engelleyen sayaç.
@MainActor
final class IslandHold {
    var onChange: ((Bool) -> Void)?
    private var count = 0

    var isHeld: Bool { count > 0 }

    func begin() {
        count += 1
        if count == 1 { onChange?(true) }
    }

    func end() {
        guard count > 0 else { return }
        count -= 1
        if count == 0 { onChange?(false) }
    }

    /// Senkron modal çalıştırmalar için (NSOpenPanel, NSAlert).
    func during<T>(_ work: () -> T) -> T {
        begin()
        defer { end() }
        return work()
    }
}
