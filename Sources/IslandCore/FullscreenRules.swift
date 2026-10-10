import CoreGraphics
import Foundation

/// Tam ekran davranışı (Ayarlar).
public enum FullscreenBehavior: String, CaseIterable, Sendable {
    /// Canlı etkinlikler ve bildirimler gizlenir (acil pil uyarısı hariç); imleç çentiğe gidince ada açılır.
    case smart
    /// Tam ekranı yok say.
    case alwaysShow
    /// Ada tam ekranda hiç açılmaz; yalnızca kullanıcının kendi eylemi olan ses/parlaklık göstergesi görünür.
    case alwaysHide
}

/// `CGWindowListCopyWindowInfo` kaydının izin gerektirmeyen alanları.
public struct WindowSnapshot: Sendable, Equatable {
    public var ownerPID: Int32
    public var layer: Int
    /// CG global koordinatları (sol-üst orijin).
    public var bounds: CGRect

    public init(ownerPID: Int32, layer: Int, bounds: CGRect) {
        self.ownerPID = ownerPID
        self.layer = layer
        self.bounds = bounds
    }
}

public enum FullscreenDetector {
    /// Menü çubuğu penceresinin katmanı (`kCGMainMenuWindowLevel`).
    public static let menuBarLayer = 24

    /// Ada içerikleri gizli kalmalı mı: tam ekran Space veya pencerenin fiziksel çentik bandına
    /// girdiği tam ekrandan çıkış anı.
    ///
    /// Kural: başka bir sürecin normal katmandaki (0) penceresi ekranın tam genişliğini kaplıyor, alt
    /// kenara oturuyor ve üst kenarı ekranın tepesine ya da en fazla güvenli alan (çentik) kadar altına
    /// uzanıyor **ve** o ekranın menü çubuğu görünmüyor. İkinci koşul, menü çubuğu görünürken ekranı
    /// dolduran (zoom yapılmış) normal pencereleri tam ekran sanmamayı sağlar.
    public static func isFullscreen(display: CGRect, safeTopInset: CGFloat, windows: [WindowSnapshot], ownPID: Int32) -> Bool {
        // macOS önce menü çubuğunu geri getirip uygulama penceresini aşağı kaydırabilir. Bu aralıkta
        // menü çubuğunun görünmesi tek başına geçişin bittiğini göstermez: ön plan penceresi hâlâ
        // çentiğin güvenli bandını kaplıyorsa adanın canlı içeriğini gizli tut.
        if windowCrossesNotchBand(display: display, safeTopInset: safeTopInset, windows: windows, ownPID: ownPID) {
            return true
        }

        let menuBarVisible = windows.contains { window in
            window.layer == menuBarLayer
                && abs(window.bounds.minY - display.minY) < 1
                && window.bounds.width >= display.width * 0.9
                && window.bounds.intersects(display)
        }
        guard !menuBarVisible else { return false }
        return windows.contains { window in
            window.layer == 0 && window.ownerPID != ownPID
                && abs(window.bounds.minX - display.minX) < 1
                && abs(window.bounds.width - display.width) < 1
                && abs(window.bounds.maxY - display.maxY) < 1
                && window.bounds.minY <= display.minY + safeTopInset + 1
        }
    }

    /// Ön plandaki uygulama penceresi ekranın yatay merkezini (fiziksel notch) hâlâ kaplıyor mu?
    /// Yalnızca tam ekran çıkışında çentik bandına giren üst kenarı dikkate alır; normal pencere
    /// çerçevesi güvenli alanın altına geldiğinde false olur.
    private static func windowCrossesNotchBand(display: CGRect, safeTopInset: CGFloat,
                                               windows: [WindowSnapshot], ownPID: Int32) -> Bool {
        guard safeTopInset > 0 else { return false }
        let centerX = display.midX
        // CGWindowListCopyWindowInfo returns top-to-bottom order. Consider the first application
        // window crossing the notch's horizontal center so an unrelated window behind it cannot
        // keep the transition state alive indefinitely.
        guard let window = windows.first(where: { window in
            window.layer == 0 && window.ownerPID != ownPID
                && window.bounds.minX <= centerX && window.bounds.maxX >= centerX
                && window.bounds.intersects(display)
        }) else { return false }
        return window.bounds.minY < display.minY + safeTopInset
            && window.bounds.maxY > display.minY + safeTopInset
    }
}

/// Prevents a one-frame window-server snapshot during full-screen exit from reopening the island early.
public struct FullscreenExitConfirmation: Sendable {
    private var pendingExits: Set<UInt32> = []
    private var lastFullscreen: [UInt32: TimeInterval] = [:]
    /// Tam ekran son görüldükten sonra ada içeriğinin geri dönmesi için en az geçmesi gereken süre.
    /// macOS çıkış animasyonu pencereyi çentik bandından geçirir; iki ölçüm animasyon bitmeden yapılırsa
    /// kanatlar uygulama penceresinin sekme şeridinin üstüne binerdi. 0: yalnızca iki ölçüm (testlerde).
    public let settleDelay: TimeInterval

    public init(settleDelay: TimeInterval = 0) {
        self.settleDelay = settleDelay
    }

    /// A safe exit snapshot still needs its follow-up before content can return.
    public var needsConfirmation: Bool { !pendingExits.isEmpty }

    /// Entering full screen applies immediately; leaving requires two consecutive non-fullscreen snapshots
    /// and, when `settleDelay` is set, that much time since full screen was last observed.
    public mutating func apply(current: [UInt32: Bool], detected: [UInt32: Bool],
                               now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [UInt32: Bool] {
        var result = current
        for displayID in Set(current.keys).union(detected.keys) {
            let wasFullscreen = current[displayID] ?? false
            let isFullscreen = detected[displayID] ?? false
            if isFullscreen { lastFullscreen[displayID] = now }
            if wasFullscreen && !isFullscreen {
                let settled = now - (lastFullscreen[displayID] ?? -.infinity) >= settleDelay
                if pendingExits.contains(displayID), settled {
                    pendingExits.remove(displayID)
                    lastFullscreen[displayID] = nil
                    result[displayID] = false
                } else {
                    pendingExits.insert(displayID)
                    result[displayID] = true
                }
            } else {
                pendingExits.remove(displayID)
                result[displayID] = isFullscreen
            }
        }
        return result
    }

    public mutating func reset() {
        pendingExits.removeAll()
        lastFullscreen.removeAll()
    }
}
