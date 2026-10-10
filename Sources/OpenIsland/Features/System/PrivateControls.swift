import AppKit
import CoreGraphics
import IOKit
import IslandCore
import ObjectiveC

/// Private çerçeve okuma/yazmaları (hepsi `dlopen`/`dlsym`/ObjC çalışma zamanı; link-time bağımlılık yok).
/// Her çağrı grubu `PrivateAPIGuard` ile korunur; sembol yoksa, imza değiştiyse ya da değer geçersizse özellik
/// sessizce yok sayılır ve arayüz o bölümü göstermez.

// MARK: - Sıcaklık sensörleri (IOHIDEventSystemClient)

/// Apple Silicon sıcaklık sensörleri. Okuma yalnızca sistem monitörü açıkken yapılır.
@MainActor
final class ThermalSensors {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    private typealias CopyEventFn = @convention(c) (UnsafeMutableRawPointer, Int64, Int64, Int64) -> UnsafeMutableRawPointer?
    private typealias FloatFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double
    private typealias CopyPropertyFn = @convention(c) (UnsafeMutableRawPointer, CFString) -> Unmanaged<CFTypeRef>?

    private let copyEvent: CopyEventFn
    private let floatValue: FloatFn
    private let copyProperty: CopyPropertyFn
    /// `Create` returns +1. ARC owns it until the panel releases this sensor reader.
    private let client: AnyObject
    /// Hizmetler bir kez alınır ve saklanır (CFArray); her okumada yalnızca olaylar sorgulanır.
    private let services: [AnyObject]
    private let names: [String]

    /// `nil`: semboller yok, korumaya takıldı ya da sensör bulunamadı.
    init?() {
        guard PrivateAPIGuard.begin("temperature") else { return nil }
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            PrivateAPIGuard.failed("temperature"); return nil
        }
        // IOKit is also linked directly by this target; balance this lookup's extra open.
        defer { dlclose(handle) }
        guard let create = dlsym(handle, "IOHIDEventSystemClientCreate").map({ unsafeBitCast($0, to: CreateFn.self) }),
              let setMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching").map({ unsafeBitCast($0, to: SetMatchingFn.self) }),
              let copyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices").map({ unsafeBitCast($0, to: CopyServicesFn.self) }),
              let copyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent").map({ unsafeBitCast($0, to: CopyEventFn.self) }),
              let floatValue = dlsym(handle, "IOHIDEventGetFloatValue").map({ unsafeBitCast($0, to: FloatFn.self) }),
              let copyProperty = dlsym(handle, "IOHIDServiceClientCopyProperty").map({ unsafeBitCast($0, to: CopyPropertyFn.self) }),
              let client = create(kCFAllocatorDefault)
        else { PrivateAPIGuard.failed("temperature"); return nil }
        let ownedClient = Unmanaged<AnyObject>.fromOpaque(client).takeRetainedValue()
        // Sıcaklık sensörleri: kullanım sayfası 0xff00, kullanım 5.
        setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let found = copyServices(client)?.takeRetainedValue() as? [AnyObject] ?? []
        guard !found.isEmpty else { PrivateAPIGuard.failed("temperature"); return nil }
        self.copyEvent = copyEvent
        self.floatValue = floatValue
        self.copyProperty = copyProperty
        self.client = ownedClient
        services = found
        names = found.map { service in
            let pointer = Unmanaged.passUnretained(service).toOpaque()
            return (copyProperty(pointer, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
        }
    }

    func read() -> TemperatureRules.Summary {
        defer { withExtendedLifetime(client) {} }
        var readings: [(name: String, celsius: Double)] = []
        for (service, name) in zip(services, names) {
            let pointer = Unmanaged.passUnretained(service).toOpaque()
            guard let event = copyEvent(pointer, 15, 0, 0) else { continue } // kIOHIDEventTypeTemperature
            readings.append((name, floatValue(event, Int32(15 << 16))))
            // `IOHIDServiceClientCopyEvent` +1 verir; CFRelease ile bırakılır.
            Unmanaged<AnyObject>.fromOpaque(event).release()
        }
        let summary = TemperatureRules.summarize(readings)
        if summary.cpu != nil || summary.gpu != nil { PrivateAPIGuard.succeeded("temperature") }
        return summary
    }
}

// MARK: - Parlaklık (DisplayServices) ve klavye ışığı (CoreBrightness)

@MainActor
enum PrivateLevelBackends {
    private typealias GetBrightnessFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (UInt32, Float) -> Int32
    private typealias KeyboardReadFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias KeyboardWriteFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    /// Okuma-yazma sonrası doğrulama toleransı: yazılan değer geri okununca bu kadar sapabilir.
    private static let tolerance: Float = 0.1

    /// Dahili ekran parlaklığı. `nil`: sembol yok, korumaya takıldı ya da ilk okuma geçersiz.
    static func displayBrightness() -> LevelControlBackend? {
        guard PrivateAPIGuard.begin("brightness") else { return nil }
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness").map({ unsafeBitCast($0, to: GetBrightnessFn.self) }),
              let set = dlsym(handle, "DisplayServicesSetBrightness").map({ unsafeBitCast($0, to: SetBrightnessFn.self) })
        else { PrivateAPIGuard.failed("brightness"); return nil }
        func builtInDisplay() -> UInt32? {
            var ids = [CGDirectDisplayID](repeating: 0, count: 8)
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(8, &ids, &count) == .success else { return nil }
            return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
        }
        func read() -> Float? {
            guard let display = builtInDisplay() else { return nil }
            var value: Float = -1
            return get(display, &value) == 0 ? value : nil
        }
        guard let first = read(), first.isFinite, (0...1).contains(first) else { PrivateAPIGuard.failed("brightness"); return nil }
        PrivateAPIGuard.succeeded("brightness")
        return LevelControlBackend(read: read) { value in
            guard let display = builtInDisplay(), set(display, value) == 0, let back = read() else { return false }
            return abs(back - value) <= tolerance
        }
    }

    /// MacBook klavye aydınlatması (`KeyboardBrightnessClient`). Yöntem imzaları çalışma zamanında doğrulanır; farklıysa
    /// hiçbir çağrı yapılmaz.
    static func keyboardBacklight() -> LevelControlBackend? {
        guard PrivateAPIGuard.begin("keyboard") else { return nil }
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            PrivateAPIGuard.failed("keyboard"); return nil
        }
        let client = cls.init()
        let idsSelector = Selector(("copyKeyboardBacklightIDs"))
        let readSelector = Selector(("brightnessForKeyboard:"))
        let writeSelector = Selector(("setBrightness:forKeyboard:"))
        func signature(_ selector: Selector) -> [String]? {
            guard let method = class_getInstanceMethod(cls, selector) else { return nil }
            var parts: [String] = []
            let returnType = method_copyReturnType(method)
            parts.append(String(cString: returnType)); free(returnType)
            for index in 0..<method_getNumberOfArguments(method) {
                guard let type = method_copyArgumentType(method, UInt32(index)) else { return nil }
                parts.append(String(cString: type)); free(type)
            }
            return parts
        }
        // Cihazda ölçülen imzalar: okuma `f @ : Q`, yazma `B @ : f Q`.
        guard signature(readSelector) == ["f", "@", ":", "Q"], signature(writeSelector) == ["B", "@", ":", "f", "Q"],
              client.responds(to: idsSelector),
              let readMethod = class_getInstanceMethod(cls, readSelector), let writeMethod = class_getInstanceMethod(cls, writeSelector),
              let ids = client.perform(idsSelector)?.takeRetainedValue() as? [NSNumber], let id = ids.first?.uint64Value
        else { PrivateAPIGuard.failed("keyboard"); return nil }
        let read = unsafeBitCast(method_getImplementation(readMethod), to: KeyboardReadFn.self)
        let write = unsafeBitCast(method_getImplementation(writeMethod), to: KeyboardWriteFn.self)
        let first = read(client, readSelector, id)
        guard first.isFinite, (0...1).contains(first) else { PrivateAPIGuard.failed("keyboard"); return nil }
        PrivateAPIGuard.succeeded("keyboard")
        return LevelControlBackend(read: { read(client, readSelector, id) }) { value in
            guard write(client, writeSelector, value, id) else { return false }
            return abs(read(client, readSelector, id) - value) <= tolerance
        }
    }
}
