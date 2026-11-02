import AppKit
import EventKit
import IslandCore
import SwiftUI
import os
import CryptoKit

/// Geometri tanılaması (yalnızca `OPENISLAND_DIAGNOSTICS=<dosya>` ortam değişkeniyle açılır; normal
/// çalışmada hiçbir kod yolu etkin değildir).
///
/// Siyah yüzeyin gerçekten hesaplanan kontur sınırını (`Shape.path`) ekran koordinatlarına çevirip
/// beklenen değerle karşılaştırır: üst kenar `screen.frame.maxY − topInset`, yatay merkez
/// `screen.frame.midX`, boyut `IslandLayoutEngine` çıktısı. Ekran kaydı izni gerektirmez.
/// `OPENISLAND_DIAGNOSTICS_SCRIPT=1` ile adayı sırayla tüm temel durumlardan geçirir ve her durumda
/// ölçüm alır (kullanıcının imleci hiç kullanılmaz).
@MainActor
final class IslandDiagnostics {
    static let shared: IslandDiagnostics? = {
        guard let path = ProcessInfo.processInfo.environment["OPENISLAND_DIAGNOSTICS"], !path.isEmpty else { return nil }
        return IslandDiagnostics(output: URL(fileURLWithPath: path))
    }()

    static var isEnabled: Bool { shared != nil }
    /// Keep logging/test input separate from per-frame geometry instrumentation in CPU runs.
    static var measuresGeometry: Bool {
        isEnabled && ProcessInfo.processInfo.environment["OPENISLAND_GEOMETRY_PROBE"] != "0"
    }

    var surfaceRecorder: SurfaceGeometryRecorder? { Self.measuresGeometry ? geometryRecorder : nil }
    private let geometryRecorder = SurfaceGeometryRecorder()

    private let output: URL
    private var lines: [String] = []
    private var lastRendered: CGRect?
    private let signpostLog = OSLog(subsystem: "io.github.openisland.performance", category: .pointsOfInterest)
    private var benchmarkCPUStart: [String: Double] = [:]
    private func processCPUSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    private var signpostIDs: [String: OSSignpostID] = [:]
    private var emitsSignposts: Bool { ProcessInfo.processInfo.environment["OPENISLAND_SIGNPOSTS"] == "1" }

    private init(output: URL) {
        self.output = output
    }

    func recordRendered(_ rect: CGRect) {
        lastRendered = rect
    }

    func log(_ line: String) {
        lines.append(line)
        try? lines.joined(separator: "\n").appending("\n").write(to: output, atomically: true, encoding: .utf8)
    }

    /// Anlık ölçüm: beklenen ve çizilen dikdörtgeni karşılaştırır.
    func checkpoint(_ step: String, controller: NotchWindowController) {
        let screen = controller.screen
        let layout = controller.model.layout
        let expected = CGRect(
            x: screen.anchor.x - layout.size.width / 2,
            y: screen.frame.maxY - layout.topInset - layout.size.height,
            width: layout.size.width, height: layout.size.height
        )
        let renderedSurface = geometryRecorder.latest().map { rect in
            CGRect(x: controller.panel.frame.minX + rect.minX,
                   y: controller.panel.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        guard let rendered = renderedSurface ?? lastRendered else {
            log("✘ \(step): çizim ölçümü yok")
            return
        }
        let topOK = abs(rendered.maxY - (screen.frame.maxY - layout.topInset)) < 0.01
        let centerOK = abs(rendered.midX - screen.frame.midX) < 0.01
        let sizeOK = abs(rendered.width - expected.width) < 0.01 && abs(rendered.height - expected.height) < 0.01
        let mark = topOK && centerOK && sizeOK ? "✔" : "✘"
        log("\(mark) \(step) [\(controller.model.presentation)] çizilen x=\(f(rendered.minX))…\(f(rendered.maxX)) y=\(f(rendered.minY))…\(f(rendered.maxY)) "
            + "boyut=\(f(rendered.width))×\(f(rendered.height)) | tavan \(topOK ? "kilitli" : "KAYDI") · merkez \(f(rendered.midX)) \(centerOK ? "=" : "≠") \(f(screen.frame.midX)) · boyut \(sizeOK ? "doğru" : "YANLIŞ")")
    }

    func logEnvironment(controller: NotchWindowController) {
        let statuses = ["notDetermined", "restricted", "denied", "fullAccess", "writeOnly"]
        func name(_ status: EKAuthorizationStatus) -> String { statuses.indices.contains(status.rawValue) ? statuses[status.rawValue] : "\(status.rawValue)" }
        log("izin: takvim \(name(EKEventStore.authorizationStatus(for: .event))) · anımsatıcılar \(name(EKEventStore.authorizationStatus(for: .reminder)))")
        let screen = controller.screen
        log("ekran \(screen.name): frame=\(screen.frame) ölçek=\(screen.backingScale) midX=\(f(screen.frame.midX)) maxY=\(f(screen.frame.maxY))")
        if let notch = screen.notchRect {
            log("donanım çentiği (aux alanlar): x=\(f(notch.minX))…\(f(notch.maxX)) \(f(notch.width))×\(f(notch.height)) merkez=\(f(notch.midX))")
        }
        log("görsel panel: \(controller.panel.frame) · sensör: \(controller.sensor.frame)")
    }

    /// Yüzeyi `ImageRenderer` ile sRGB olarak (2×) çizer ve piksel düzeyinde denetler:
    /// gövde tam #000000 mi; çentiğin yanında hiç piksel (kontur, gölge, hale) var mı; notch'ta açık adanın
    /// altında gölge var mı (Revizyon 18: açık ada da çentiğin gölgesiz devamıdır). Ekran kaydı izni gerektirmez.
    func verifySurface(metrics: NotchMetrics) {
        let margin: CGFloat = 44
        let cases: [(String, IslandPresentation)] = [
            ("idle", .idle), ("peek", .peek(nil)), ("compact", .compact(.media)),
            ("bildirim", .notice(.unlocked)), ("genişletilmiş", .expanded(.media)),
        ]
        for (name, presentation) in cases {
            let layout = IslandLayoutEngine.layout(for: presentation, metrics: metrics)
            let shape = IslandShape(style: metrics.style, topRadius: layout.topCornerRadius, bottomRadius: layout.bottomCornerRadius)
            let clearance = metrics.style == .notch ? metrics.notchSize.height : 0
            let view = Color.clear
                .frame(width: layout.size.width, height: layout.size.height)
                .background { IslandSurface(shape: shape, elevation: layout.elevation, shadowClearance: clearance) }
                .overlay { IslandEdgeHighlight(shape: shape, intensity: layout.edgeHighlight) }
                .padding(.horizontal, margin)
                .padding(.bottom, margin)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage, let pixels = PixelProbe(image) else {
                log("✘ yüzey \(name): çizilemedi")
                continue
            }
            // Noktadan piksele (2×, sol-üst orijin).
            func px(_ x: CGFloat, _ y: CGFloat) -> (UInt8, UInt8, UInt8, UInt8) { pixels.rgba(x: Int(x * 2), y: Int(y * 2)) }
            let center = px(margin + layout.size.width / 2, min(layout.size.height / 2, 12))
            let pureBlack = center == (0, 0, 0, 255)
            // Çentik bandında adanın 3 pt yanı: tamamen şeffaf olmalı (hale/gölge/kontur yok).
            let bandY = min(clearance > 0 ? clearance - 4 : 4, layout.size.height / 2)
            let besideLeft = px(margin - 3, bandY), besideRight = px(margin + layout.size.width + 3, bandY)
            let bandClean = besideLeft.3 == 0 && besideRight.3 == 0
            let below = px(margin + layout.size.width / 2, layout.size.height + 8)
            let belowClean = layout.elevation > 0 || below.3 == 0
            var line = "\(pureBlack && bandClean && belowClean ? "✔" : "✘") yüzey \(name): merkez rgba\(center) \(pureBlack ? "= #000000" : "≠ #000000") · "
                + "çentik bandında yan piksel alfa \(besideLeft.3)/\(besideRight.3) \(bandClean ? "(temiz)" : "(HALE)")"
            line += layout.elevation > 0 ? " · alt gölge alfa \(below.3)"
                                         : " · altında alfa \(below.3) \(belowClean ? "(gölgesiz)" : "(GÖLGE)")"
            log(line)
        }
    }

    /// Genişletilmiş sekmenin içeriğini gerçek verilerle, ayrılan genişlikte ideal yüksekliğine göre ölçer:
    /// gövdenin ne kadarının içerik, ne kadarının boş siyah alan olduğunu gösterir.
    func measureContent(_ tab: ExpandedTab, environment: AppEnvironment, metrics: NotchMetrics) {
        let layout = IslandLayoutEngine.layout(for: .expanded(tab), metrics: metrics)
        let side = IslandLayoutEngine.contentSideInset(for: layout, style: metrics.style, size: metrics.expandedSurfaceSize)
        let width = layout.size.width - 2 * side
        let allotted = layout.size.height - metrics.notchSize.height - IslandLayoutEngine.headerGap - IslandLayoutEngine.expandedBottomInset(for: metrics)
        let panel: AnyView = switch tab {
        case .nook: AnyView(NookPanel(environment: environment, metrics: metrics))
        case .media: AnyView(MediaPanel(media: environment.media, metrics: metrics))
        case .shelf: AnyView(ShelfPanel(shelf: environment.shelf))
        case .clipboard: AnyView(ClipboardPanel(history: environment.clipboard, colors: environment.colorPicker))
        case .focus: AnyView(FocusPanel(timer: environment.focusTimer))
        case .notes: AnyView(NotesPanel(notes: environment.notes, launcher: environment.launcher))
        case .mirror: AnyView(EmptyView())
        case .system: AnyView(SystemPanel(system: environment.system))
        case .mixer: AnyView(AudioMixerPanel(mixer: environment.audioMixer, settings: environment.openSettings))
        }
        let host = NSHostingView(rootView: panel.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, .dark))
        let ideal = host.fittingSize.height
        log("  içerik \(tab): genişlik \(f(width)) · ideal yükseklik \(f(ideal)) / ayrılan \(f(allotted)) · boş \(f(max(allotted - ideal, 0))) pt "
            + "(pano \(environment.clipboard.items.count), raf \(environment.shelf.items.count), etkinlik \(environment.calendar.events.count), "
            + "anımsatıcı \(environment.reminders.items.count), başlatıcı \(environment.launcher.items.count))")
    }

    /// Adayı sırayla temel durumlardan geçirir. Her adımdan sonra yayın durmasını bekler.
    func runScript(on controller: NotchWindowController, environment: AppEnvironment) {
        let model = controller.model
        Task { @MainActor in
            let original = model.machine.configuration
            var deterministic = original
            deterministic.expandsOnHover = false
            model.configure(deterministic)
            logEnvironment(controller: controller)
            log("sistem: erişilebilirlik \(AXIsProcessTrusted() ? "güvenilir" : "YOK") "
                + "· ses aygıtı bildirimi \(environment.preferences.audioDeviceNotices) "
                + "· tam ekran \(environment.fullscreen.state) · ada tam ekran sayıyor \(model.machine.context.isFullscreen) "
                + "· Space sunumu \(SpacePresentationController.shared.status) (sıra \(SpacePresentationController.shared.order.map(\.rawValue)), "
                + "A/B tercihi \(SpacePresentationController.shared.preferred?.rawValue ?? "yok"))")
            verifySurface(metrics: model.metrics)

            @MainActor func step(_ name: String, _ events: [IslandEvent], wait: Double = 1.4) async {
                for event in events { model.send(event) }
                try? await Task.sleep(for: .seconds(wait))
                checkpoint(name, controller: controller)
            }

            await step("dinlenme", [], wait: 1.4)
            log("sensör (dinlenme): \(controller.sensor.frame)")
            await step("hover kabarması", [.pointerEntered])
            await step("genişletilmiş · medya", [.selectTab(.media), .tapped])
            let wasPinned = model.machine.context.isPinned
            if !wasPinned { model.send(.togglePin) }
            // Her sekme: çizilen gövde (ekran ölçüsü) + içerik ideal yüksekliği (boş alan).
            for (name, tab) in [("nook", ExpandedTab.nook), ("medya", .media), ("notlar", .notes), ("pano", .clipboard),
                                ("raf", .shelf), ("odak", .focus), ("sistem", .system), ("mikser", .mixer)] {
                await step("sekme · \(name)", [.selectTab(tab)])
                measureContent(tab, environment: environment, metrics: model.metrics)
            }
            if !wasPinned { model.send(.togglePin) }
            await step("kapanma", [.escapePressed, .pointerExited])
            await step("bildirim · şarj", [.noticeRequested(.power(PowerEvent(kind: .pluggedIn, level: 0.8, isCharging: true)))], wait: 1.0)
            try? await Task.sleep(for: .seconds(3))
            await step("HUD · ses", [.hudRequested(HUDPayload(kind: .volume(muted: false), level: 0.5))], wait: 0.6)
            try? await Task.sleep(for: .seconds(1.5))
            await step("yeniden dinlenme", [], wait: 0.5)
            // Let the subpixel spring tail settle before comparing the exact target. Still leaves
            // room for the queued Bluetooth check before the unchanged 1.1-second notice expiry.
            await step("unlock · yatay geri bildirim", [.noticeRequested(.unlocked)], wait: 0.8)
            await step("unlock · Bluetooth sırada", [
                .noticeRequested(.audioOutput(name: "Test kulaklığı", kind: .headphones, connected: true))
            ], wait: 0.2)
            await step("Bluetooth · unlock sonrası", [], wait: 0.95)
            await step("Bluetooth · normal duruma dönüş", [], wait: 2)
            log("sensör (son): \(controller.sensor.frame)")
            model.configure(original)
            log("bitti")
        }
    }

    /// Explicit developer run only; no task is created in normal operation.
    func runPerformanceScript(on controller: NotchWindowController, environment: AppEnvironment) {
        if let mode = ProcessInfo.processInfo.environment["OPENISLAND_BENCHMARK_V2"] {
            runControlledBenchmark(mode: mode, controller: controller, environment: environment)
            return
        }
        let model = controller.model
        let quick = ProcessInfo.processInfo.environment["OPENISLAND_PERFORMANCE_QUICK"] == "1"
        let cycles = quick ? 20 : 40
        Task { @MainActor in
            let originalConfiguration = model.machine.configuration
            let originalDemoMode = model.machine.context.isDemoMode
            let originalTab = model.machine.context.lastTab
            defer {
                model.send(.escapePressed)
                model.send(.demoModeChanged(isOn: originalDemoMode))
                model.send(.selectTab(originalTab))
                model.configure(originalConfiguration)
            }
            log("performance start; hover enabled=\(originalConfiguration.expandsOnHover); hover delay=\(originalConfiguration.hoverExpandDelay)")
            model.send(.pointerExited)
            model.send(.escapePressed)
            model.cancelPendingEffects()
            try? await Task.sleep(for: .seconds(2))
            for index in 0..<1000 {
                model.send(.pointerEntered)
                model.send(.pointerExited)
                if index % 100 == 0 { log("rapid hover \(index); pending tasks=\(model.pendingEffectCount)") }
            }
            try? await Task.sleep(for: .seconds(1))
            log("rapid hover settled; pending tasks=\(model.pendingEffectCount)")
            // Use the real rendered panel, but keep a physical pointer exit from
            // cancelling the developer's synthetic input. Never persist test settings.
            model.send(.demoModeChanged(isOn: true))
            model.send(.selectTab(.nook))
            log("animated open-close start; epoch=\(Date().timeIntervalSince1970)")
            for index in 0..<cycles {
                model.send(.tapped)
                try? await Task.sleep(for: .seconds(0.4))
                guard model.machine.isExpanded else {
                    log("FAIL: cycle \(index) never expanded; performance run invalid")
                    return
                }
                model.send(.escapePressed)
                try? await Task.sleep(for: .seconds(0.4))
                guard !model.machine.isEngaged else {
                    log("FAIL: cycle \(index) never collapsed; performance run invalid")
                    return
                }
                if index % 10 == 0 { log("verified open-close \(index); pending tasks=\(model.pendingEffectCount)") }
            }
            model.send(.escapePressed)
            model.cancelPendingEffects()
            log("animated open-close finished; epoch=\(Date().timeIntervalSince1970); verified cycles=\(cycles); pending tasks=\(model.pendingEffectCount)")
            model.send(.tapped)
            guard model.machine.isExpanded else { log("FAIL: static panel never expanded"); return }
            log("static expanded start; epoch=\(Date().timeIntervalSince1970)")
            try? await Task.sleep(for: .seconds(quick ? 10 : 30))
            log("static expanded end; epoch=\(Date().timeIntervalSince1970)")
            model.send(.selectTab(.system))
            log("system panel start; epoch=\(Date().timeIntervalSince1970)")
            try? await Task.sleep(for: .seconds(quick ? 12 : 20))
            log("system panel end; epoch=\(Date().timeIntervalSince1970); running=\(environment.system.isRunning)")
            if ProcessInfo.processInfo.environment["OPENISLAND_PERFORMANCE_EXTENDED"] == "1" {
                let tabs: [ExpandedTab] = [.media, .shelf, .clipboard, .notes, .nook, .system]
                for (phase, delay, passes) in [("normal tabs", 0.65, 3), ("rapid tabs", 0.08, 5)] {
                    log("\(phase) start; epoch=\(Date().timeIntervalSince1970)")
                    for _ in 0..<passes {
                        for tab in tabs {
                            model.send(.selectTab(tab))
                            try? await Task.sleep(for: .seconds(delay))
                            guard model.presentation.expandedTab == tab else { log("FAIL: tab \(tab) did not activate"); return }
                        }
                    }
                    log("\(phase) end; epoch=\(Date().timeIntervalSince1970)")
                }
                model.send(.selectTab(.media))
                log("media start; epoch=\(Date().timeIntervalSince1970); playing=\(environment.media.isPlaying); title=\(environment.media.nowPlaying?.title ?? "none")")
                try? await Task.sleep(for: .seconds(quick ? 12 : 20))
                log("media end; epoch=\(Date().timeIntervalSince1970); playing=\(environment.media.isPlaying)")
            }
            model.send(.escapePressed)
            model.cancelPendingEffects()
            if let value = ProcessInfo.processInfo.environment["OPENISLAND_PERFORMANCE_AUDIO_PID"], let pid = pid_t(value) {
                environment.audioMixer.showPanel()
                defer { environment.audioMixer.hidePanel() }
                if environment.audioMixer.applications.contains(where: { $0.id == pid && $0.isPlaying }) {
                    let originalVolume = environment.audioMixer.volumes[pid] ?? 1
                    defer { environment.audioMixer.setApplicationVolume(originalVolume, pid: pid) }
                    environment.audioMixer.setApplicationVolume(0.5, pid: pid)
                    try? await Task.sleep(for: .seconds(5))
                    log("audio route start; epoch=\(Date().timeIntervalSince1970); routes=\(environment.audioMixer.activeRouteCount); error=\(environment.audioMixer.error ?? "none")")
                    try? await Task.sleep(for: .seconds(quick ? 12 : 20))
                    log("audio route end; epoch=\(Date().timeIntervalSince1970); routes=\(environment.audioMixer.activeRouteCount); error=\(environment.audioMixer.error ?? "none")")
                } else { log("SKIP: requested audio fixture is not playing") }
            }
            try? await Task.sleep(for: .seconds(2))
            log("idle start; epoch=\(Date().timeIntervalSince1970); system running=\(environment.system.isRunning); routes=\(environment.audioMixer.activeRouteCount); pending tasks=\(model.pendingEffectCount)")
            try? await Task.sleep(for: .seconds(quick ? 40 : 60))
            log("performance finished; pending tasks=\(model.pendingEffectCount)")
        }
    }

    /// Developer-only: OPENISLAND_BENCHMARK_RAPID_MS sets the profile-rapid interval (20…1000 ms); otherwise the original 80 ms.
    private static func benchmarkRapidDelay() -> Int {
        guard let value = ProcessInfo.processInfo.environment["OPENISLAND_BENCHMARK_RAPID_MS"], let ms = Int(value),
              (20...1000).contains(ms) else { return 80 }
        return ms
    }

    /// Yalnızca geliştirici: `profile-rapid` tur sayısı (uzun süreli bellek ölçümü için). Geçersizse özgün 80.
    private static func benchmarkRapidPasses() -> Int {
        guard let value = ProcessInfo.processInfo.environment["OPENISLAND_BENCHMARK_PASSES"], let passes = Int(value),
              (1...5000).contains(passes) else { return 80 }
        return passes
    }

    /// Benchmark sekme sırası. Ortam değişkeni yoksa veya geçersiz bir ad içeriyorsa varsayılan sıra kullanılır.
    private static func benchmarkTabs(default tabs: [ExpandedTab]) -> [ExpandedTab] {
        guard let value = ProcessInfo.processInfo.environment["OPENISLAND_BENCHMARK_TABS"], !value.isEmpty else { return tabs }
        let parsed = value.split(separator: ",").map { name in
            ExpandedTab.allCases.first { String(describing: $0) == name.trimmingCharacters(in: .whitespaces) }
        }
        guard !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) else { return tabs }
        return parsed.compactMap { $0 }
    }

    /// Repeatable developer-only workloads. No preferences, media controls or saved files are changed.
    private func runControlledBenchmark(mode: String, controller: NotchWindowController, environment: AppEnvironment) {
        if mode == "media-validation" || mode == "media-seek-validation" || mode == "media-quiet-validation" || mode == "media-pause-validation" {
            runMediaValidation(controller: controller, environment: environment)
            return
        }
        let model = controller.model
        let seconds = max(305, min(1800, Double(ProcessInfo.processInfo.environment["OPENISLAND_BENCHMARK_SECONDS"] ?? "305") ?? 305))
        Task { @MainActor in
            let originalDemo = model.machine.context.isDemoMode
            let originalTab = model.machine.context.lastTab
            defer {
                model.send(.escapePressed)
                model.cancelPendingEffects()
                model.send(.demoModeChanged(isOn: originalDemo))
                model.send(.selectTab(originalTab))
            }
            model.send(.escapePressed)
            model.cancelPendingEffects()
            model.send(.demoModeChanged(isOn: true))
            try? await Task.sleep(for: .seconds(2))
            // Developer-only: OPENISLAND_BENCHMARK_TABS=media,shelf,... overrides the original six-tab order.
            let tabs = Self.benchmarkTabs(default: [.media, .shelf, .clipboard, .notes, .nook, .system])
            log("controlled start; mode=\(mode); tabs=\(tabs.map { String(describing: $0) }.joined(separator: ",")); playing=\(environment.media.isPlaying); title=\(environment.media.nowPlaying?.title ?? "none")")
            if mode == "open-close" {
                // Developer-only: N aç/kapat döngüsü (demo modu kapalı, gerçek kapanma yolu). Animasyon akıcılığı
                // karşılaştırması için; her açılış/kapanış bir Points of Interest aralığıdır.
                model.send(.demoModeChanged(isOn: false))
                let cycles = max(1, min(60, Int(ProcessInfo.processInfo.environment["OPENISLAND_BENCHMARK_CYCLES"] ?? "12") ?? 12))
                try? await Task.sleep(for: .seconds(1))
                beginBenchmarkPhase("open-close")
                let hover = ProcessInfo.processInfo.environment["OPENISLAND_BENCHMARK_HOVER"] == "1"
                // OPENISLAND_BENCHMARK_TAB: açılacak sekme (varsayılan medya); ör. `nook`, uygulamanın önceden kurduğu sekme.
                let tab = ProcessInfo.processInfo.environment["OPENISLAND_BENCHMARK_TAB"].flatMap(ExpandedTab.init(rawValue:)) ?? .media
                for _ in 0..<cycles {
                    beginBenchmarkPhase("open")
                    model.send(.selectTab(tab))
                    // Hover yolu: kabarma → gecikmeyle genişleme (kullanıcının adayı fareyle açması).
                    model.send(hover ? .pointerEntered : .tapped)
                    // Explicit, isolated fault injection. Never reachable from
                    // a normal launch; TestIsolationGuard has already required
                    // a validation bundle and private stores before startup.
                    if Bundle.main.bundleIdentifier?.hasPrefix("io.github.openisland.validation.") == true,
                       let raw = ProcessInfo.processInfo.environment["OPENISLAND_BENCHMARK_STALL_MS"],
                       let milliseconds = UInt32(raw), milliseconds > 0, milliseconds <= 250 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                            self.log("injected main stall start; milliseconds=\(milliseconds)")
                            usleep(milliseconds * 1000)
                            self.log("injected main stall end")
                        }
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                    endBenchmarkPhase("open")
                    guard model.machine.isExpanded else { log("FAIL: open-close did not expand"); return }
                    beginBenchmarkPhase("close")
                    model.send(.escapePressed)
                    model.send(.pointerExited)
                    try? await Task.sleep(for: .seconds(1.5))
                    endBenchmarkPhase("close")
                    guard !model.machine.isExpanded else { log("FAIL: open-close did not collapse"); return }
                }
                endBenchmarkPhase("open-close")
            } else if mode == "idle-compact" {
                beginBenchmarkPhase("idle compact")
                try? await Task.sleep(for: .seconds(seconds))
                endBenchmarkPhase("idle compact")
                guard !model.machine.isEngaged else { log("FAIL: compact idle became engaged"); return }
            } else {
                model.send(.selectTab(.nook))
                model.send(.tapped)
                try? await Task.sleep(for: .seconds(2))
                guard model.machine.isExpanded else { log("FAIL: benchmark did not expand"); return }
                if mode == "idle-expanded" {
                    beginBenchmarkPhase("idle expanded")
                    try? await Task.sleep(for: .seconds(seconds))
                    endBenchmarkPhase("idle expanded")
                    guard model.machine.isExpanded else { log("FAIL: expanded idle closed"); return }
                } else if mode == "tab-speeds" || mode == "profile-rapid" {
                    for tab in tabs {
                        model.send(.selectTab(tab))
                        try? await Task.sleep(for: .milliseconds(350))
                    }
                    let delays = mode == "profile-rapid" ? [Self.benchmarkRapidDelay()] : [650, 300, 150, 80, 50]
                    let passes = mode == "profile-rapid" ? Self.benchmarkRapidPasses() : 9
                    for delay in delays {
                        let phase = "speed \(delay)ms"
                        beginBenchmarkPhase(phase)
                        var selected = 0
                        var synchronousCPU: Double = 0
                        for _ in 0..<passes {
                            for tab in tabs {
                                if emitsSignposts {
                                    os_signpost(.event, log: signpostLog, name: "Tab selected", "%{public}@", String(describing: tab) as NSString)
                                }
                                let cpu = processCPUSeconds() ?? 0
                                model.send(.selectTab(tab))
                                synchronousCPU += (processCPUSeconds() ?? cpu) - cpu
                                selected += 1
                                try? await Task.sleep(for: .milliseconds(delay))
                                guard model.presentation.expandedTab == tab, model.machine.isExpanded else {
                                    log("FAIL: speed selection did not activate \(tab)"); return
                                }
                            }
                        }
                        endBenchmarkPhase(phase)
                        log("speed selections=\(selected); delay_ms=\(delay); synchronous_cpu=\(synchronousCPU); pending=\(model.pendingEffectCount); system_running=\(environment.system.isRunning); camera=\(environment.mirror.state); routes=\(environment.audioMixer.activeRouteCount)")
                    }
                } else if mode == "suite" || mode == "tabs" {
                    // Equal warm-up for both binaries; first-open cost remains in the separate cycle test.
                    for tab in tabs {
                        model.send(.selectTab(tab))
                        try? await Task.sleep(for: .milliseconds(350))
                    }
                    for round in 1...3 {
                        for (name, delay, passes) in [("normal tabs", 0.65, 3), ("rapid tabs", 0.08, 5)] {
                            let phase = "\(name) \(round)"
                            beginBenchmarkPhase(phase)
                            for _ in 0..<passes {
                                for tab in tabs {
                                    if emitsSignposts {
                                        os_signpost(.event, log: signpostLog, name: "Tab selected", "%{public}@", String(describing: tab) as NSString)
                                    }
                                    model.send(.selectTab(tab))
                                    try? await Task.sleep(for: .seconds(delay))
                                    guard model.presentation.expandedTab == tab else { log("FAIL: \(tab) did not activate"); return }
                                }
                            }
                            endBenchmarkPhase(phase)
                        }
                    }
                    if mode == "suite" {
                        for tab in [ExpandedTab.system, .media] {
                            model.send(.selectTab(tab))
                            let phase = "static \(tab)"
                            beginBenchmarkPhase(phase)
                            try? await Task.sleep(for: .seconds(30))
                            endBenchmarkPhase(phase)
                        }
                        model.send(.escapePressed)
                        model.send(.selectTab(.nook))
                        beginBenchmarkPhase("open close")
                        for _ in 0..<20 {
                            model.send(.tapped)
                            try? await Task.sleep(for: .milliseconds(400))
                            guard model.machine.isExpanded else { log("FAIL: cycle did not expand"); return }
                            model.send(.escapePressed)
                            try? await Task.sleep(for: .milliseconds(400))
                            guard !model.machine.isEngaged else { log("FAIL: cycle did not close"); return }
                        }
                        endBenchmarkPhase("open close")
                    }
                } else { log("FAIL: unknown benchmark mode \(mode)"); return }
            }
            log("controlled finished; mode=\(mode); playing=\(environment.media.isPlaying); system samples=\(environment.system.sampleCount); storage reads=\(environment.system.storageReadCount); pending tasks=\(model.pendingEffectCount)")
        }
    }

    /// Bounded, opt-in evidence only. Spotify commands belong to the external test driver.
    /// No demo mode: the product's actual compact/session behaviour remains enabled.
    private func runMediaValidation(controller: NotchWindowController, environment: AppEnvironment) {
        Task { @MainActor in
            let model = controller.model
            let originalTab = model.machine.context.lastTab
            let originalPin = model.isPinned
            var events = 0
            let observer = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated {
                events += 1
                self.log("media event; epoch=\(Date().timeIntervalSince1970); index=\(events)")
                if self.emitsSignposts {
                    os_signpost(.event, log: self.signpostLog, name: "Media notification")
                }
            } }
            defer {
                DistributedNotificationCenter.default().removeObserver(observer)
                if model.isPinned != originalPin { model.send(.togglePin) }
                model.send(.escapePressed)
                model.send(.selectTab(originalTab))
            }
            @MainActor func snapshot(_ phase: String) {
                @MainActor func descendants(_ view: NSView) -> [NSView] {
                    [view] + view.subviews.flatMap(descendants)
                }
                let waves = controller.panel.contentView.map(descendants)?.compactMap { $0 as? WaveformLayerView } ?? []
                let pulses = waves.flatMap { $0.layer?.sublayers ?? [] }.filter { $0.animation(forKey: "pulse") != nil }.count
                let info = environment.media.nowPlaying
                let row: [String: Any] = [
                    "epoch": Date().timeIntervalSince1970, "phase": phase,
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "binary": Bundle.main.executablePath ?? "", "expanded": model.machine.isExpanded,
                    "presentation": String(describing: model.presentation), "tab": String(describing: model.presentation.expandedTab),
                    "title": info?.title ?? "", "artist": info?.artist ?? "", "album": info?.album ?? "",
                    "source": environment.media.activeSourceID ?? "", "playing": environment.media.isPlaying,
                    "duration": info?.duration ?? 0, "elapsed": info?.elapsed(at: Date()) ?? 0,
                    "artworkBytes": info?.artworkData?.count ?? 0,
                    "artworkSHA256": info?.artworkData.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "",
                    "decodedArtwork": environment.media.artwork != nil,
                    "waveformViews": waves.count, "pulseLayers": pulses, "spotifyEvents": events,
                    "pendingEffects": model.pendingEffectCount,
                    "cameraState": String(describing: environment.mirror.state),
                    "mixerRoutes": environment.audioMixer.activeRouteCount
                ]
                if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                   let text = String(data: data, encoding: .utf8) { log("media witness " + text) }
            }
            try? await Task.sleep(for: .seconds(3))
            let seekOnly = ProcessInfo.processInfo.environment["OPENISLAND_BENCHMARK_V2"] == "media-seek-validation"
            let pauseValidation = ProcessInfo.processInfo.environment["OPENISLAND_BENCHMARK_V2"] == "media-pause-validation"
            let quiet = pauseValidation || ProcessInfo.processInfo.environment["OPENISLAND_BENCHMARK_V2"] == "media-quiet-validation"
            let phases = pauseValidation ? [("playing compact", false, 20), ("playing expanded", true, 20),
                                             ("paused compact", false, 75), ("paused expanded", true, 60)]
                : quiet ? [("playing compact", false, 30), ("playing expanded", true, 30),
                                  ("paused compact", false, 30), ("paused expanded", true, 30)]
                : seekOnly ? [("track seek", true, 45)] : [
                ("playing compact", false, 60), ("playing expanded", true, 45),
                ("paused compact", false, 30), ("paused expanded", true, 30),
                ("track seek", true, 45), ("sustained compact", false, 180)
            ]
            for (phase, expanded, seconds) in phases {
                if model.isPinned { model.send(.togglePin) }
                model.send(.escapePressed)
                model.send(.selectTab(.media))
                if expanded { model.send(.tapped); model.send(.togglePin) }
                // Let the spring settle; no hover delay or product timing changes.
                try? await Task.sleep(for: .seconds(1))
                beginBenchmarkPhase("media " + phase)
                if quiet {
                    snapshot(phase)
                    try? await Task.sleep(for: .seconds(seconds))
                } else {
                for tick in 0..<seconds {
                    if phase == "track seek", tick == 32 || tick == 39 {
                        let position: Double = tick == 32 ? 45 : 10
                        environment.media.seek(to: position)
                        log("media control seek=\(position); epoch=\(Date().timeIntervalSince1970)")
                    }
                    snapshot(phase)
                    try? await Task.sleep(for: .seconds(1))
                }
                }
                snapshot(phase)
                endBenchmarkPhase("media " + phase)
            }
            if seekOnly || quiet { log("media validation finished; events=\(events)"); return }
            model.send(.escapePressed)
            model.send(.selectTab(.media))
            model.send(.tapped)
            try? await Task.sleep(for: .seconds(1))
            // Focus UI is safe without starting its timer. Camera and mixer are intentionally excluded.
            let tabs: [ExpandedTab] = [.nook, .media, .shelf, .clipboard, .focus, .notes, .system]
            for (phase, delay) in [("media normal seven tabs", 0.65), ("media rapid seven tabs", 0.08)] {
                beginBenchmarkPhase(phase)
                for _ in 0..<3 {
                    for tab in tabs {
                        model.send(.selectTab(tab))
                        try? await Task.sleep(for: .seconds(delay))
                        guard model.presentation.expandedTab == tab else { log("FAIL: media tab did not activate"); return }
                    }
                }
                endBenchmarkPhase(phase)
            }
            log("media validation finished; events=\(events)")
        }
    }

    private func beginBenchmarkPhase(_ name: String) {
        log("\(name) start; epoch=\(Date().timeIntervalSince1970)")
        benchmarkCPUStart[name] = processCPUSeconds()
        guard emitsSignposts else { return }
        let id = OSSignpostID(log: signpostLog)
        signpostIDs[name] = id
        os_signpost(.begin, log: signpostLog, name: "Benchmark phase", signpostID: id, "%{public}@", name as NSString)
    }

    private func endBenchmarkPhase(_ name: String) {
        let cpu = processCPUSeconds()
        let start = benchmarkCPUStart.removeValue(forKey: name)
        let suffix: String
        if let cpu, let start, cpu >= start {
            suffix = "; cpu_seconds=\(cpu - start)"
        } else {
            suffix = "; cpu_seconds=unavailable"
        }
        log("\(name) end; epoch=\(Date().timeIntervalSince1970)\(suffix)")
        guard let id = signpostIDs.removeValue(forKey: name) else { return }
        os_signpost(.end, log: signpostLog, name: "Benchmark phase", signpostID: id, "%{public}@", name as NSString)
    }

    func runMixerScript(environment: AppEnvironment, pid: pid_t) {
        Task { @MainActor in
            let mixer = environment.audioMixer
            mixer.showPanel()
            var cleanedUp = false
            defer {
                if !cleanedUp { mixer.restoreApplication(pid); mixer.hidePanel() }
            }
            guard let app = mixer.applications.first(where: { $0.id == pid }) else { log("mixer: app missing"); return }
            log("mixer: processes=\(app.processes) playing=\(app.isPlaying)")
            for value: Float in [0.25, 0.75, 0, 0.5] {
                mixer.setApplicationVolume(value, pid: pid)
                try? await Task.sleep(for: .seconds(5))
                log("mixer: requested=\(value) displayed=\(mixer.volumes[pid] ?? 1) routes=\(mixer.activeRouteCount) error=\(mixer.error ?? "none") state=\(mixer.diagnosticState(pid: pid))")
            }
            mixer.interruptRouteForDiagnostics(pid: pid)
            try? await Task.sleep(for: .seconds(2))
            log("mixer: interrupted-IO recovery state=\(mixer.diagnosticState(pid: pid)) routes=\(mixer.activeRouteCount)")
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            log("mixer: sleep routes=\(mixer.activeRouteCount)")
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            try? await Task.sleep(for: .seconds(2))
            log("mixer: wake recovery state=\(mixer.diagnosticState(pid: pid)) routes=\(mixer.activeRouteCount)")
            for _ in 0..<100 { mixer.hidePanel(); mixer.showPanel() }
            log("mixer: 100 cycles listeners=\(mixer.listenerCount) routes=\(mixer.activeRouteCount)")
            log("mixer: steady start epoch=\(Date().timeIntervalSince1970)")
            try? await Task.sleep(for: .seconds(30))
            log("mixer: steady end epoch=\(Date().timeIntervalSince1970) state=\(mixer.diagnosticState(pid: pid))")
            mixer.restoreApplication(pid)
            mixer.hidePanel()
            cleanedUp = true
            log("mixer: restored listeners=\(mixer.listenerCount) routes=\(mixer.activeRouteCount)")
        }
    }

    private func f(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }
}

/// CGImage piksellerini sRGB RGBA8 olarak okur.
private struct PixelProbe {
    private let data: [UInt8]
    private let width: Int
    private let height: Int

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = buffer
    }

    /// Sol-üst orijinli piksel koordinatı.
    func rgba(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let cx = min(max(x, 0), width - 1), cy = min(max(y, 0), height - 1)
        let i = (cy * width + cx) * 4
        return (data[i], data[i + 1], data[i + 2], data[i + 3])
    }
}
