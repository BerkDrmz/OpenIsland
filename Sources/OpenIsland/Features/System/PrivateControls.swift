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
private final class ThermalSensorReader {
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
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            return nil
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
        else { return nil }
        let ownedClient = Unmanaged<AnyObject>.fromOpaque(client).takeRetainedValue()
        // Sıcaklık sensörleri: kullanım sayfası 0xff00, kullanım 5.
        setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let found = copyServices(client)?.takeRetainedValue() as? [AnyObject] ?? []
        guard !found.isEmpty else { return nil }
        var matchedServices: [AnyObject] = []
        var matchedNames: [String] = []
        for service in found {
            let pointer = Unmanaged.passUnretained(service).toOpaque()
            let name = (copyProperty(pointer, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
            if name.hasPrefix("PMU tdie") || name.hasPrefix("PMU2 tdie") {
                matchedServices.append(service)
                matchedNames.append(name)
            }
        }
        guard !matchedServices.isEmpty else { return nil }
        self.copyEvent = copyEvent
        self.floatValue = floatValue
        self.copyProperty = copyProperty
        self.client = ownedClient
        services = matchedServices
        names = matchedNames
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
        return summary
    }
}

/// Synchronous facade used by the hardware lifecycle check, not the UI sampling path.
@MainActor
final class ThermalSensors {
    private let reader: ThermalSensorReader
    init?() {
        guard PrivateAPIGuard.begin("temperature") else { return nil }
        guard let reader = ThermalSensorReader() else { PrivateAPIGuard.failed("temperature"); return nil }
        self.reader = reader
    }
    func read() -> TemperatureRules.Summary {
        let result = reader.read()
        PrivateAPIGuard.succeeded("temperature")
        return result
    }
}

/// Serial, demand-driven sensor work. No timer, detached polling, or main-actor CF objects.
actor ThermalSamplingWorker {
    private var reader: ThermalSensorReader?
    private var revision: UInt64?
    private let overrideRead: (@Sendable () async -> TemperatureRules.Summary?)?
    init(read: (@Sendable () async -> TemperatureRules.Summary?)? = nil) { overrideRead = read }

    func read(revision nextRevision: UInt64) async -> TemperatureRules.Summary? {
        // An issued private call finishes its crash guard even if its UI request was cancelled.
        // Publication is generation-checked by the monitor; this worker never starts a loop.
        if let overrideRead { return await overrideRead() }
        if revision != nextRevision {
            reader = ThermalSensorReader()
            revision = nextRevision
        }
        return reader?.read()
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

    // One process-lifetime load: function pointers/ObjC instances require the image to stay loaded.
    // Recreating a level control must not add another dlopen reference.
    private static var didLoadDisplayServices = false
    private static var getBrightnessFn: GetBrightnessFn?
    private static var setBrightnessFn: SetBrightnessFn?

    private static var didLoadKeyboard = false
    private static var keyboardClientClass: NSObject.Type?

    /// Dahili ekran parlaklığı. `nil`: sembol yok, korumaya takıldı ya da ilk okuma geçersiz.
    static func displayBrightness() -> LevelControlBackend? {
        guard PrivateAPIGuard.begin("brightness") else { return nil }
        if !didLoadDisplayServices {
            didLoadDisplayServices = true
            if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) {
                getBrightnessFn = dlsym(handle, "DisplayServicesGetBrightness").map({ unsafeBitCast($0, to: GetBrightnessFn.self) })
                setBrightnessFn = dlsym(handle, "DisplayServicesSetBrightness").map({ unsafeBitCast($0, to: SetBrightnessFn.self) })
            }
        }
        guard let get = getBrightnessFn, let set = setBrightnessFn else {
            PrivateAPIGuard.failed("brightness"); return nil
        }
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
        // Dahili ekran etkin değilse (uyanma, ekran yeniden yapılandırması) okuma geçici olarak yoktur; API bozuk değildir.
        guard let first = read() else { PrivateAPIGuard.unavailable("brightness"); return nil }
        guard first.isFinite, (0...1).contains(first) else { PrivateAPIGuard.failed("brightness"); return nil }
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
        if !didLoadKeyboard {
            didLoadKeyboard = true
            _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
            keyboardClientClass = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
        }
        guard let cls = keyboardClientClass else {
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
