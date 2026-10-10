import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import IslandCore

@Suite("IslandMachine durum geçişleri")
struct IslandMachineTests {
    @Test func hoverShowsPeekAndExitReturnsToIdle() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.pointerEntered)
        #expect(machine.presentation == .peek(nil))
        machine.send(.pointerExited)
        #expect(machine.presentation == .idle)
    }

    @Test func mediaPlaybackBecomesCompactActivity() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.mediaPlaybackChanged(isPlaying: true))
        #expect(machine.presentation == .compact(.media))

        machine.send(.pointerEntered)
        #expect(machine.presentation == .peek(.media))

        let effects = machine.send(.tapped)
        #expect(machine.presentation == .expanded(.nook), "Varsayılan açılış NotchNook gibi widget'lı ana görünüm")
        #expect(effects == [.haptic(.expanded)])
    }

    @Test func activityPriorityIsMediaThenTimerThenShelf() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.shelfCountChanged(2))
        #expect(machine.phase == .compact(.shelf))
        machine.send(.timerRunningChanged(isRunning: true))
        #expect(machine.phase == .compact(.timer))
        machine.send(.mediaPlaybackChanged(isPlaying: true))
        #expect(machine.phase == .compact(.media))
        let effects = machine.send(.mediaPlaybackChanged(isPlaying: false))
        #expect(machine.phase == .compact(.media), "Duraklatınca nabız kısa süre sakin formda kalır")
        guard case let .schedule(.mediaLinger, token, _)? = effects.first else {
            Issue.record("duraklatma bekleme zamanlayıcısı bekleniyordu"); return
        }
        machine.send(.timerFired(.mediaLinger, token: token))
        #expect(machine.phase == .compact(.timer), "Bekleme bitince öncelik sırası: zamanlayıcı")
    }

    @Test func pausedMediaLingersThenReturnsToNotch() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.mediaPlaybackChanged(isPlaying: true))
        let pause = machine.send(.mediaPlaybackChanged(isPlaying: false))
        guard case let .schedule(.mediaLinger, token, delay)? = pause.first else {
            Issue.record("bekleme zamanlayıcısı bekleniyordu"); return
        }
        #expect(delay == machine.configuration.pausedMediaLinger)
        #expect(machine.presentation == .compact(.media))

        // Bekleme içinde yeniden çalma: kanat kapanmaz; eski zamanlayıcı artık etkisizdir.
        machine.send(.mediaPlaybackChanged(isPlaying: true))
        machine.send(.timerFired(.mediaLinger, token: token))
        #expect(machine.presentation == .compact(.media))

        // Tekrar duraklat ve bekle: ada çentiğe döner.
        guard case let .schedule(.mediaLinger, second, _)? = machine.send(.mediaPlaybackChanged(isPlaying: false)).first else {
            Issue.record("ikinci bekleme zamanlayıcısı bekleniyordu"); return
        }
        machine.send(.timerFired(.mediaLinger, token: second))
        #expect(machine.presentation == .idle)
    }

    @Test func endedMediaSessionLeavesWithoutLinger() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.mediaPlaybackChanged(isPlaying: true))
        let effects = machine.send(.mediaPlaybackChanged(isPlaying: false))
        machine.send(.mediaSessionEnded)
        #expect(machine.presentation == .idle, "Parça kalmadıysa boş kanat beklemez")
        if case let .schedule(.mediaLinger, token, _)? = effects.first {
            machine.send(.timerFired(.mediaLinger, token: token))
        }
        #expect(machine.presentation == .idle)
        // Hiç çalmamış medyanın 'duraklatıldı' bildirimi bekleme başlatmaz.
        var fresh = IslandMachine(configuration: .init(expandsOnHover: false))
        #expect(fresh.send(.mediaPlaybackChanged(isPlaying: false)).isEmpty)
        #expect(fresh.presentation == .idle)
    }

    @Test func pointerExitStartsDecayAndReturnCancelsIt() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.pointerEntered)
        machine.send(.tapped)
        let effects = machine.send(.pointerExited)
        guard case let .schedule(.collapseGrace, staleToken, _)? = effects.first else {
            Issue.record("collapse zamanlayıcısı bekleniyordu"); return
        }
        #expect(machine.isRelaxing, "Kapanmadan önce yüzey sönümlenmeli")

        machine.send(.pointerEntered)
        #expect(!machine.isRelaxing)
        machine.send(.timerFired(.collapseGrace, token: staleToken))
        #expect(machine.isExpanded, "Eski jetonlu zamanlayıcı adayı kapatmamalı")
    }

    @Test func collapseGraceClosesExpandedIsland() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.mediaPlaybackChanged(isPlaying: true))
        machine.send(.pointerEntered)
        machine.send(.tapped)
        let effects = machine.send(.pointerExited)
        guard case let .schedule(.collapseGrace, token, _)? = effects.first else {
            Issue.record("collapse zamanlayıcısı bekleniyordu"); return
        }
        machine.send(.timerFired(.collapseGrace, token: token))
        #expect(machine.presentation == .compact(.media))
        #expect(!machine.isRelaxing)
        #expect(!machine.isEngaged)
    }

    @Test func hudOverlaysCompactButNotExpanded() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.mediaPlaybackChanged(isPlaying: true))
        let payload = HUDPayload(kind: .volume(muted: false), level: 0.5)
        let first = machine.send(.hudRequested(payload))
        #expect(machine.presentation == .hud(payload))

        // İkinci HUD isteği eski zamanlayıcıyı geçersiz kılar.
        machine.send(.hudRequested(HUDPayload(kind: .volume(muted: false), level: 0.6)))
        if case let .schedule(.hudDismiss, oldToken, _)? = first.first {
            machine.send(.timerFired(.hudDismiss, token: oldToken))
        }
        #expect(machine.hud != nil)

        machine.send(.pointerEntered)
        machine.send(.tapped)
        #expect(machine.presentation == .expanded(.nook), "Genişletilmiş görünüm HUD'a yer vermez; HUD banner olarak çizilir")
    }

    @Test func fileDragLocksThenDropOpensShelf() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        #expect(machine.send(.fileDragEntered) == [.haptic(.dropLocked)])
        #expect(machine.presentation == .dropTarget)
        let effects = machine.send(.fileDragEnded(dropped: true))
        #expect(machine.presentation == .expanded(.shelf))
        #expect(machine.context.lastTab == .shelf)
        #expect(effects.first == .haptic(.dropCompleted))
    }

    @Test func dragExitWaitsForGraceBeforeCollapsing() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.fileDragEntered)
        let effects = machine.send(.fileDragExited)
        guard case let .schedule(.dragExitGrace, token, _)? = effects.first else {
            Issue.record("sürükleme toleransı bekleniyordu"); return
        }
        #expect(machine.presentation == .dropTarget, "Kısa çıkışta ada hemen kapanmamalı")
        machine.send(.timerFired(.dragExitGrace, token: token))
        #expect(machine.presentation == .idle)
    }

    @Test func draggingBackInsideCancelsExitGrace() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.fileDragEntered)
        let effects = machine.send(.fileDragExited)
        machine.send(.fileDragEntered)
        if case let .schedule(.dragExitGrace, staleToken, _)? = effects.first {
            machine.send(.timerFired(.dragExitGrace, token: staleToken))
        }
        #expect(machine.presentation == .dropTarget)
    }

    @Test func fileDragWhileExpandedSwitchesToShelfTab() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.tapped)
        machine.send(.selectTab(.notes))
        machine.send(.fileDragEntered)
        #expect(machine.presentation == .expanded(.shelf))
    }

    @Test func pinnedIslandIgnoresOutsideClicksAndPointerExit() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.pointerEntered)
        #expect(machine.send(.togglePin) == [.haptic(.pinChanged)])
        #expect(machine.isExpanded)
        #expect(machine.send(.pointerExited).isEmpty)
        #expect(!machine.isRelaxing)
        machine.send(.tappedOutside)
        #expect(machine.isExpanded)
        machine.send(.escapePressed)
        #expect(!machine.isExpanded)
        #expect(!machine.context.isPinned)
    }

    @Test func hoverExpandsAutomaticallyByDefaultAfterDebounce() {
        var machine = IslandMachine()
        #expect(machine.configuration.hoverExpandDelay >= 0.06 && machine.configuration.hoverExpandDelay <= 0.12)
        let effects = machine.send(.pointerEntered)
        guard case let .schedule(.hoverExpand, token, _)? = effects.first else {
            Issue.record("hover zamanlayıcısı bekleniyordu"); return
        }
        #expect(machine.send(.timerFired(.hoverExpand, token: token)) == [.haptic(.expanded)])
        #expect(machine.presentation == .expanded(.nook))
    }

    @Test func passingPointerDoesNotExpand() {
        var machine = IslandMachine()
        let effects = machine.send(.pointerEntered)
        machine.send(.pointerExited)
        if case let .schedule(.hoverExpand, token, _)? = effects.first {
            machine.send(.timerFired(.hoverExpand, token: token))
        }
        #expect(machine.presentation == .idle, "Menü çubuğuna geçerken anlık temas adayı açmamalı")
    }

    @Test func noticeOverlaysRestButYieldsToHUD() {
        var machine = IslandMachine()
        let power = IslandNotice.power(PowerEvent(kind: .pluggedIn, level: 0.4, isCharging: true))
        let effects = machine.send(.noticeRequested(power))
        #expect(machine.presentation == .notice(power))
        #expect(machine.basePresentation == .idle, "Sensör bildirim genişliğine göre büyümemeli")

        let hud = HUDPayload(kind: .volume(muted: false), level: 0.3)
        machine.send(.hudRequested(hud))
        #expect(machine.presentation == .hud(hud))

        guard case let .schedule(.noticeDismiss, token, delay)? = effects.first else {
            Issue.record("bildirim zamanlayıcısı bekleniyordu"); return
        }
        #expect(delay == power.duration)
        machine.send(.timerFired(.noticeDismiss, token: token))
        #expect(machine.notice == nil)
    }

    @Test func noticePriorityIsDeterministic() {
        var machine = IslandMachine()
        let critical = IslandNotice.power(PowerEvent(kind: .critical, level: 0.09, isCharging: false))
        machine.send(.noticeRequested(critical))
        machine.send(.noticeRequested(.colorPicked(hex: "#FF0000")))
        #expect(machine.notice == critical, "Düşük öncelikli bildirim kritik pil uyarısını ezmemeli")

        var other = IslandMachine()
        other.send(.noticeRequested(.colorPicked(hex: "#FF0000")))
        let meeting = IslandNotice.meeting(title: "Standup", minutes: 5)
        other.send(.noticeRequested(meeting))
        #expect(other.notice == meeting, "Yüksek öncelikli bildirim düşük olanın yerini alır")
    }

    @Test func noticeDurationsFollowImportanceAndReadingLoad() {
        let track = IslandNotice.nowPlaying(title: "Şarkı", artist: "Sanatçı").duration
        #expect((1.8...2.2).contains(track), "Parça değişimi çevik olmalı (Dynamic Island hissi)")
        let color = IslandNotice.colorPicked(hex: "#FFAA00").duration
        let airPods = IslandNotice.audioOutput(name: "AirPods Pro", kind: .airPodsPro, connected: true).duration
        let download = IslandNotice.transferFinished(name: "rapor.pdf").duration
        let meeting = IslandNotice.meeting(title: "Standup", minutes: 5).duration
        let critical = IslandNotice.power(PowerEvent(kind: .critical, level: 0.05, isCharging: false)).duration
        #expect(color < airPods && airPods < track && track < download && download < meeting)
        #expect(critical >= meeting, "Kritik pil en az toplantı kadar görünür kalmalı")
    }

    @Test func noticeStaysWhilePointerRestsOnItAndLingersAfterExit() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        let notice = IslandNotice.nowPlaying(title: "Şarkı", artist: "Sanatçı")
        guard case let .schedule(.noticeDismiss, token, _)? = machine.send(.noticeRequested(notice)).first else {
            Issue.record("bildirim zamanlayıcısı bekleniyordu"); return
        }
        machine.send(.pointerEntered)
        machine.send(.timerFired(.noticeDismiss, token: token))
        #expect(machine.presentation == .notice(notice), "İmleç üzerindeyken süre dolması bildirimi kapatmamalı")

        let exit = machine.send(.pointerExited)
        guard case let .schedule(.noticeDismiss, linger, delay)? = exit.first else {
            Issue.record("imleç ayrılınca kısa bir kalma süresi bekleniyordu"); return
        }
        #expect(delay == NoticeTiming.lingerAfterHover)
        #expect(machine.notice == notice)
        machine.send(.timerFired(.noticeDismiss, token: linger))
        #expect(machine.notice == nil)
        #expect(machine.presentation == .idle)
    }

    @Test func noticeWithoutHoverExpiresOnTime() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        let effects = machine.send(.noticeRequested(.unlocked))
        guard case let .schedule(.noticeDismiss, token, delay)? = effects.first else { return }
        #expect(delay == NoticeTiming.unlock)
        machine.send(.pointerEntered)
        machine.send(.pointerExited)
        #expect(machine.notice == .unlocked, "Kısa bir temas bildirimin süresini değiştirmez")
        machine.send(.timerFired(.noticeDismiss, token: token))
        #expect(machine.notice == nil)
    }

    @Test func unlockNoticeTimingAndLayoutAreTailoredForFaceIDStyle() {
        let unlock = IslandNotice.unlocked.duration
        let color = IslandNotice.colorPicked(hex: "#FFFFFF").duration
        let airPods = IslandNotice.audioOutput(name: "AirPods", kind: .airPodsPro, connected: true).duration
        #expect(unlock == NoticeTiming.unlock)
        #expect(unlock >= 0.6 && unlock < airPods, "Kilit açılma: kısa sistem geri bildirimi (≥ 0,6 sn sembol geçişi için), aygıt bildiriminden kısa")
        _ = color

        let notch = NotchMetrics(notchSize: .init(width: 185, height: 33.5), style: .notch, scale: 2)
        let layout = IslandLayoutEngine.layout(for: .notice(.unlocked), metrics: notch)
        #expect(layout.topInset == 0, "Kilit açılma doğrudan ekran tavanına bağlı")
        #expect(layout.elevation == 0, "Donanım çentiği etrafında hale oluşmamalı")
        #expect(layout.size.height == notch.notchSize.height - notch.restHeightTrim, "Dikeyde büyümez; yükseklik çentikle aynı (yarım piksel kırpılmış)")
        let standardNotice = IslandLayoutEngine.layout(for: .notice(.colorPicked(hex: "#FFFFFF")), metrics: notch)
        #expect(layout.size.width > standardNotice.size.width, "Yatayda standart bildirimden daha geniş açılır")
        #expect(layout.size.height < standardNotice.size.height, "Standart bildirim gibi açıklama satırı içermez")
    }

    @Test func lockingCancelsInFlightUnlockNoticeAndItsTimer() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        let effects = machine.send(.noticeRequested(.unlocked))
        guard case let .schedule(.noticeDismiss, token, _)? = effects.first else { return }
        machine.send(.systemLocked)
        #expect(machine.notice == nil, "Animasyon sırasında tekrar kilitlenirse bildirim iptal edilir")
        #expect(machine.presentation == .idle)
        // Eski zamanlayıcı geç gelirse sonraki bildirimi kapatmamalı.
        machine.send(.noticeRequested(.unlocked))
        machine.send(.timerFired(.noticeDismiss, token: token))
        #expect(machine.notice == .unlocked, "İptal edilen bildirimin bayat zamanlayıcısı yeni bildirimi kapatmaz")
    }

    @Test func lockingCollapsesExpandedIslandButKeepsPinnedOpen() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.tapped)
        #expect(machine.isExpanded)
        machine.send(.systemLocked)
        #expect(!machine.isExpanded, "Açık ada kilitlenirken kapanır; kilit açılınca temiz durumdan başlanır")

        machine.send(.tapped)
        machine.send(.togglePin)
        machine.send(.systemLocked)
        #expect(machine.isExpanded, "Kullanıcının sabitlediği ada kilitle kapanmaz")
    }

    @Test func lockingKeepsOtherNoticesAndRestingActivity() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.mediaPlaybackChanged(isPlaying: true))
        machine.send(.noticeRequested(.power(PowerEvent(kind: .low, level: 0.15, isCharging: false))))
        machine.send(.systemLocked)
        #expect(machine.notice != nil, "Yalnızca kilit açılma bildirimi iptal edilir")
        #expect(machine.restingActivity == .media)
    }

    @Test func unlockNoticeIsAtomicAgainstLowerPriorityNotices() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.transferActiveChanged(isActive: true))
        machine.send(.noticeRequested(.unlocked))
        #expect(machine.notice == .unlocked, "Etkin aktarım kilit açılma geri bildirimini bastırmaz")
        machine.send(.noticeRequested(.airDropSent(count: 1)))
        machine.send(.noticeRequested(.colorPicked(hex: "#FFFFFF")))
        #expect(machine.notice == .unlocked, "Animasyon sırasında gelen düşük öncelikli bildirimler üstüne binmez")
        machine.send(.noticeRequested(.power(PowerEvent(kind: .critical, level: 0.05, isCharging: false))))
        #expect(machine.notice != .unlocked, "Kritik pil uyarısı yine de öne geçer")
    }

    @Test func activeTransferOutranksLowPriorityNotices() {
        var machine = IslandMachine()
        machine.send(.transferActiveChanged(isActive: true))
        machine.send(.noticeRequested(.colorPicked(hex: "#00FF00")))
        #expect(machine.presentation == .compact(.transfer), "İndirme ilerlemesi 'renk kopyalandı'nın altında kalmamalı")
        let done = IslandNotice.timerFinished(title: "Odak tamamlandı")
        machine.send(.noticeRequested(done))
        #expect(machine.presentation == .notice(done))
    }

    @Test func holdKeepsIslandOpenUntilReleased() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.pointerEntered)
        machine.send(.tapped)
        machine.send(.holdChanged(isHeld: true))
        #expect(machine.send(.pointerExited).isEmpty, "Quick Look açıkken ada kapanmamalı")
        machine.send(.tappedOutside)
        #expect(machine.isExpanded)

        let effects = machine.send(.holdChanged(isHeld: false))
        guard case let .schedule(.collapseGrace, token, _)? = effects.first else {
            Issue.record("kilit kalkınca kapanma bekleniyordu"); return
        }
        machine.send(.timerFired(.collapseGrace, token: token))
        #expect(!machine.isExpanded)
    }

    @Test func demoModeKeepsIslandOpenButEscapeStillCloses() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.pointerEntered)
        machine.send(.tapped)
        machine.send(.demoModeChanged(isOn: true))
        #expect(machine.send(.pointerExited).isEmpty, "Demo modunda imleç çıkınca kapanmamalı")
        machine.send(.tappedOutside)
        #expect(machine.isExpanded)
        machine.send(.escapePressed)
        #expect(!machine.isExpanded, "Kullanıcının kendi kapatması çalışmalı")
        #expect(machine.context.isDemoMode, "Esc demo modunu kapatmaz (pin'den farkı)")
    }

    @Test func demoModeCancelsPendingCollapseAndRestoresItWhenTurnedOff() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.pointerEntered)
        machine.send(.tapped)
        guard case let .schedule(.collapseGrace, stale, _)? = machine.send(.pointerExited).first else {
            Issue.record("kapanma zamanlayıcısı bekleniyordu"); return
        }
        machine.send(.demoModeChanged(isOn: true))
        #expect(!machine.isRelaxing)
        machine.send(.timerFired(.collapseGrace, token: stale))
        #expect(machine.isExpanded, "Demo açılınca bekleyen kapanma geçersiz")

        guard case let .schedule(.collapseGrace, token, _)? = machine.send(.demoModeChanged(isOn: false)).first else {
            Issue.record("demo kapanınca normal kapanma bekleniyordu"); return
        }
        machine.send(.timerFired(.collapseGrace, token: token))
        #expect(!machine.isExpanded)
    }

    @Test func demoModeKeepsPausedMediaUntilTurnedOff() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.demoModeChanged(isOn: true))
        machine.send(.mediaPlaybackChanged(isPlaying: true))
        guard case let .schedule(.mediaLinger, token, _)? = machine.send(.mediaPlaybackChanged(isPlaying: false)).first else {
            Issue.record("bekleme zamanlayıcısı bekleniyordu"); return
        }
        machine.send(.timerFired(.mediaLinger, token: token))
        #expect(machine.presentation == .compact(.media), "Demo modunda duraklatılan medya kaybolmaz")

        guard case let .schedule(.mediaLinger, next, delay)? = machine.send(.demoModeChanged(isOn: false)).first else {
            Issue.record("demo kapanınca bekleme yeniden kurulmalı"); return
        }
        #expect(delay == machine.configuration.pausedMediaLinger)
        machine.send(.timerFired(.mediaLinger, token: next))
        #expect(machine.presentation == .idle)
    }

    @Test func fullscreenHidesLiveActivitiesButKeepsUrgentNotices() {
        var machine = IslandMachine()
        machine.send(.mediaPlaybackChanged(isPlaying: true))
        machine.send(.fullscreenChanged(isFullscreen: true))
        #expect(machine.presentation == .idle, "Tam ekran videonun üstünde kanat olmamalı")
        machine.send(.noticeRequested(.nowPlaying(title: "Şarkı", artist: "")))
        #expect(machine.notice == nil)
        let low = IslandNotice.power(PowerEvent(kind: .low, level: 0.2, isCharging: false))
        machine.send(.noticeRequested(low))
        #expect(machine.presentation == .notice(low), "Düşük pil tam ekranda da gösterilmeli")
        machine.send(.fullscreenChanged(isFullscreen: false))
        machine.send(.pointerEntered)
        machine.send(.pointerExited)
        #expect(machine.basePresentation == .compact(.media))
    }

    @Test func transferTakesPriorityWhileActive() {
        var machine = IslandMachine()
        machine.send(.mediaPlaybackChanged(isPlaying: true))
        machine.send(.transferActiveChanged(isActive: true))
        #expect(machine.phase == .compact(.transfer))
        machine.send(.transferActiveChanged(isActive: false))
        #expect(machine.phase == .compact(.media))
    }
}

@Suite("Yerleşim motoru")
struct IslandLayoutTests {
    let notch = NotchMetrics(notchSize: .init(width: 185, height: 33.5), style: .notch)

    @Test func restLikeNotchStatesHaveNoShadowOrEdgeLight() {
        for presentation in [IslandPresentation.idle, .compact(.media), .peek(nil), .peek(.timer),
                             .hud(.init(kind: .brightness, level: 0.4)), .notice(.unlocked)] {
            let layout = IslandLayoutEngine.layout(for: presentation, metrics: notch)
            #expect(layout.elevation == 0 && layout.edgeHighlight == 0, "\(presentation) fiziksel çentik etrafında hale oluşturmamalı")
        }
    }

    @Test func idleFitsHardwareNotchWithoutElevation() {
        let layout = IslandLayoutEngine.layout(for: .idle, metrics: notch)
        #expect(layout.size.width == notch.notchSize.width)
        #expect(layout.size.height == notch.notchSize.height - notch.restHeightTrim, "Küçük ada çentikten yarım piksel kısa biter")
        #expect(layout.elevation == 0 && layout.edgeHighlight == 0, "Dinlenmede donanım kamuflajı: gölge/kontur yok")
    }

    @Test func hoverSwellIsSubtle() {
        let rest = IslandLayoutEngine.layout(for: .compact(.media), metrics: notch)
        let peek = IslandLayoutEngine.layout(for: .peek(.media), metrics: notch)
        #expect(peek.size.width - rest.size.width <= 12)
        #expect(peek.size.height - rest.size.height <= 6)
    }

    /// Kenarlar `merkez ± genişlik/2`: genişlik ekran ölçeğinde çift piksel olduğunda iki kenar da tam
    /// piksele düşer; genişleme iki yana birebir aynı piksel sayısıyla dağılır.
    @Test(arguments: [(185.0, 2.0), (184.5, 2.0), (162.25, 2.0), (200.0, 1.0), (185.0, 1.0)])
    func everyWidthIsEvenInPixelsForSymmetricGrowth(notchWidth: Double, scale: Double) {
        let metrics = NotchMetrics(notchSize: .init(width: notchWidth, height: 33.5), style: .notch, scale: scale)
        var presentations: [IslandPresentation] = [.idle, .compact(.media), .peek(nil), .peek(.timer), .dropTarget,
                                                   .hud(.init(kind: .brightness, level: 0.5)), .notice(.airDropSent(count: 1))]
        presentations += ExpandedTab.allCases.map(IslandPresentation.expanded)
        for presentation in presentations {
            let layout = IslandLayoutEngine.layout(for: presentation, metrics: metrics)
            let pixels = layout.size.width * scale
            #expect(pixels == pixels.rounded() && pixels.truncatingRemainder(dividingBy: 2) == 0, "\(presentation): \(layout.size.width)")
            let heightPixels = layout.size.height * scale
            let trimmedPixels = (layout.size.height + metrics.restHeightTrim) * scale
            #expect(abs(heightPixels - heightPixels.rounded()) < 0.0001 || abs(trimmedPixels - trimmedPixels.rounded()) < 0.0001,
                    "Alt kenar tam piksele (dinlenme yüksekliğinde kırpma payıyla) düşmeli")
        }
        let idle = IslandLayoutEngine.layout(for: .idle, metrics: metrics).size
        #expect(idle.width <= notchWidth, "Dinlenmedeki şekil donanım çentiğini taşmamalı")
        #expect(notchWidth - idle.width < 2 / scale, "…ama bir çift pikselden fazla da dar olmamalı")
    }

    /// Kullanıcının ekranından ölçülen gerçek değerler: 15" MacBook Air, 1710×1107 pt, 2×.
    @Test func restIslandMatchesMeasuredHardwareNotch() {
        let metrics = NotchMetrics(notchSize: .init(width: 1710 - 762.5 - 762.5, height: 33.5), style: .notch, scale: 2)
        let idle = IslandLayoutEngine.layout(for: .idle, metrics: metrics)
        #expect(idle.size.width == 185 && abs(idle.size.height - 33.40) < 0.0001, "safeAreaInsets.top (33,5) eksi 0,10 pt")
        #expect(idle.topInset == 0, "Üst kenar ekranın tavanına kilitli")
        // Genişleyen her görünüm aynı merkezden iki yana eşit açılır: kenar payları tam piksel.
        for presentation in [IslandPresentation.peek(nil), .compact(.media), .expanded(.media), .dropTarget] {
            let width = IslandLayoutEngine.layout(for: presentation, metrics: metrics).size.width
            let growthPerSide = (width - idle.size.width) / 2
            #expect((growthPerSide * 2).rounded() == growthPerSide * 2, "\(presentation) yan başına \(growthPerSide) pt")
            #expect(IslandLayoutEngine.layout(for: presentation, metrics: metrics).topInset == 0)
        }
    }

    /// Fiziksel çentik ile yazılımsal yüzey tek parça görünmeli: dinlenme dışındaki her notch
    /// görünümünde gövde (üst içbükey köşeler hariç genişlik) donanım çentiğinden dar olmamalı.
    /// Aksi halde çentiğin altında beliren "dudak" çentikten dar kalır ve siluette basamak oluşur.
    @Test func bodyNeverNarrowerThanHardwareNotch() {
        var presentations: [IslandPresentation] = [.peek(nil), .peek(.media), .compact(.media), .dropTarget,
                                                   .hud(.init(kind: .brightness, level: 0.5)), .notice(.unlocked)]
        presentations += ExpandedTab.allCases.map(IslandPresentation.expanded)
        for presentation in presentations {
            let layout = IslandLayoutEngine.layout(for: presentation, metrics: notch)
            let body = layout.size.width - layout.topCornerRadius * 2
            #expect(body >= notch.notchSize.width, "\(presentation): gövde \(body) < çentik \(notch.notchSize.width)")
        }
        // Hover kabarması gövdeyi her iki yana eşit ve fark edilir biçimde taşırmalı.
        let peek = IslandLayoutEngine.layout(for: .peek(nil), metrics: notch)
        let overhang = (peek.size.width - peek.topCornerRadius * 2 - notch.notchSize.width) / 2
        #expect(overhang >= 4 && overhang <= 6)
    }

    @Test func canvasHoldsEveryPresentationWithShadowAndOvershoot() {
        for metrics in [notch, NotchMetrics.pill(menuBarHeight: 24)] {
            let canvas = IslandLayoutEngine.canvasSize(for: metrics)
            #expect(canvas.width.truncatingRemainder(dividingBy: 2) == 0)
            var presentations: [IslandPresentation] = [.idle, .dropTarget, .notice(.colorPicked(hex: "#FFFFFF"))]
            presentations += ExpandedTab.allCases.map(IslandPresentation.expanded)
            for presentation in presentations {
                let layout = IslandLayoutEngine.layout(for: presentation, metrics: metrics)
                // ζ = 0,78 yayının ~%2 aşımı + gölge payı tuvale sığmalı.
                #expect(layout.size.width * 1.02 + IslandLayoutEngine.shadowBleed.horizontal * 2 <= canvas.width)
                #expect(layout.topInset + layout.size.height * 1.02 + IslandLayoutEngine.shadowBleed.bottom <= canvas.height)
            }
        }
    }

    @Test func expandedWidthFollowsContentDensity() {
        func width(_ tab: ExpandedTab, _ metrics: NotchMetrics) -> CGFloat {
            IslandLayoutEngine.layout(for: .expanded(tab), metrics: metrics).size.width
        }
        let media = width(.media, notch)
        for sparse in [ExpandedTab.shelf, .clipboard, .focus, .notes, .mirror] {
            #expect(width(sparse, notch) < media, "\(sparse) medyadan kompakt olmalı")
        }
        #expect(media < width(.nook, notch), "Nook (Dengeli) medyadan yoğun")
        for metrics in [notch, NotchMetrics.pill(menuBarHeight: 24)] {
            for tab in ExpandedTab.allCases {
                let value = width(tab, metrics)
                #expect(value >= IslandLayoutEngine.minimumExpandedWidth(for: metrics) - 1)
                #expect(value <= IslandLayoutEngine.maxExpandedWidth)
            }
        }
    }

    @Test func nookWidthGrowsWithWidgetsUntilCap() {
        func nook(_ count: Int) -> CGFloat {
            var metrics = notch
            metrics.nookWidgetCount = count
            return IslandLayoutEngine.layout(for: .expanded(.nook), metrics: metrics).size.width
        }
        #expect(nook(1) < nook(2), "Sade düzen boş kolon için genişlememeli")
        #expect(nook(2) < nook(3))
        #expect(nook(3) == IslandLayoutEngine.maxExpandedWidth, "Üretkenlik üst sınırda kalır, fazlası kayar")
        // Dengeli düzen kaydırmadan sığar: medya + takvim + anımsatıcılar.
        let content = nook(2) - 2 * IslandLayoutEngine.expandedSideInset(style: .notch)
        #expect(content >= IslandLayoutEngine.contentSize(for: .nook, metrics: notch).width - 1)
    }

    private func body(_ tab: ExpandedTab, _ content: ExpandedContent) -> CGSize {
        var metrics = notch
        metrics.content = content
        return IslandLayoutEngine.layout(for: .expanded(tab), metrics: metrics).size
    }

    /// Başarı ölçütü: görünür gövde cihazda ölçülen önceki boyutlardan gerçekten küçük (sabit bir yüzde yok,
    /// her görünüm kendi içeriğine göre). Önceki değerler Revizyon 5 tanılamasından.
    @Test func sparseBodiesAreVisiblySmallerThanBefore() {
        let typical = ExpandedContent(clipboardItems: 2, shelfItems: 0, upcomingEvents: 1, reminders: 1, launcherItems: 4)
        let before: [(ExpandedTab, CGSize)] = [
            (.notes, CGSize(width: 516, height: 193.5)), (.clipboard, CGSize(width: 508, height: 205.5)),
            (.shelf, CGSize(width: 500, height: 173.5)), (.focus, CGSize(width: 522, height: 173.5)),
        ]
        for (tab, old) in before {
            let new = body(tab, typical)
            #expect(new.width < old.width && new.height < old.height, "\(tab): \(new) önceki \(old)'den küçük olmalı")
            #expect(new.width * new.height <= 0.75 * old.width * old.height, "\(tab): alan en az %25 küçülmeli")
        }
        let notes = body(.notes, typical)
        #expect(notes.width * notes.height <= 0.7 * 516 * 193.5, "Quick Note özellikle kompakt")
        // Medya diğerlerinden geniş kalabilir; hiçbir görünüm aynı gövdeyi paylaşmaz.
        let media = body(.media, typical)
        for tab in [ExpandedTab.notes, .clipboard, .shelf, .focus] { #expect(body(tab, typical).width < media.width) }
        let sizes = [ExpandedTab.notes, .clipboard, .shelf, .focus, .media, .nook].map { body($0, typical) }
        #expect(Set(sizes.map { "\($0.width)x\($0.height)" }).count == sizes.count, "Her görünüm kendi boyutunda")
    }

    @Test func clipboardGrowsWithItemsUntilScrolling() {
        let heights = (1...6).map { body(.clipboard, ExpandedContent(clipboardItems: $0)).height }
        #expect(heights[0] < heights[1] && heights[1] < heights[2], "1 → 2 → 3 öğe: gövde kontrollü büyür")
        #expect(heights[2] == heights[5], "Üst sınırdan sonra liste kayar, gövde büyümez")
        #expect(body(.clipboard, ExpandedContent(clipboardItems: 1)).height <= 120, "Tek öğede büyük boş alan yok")
    }

    @Test func shelfGrowsWithItemsUntilScrolling() {
        let empty = body(.shelf, ExpandedContent(shelfItems: 0))
        let one = body(.shelf, ExpandedContent(shelfItems: 1))
        #expect(empty.height < one.height, "Boş raf küçük açılır")
        let widths = (1...12).map { body(.shelf, ExpandedContent(shelfItems: $0)).width }
        #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(widths.last == IslandLayoutEngine.Shelf.maximumBodyWidth, "Çok öğede gövde sınırda durur, öğeler kayar")
    }

    @Test func focusSizeDoesNotDependOnCalendarOrReminders() {
        let empty = body(.focus, ExpandedContent())
        let full = body(.focus, ExpandedContent(upcomingEvents: 20, reminders: 20))
        #expect(empty == full, "Takvim kaldırıldı: etkinlik ve anımsatıcı sayısı zamanlayıcının boyutunu değiştirmez")
        let controls = 3 * IslandLayoutEngine.Focus.durationRowHeight + 2 * IslandLayoutEngine.Focus.durationRowSpacing
        #expect(controls <= IslandLayoutEngine.Focus.ringSize, "Üç süre ayarı halka yüksekliğine sığar")
    }

    @Test func canvasIsIndependentOfContentAndHoldsLargestBodies() {
        var small = notch
        small.content = ExpandedContent()
        small.nookWidgetCount = 1
        var large = notch
        large.content = .maximum
        large.nookWidgetCount = 3
        let canvas = IslandLayoutEngine.canvasSize(for: small)
        #expect(canvas == IslandLayoutEngine.canvasSize(for: large), "İçerik değişince görsel panel yeniden boyutlanmaz")
        for tab in ExpandedTab.allCases {
            let size = IslandLayoutEngine.layout(for: .expanded(tab), metrics: large).size
            #expect(size.width <= canvas.width && size.height <= canvas.height)
        }
    }

    /// Tüm sekmeler her görünümde doğrudan tıklanabilir ("⋯" yok): çentiğin iki yanında 4'er öğe her gövdeye sığar.
    @Test func allTabsFitBesideNotchInEveryBody() {
        let slot = IslandLayoutEngine.tabButtonSize.width + IslandLayoutEngine.tabSpacing
        let perSide = CGFloat(IslandLayoutEngine.tabsPerSide) * slot - IslandLayoutEngine.tabSpacing
        let padding = IslandLayoutEngine.headerSidePadding(style: .notch)
        for tab in ExpandedTab.allCases {
            let width = IslandLayoutEngine.layout(for: .expanded(tab), metrics: notch).size.width
            let ear = (width - notch.notchSize.width) / 2 - padding
            #expect(perSide <= ear + 0.01, "\(tab): sekmeler çentiğin yanına sığmalı")
        }
        #expect(IslandLayoutEngine.leadingTabOrder.count <= IslandLayoutEngine.tabsPerSide)
        #expect(IslandLayoutEngine.trailingTabOrder.count + 1 <= IslandLayoutEngine.tabsPerSide, "sağda iğne de var")
        #expect(Set(IslandLayoutEngine.leadingTabOrder + IslandLayoutEngine.trailingTabOrder) == Set(ExpandedTab.allCases),
                "Her sekme başlıkta")
        #expect(IslandLayoutEngine.leadingTabOrder.first == .media, "Müzik en başta")
    }

    @Test func compactBodiesStayBelowOldHeaderFloor() {
        #expect(IslandLayoutEngine.minimumExpandedWidth(for: notch) == 369)
        for (tab, content) in [(ExpandedTab.notes, ExpandedContent(launcherItems: 4)),
                               (.clipboard, ExpandedContent(clipboardItems: 7)),
                               (.shelf, ExpandedContent()), (.shelf, ExpandedContent(shelfItems: 2))] {
            #expect(body(tab, content).width < 427, "\(tab) eski 427 pt'lik başlık sınırının altında")
        }
    }

    /// Revizyon 10: her görünüm hem genişlikte hem yükseklikte Revizyon 9'da cihazda ölçülen gövdeden küçük.
    @Test func everyBodyShrinksInBothDimensionsSinceRevision9() {
        var twoWidgets = notch
        twoWidgets.nookWidgetCount = 2
        let revision9: [(ExpandedTab, ExpandedContent, CGSize)] = [
            (.notes, ExpandedContent(launcherItems: 4), CGSize(width: 377, height: 152.5)),
            (.clipboard, ExpandedContent(clipboardItems: 7), CGSize(width: 390, height: 162.5)),
            (.shelf, ExpandedContent(), CGSize(width: 377, height: 153.5)),
            (.focus, ExpandedContent(upcomingEvents: 1, reminders: 1), CGSize(width: 416, height: 149.5)),
            (.media, ExpandedContent(), CGSize(width: 422, height: 149.5)),
            (.nook, ExpandedContent(), CGSize(width: 659, height: 145.5)),
        ]
        for (tab, content, old) in revision9 {
            var metrics = twoWidgets
            metrics.content = content
            let new = IslandLayoutEngine.layout(for: .expanded(tab), metrics: metrics).size
            #expect(new.width < old.width && new.height < old.height, "\(tab): \(new) önceki \(old)'den küçük olmalı")
        }
    }

    /// Revizyon 18 ("genişlemiş çentik"): açık ada fiziksel çentiğin devamıdır, ayrı bir açılır pencere değil.
    /// Üst kenar ekranın tavanında ve çentiğe kesintisiz bağlı; gölge ve cam kenar ışığı yok; köşeler kart gibi değil.
    @Test func expandedIslandIsSeamlessNotchContinuation() {
        var presentations: [IslandPresentation] = [.dropTarget]
        presentations += ExpandedTab.allCases.map(IslandPresentation.expanded)
        for presentation in presentations {
            let layout = IslandLayoutEngine.layout(for: presentation, metrics: notch)
            #expect(layout.topInset == 0, "\(presentation): üst kenar ekranın tavanında, çentiğe bitişik")
            #expect(layout.elevation == 0 && layout.edgeHighlight == 0, "\(presentation): gölge/kenar ışığı açılır pencere hissi verir")
            #expect(layout.topCornerRadius == IslandLayoutEngine.expandedTopRadius, "\(presentation): üstte içbükey kulak")
            #expect(layout.bottomCornerRadius <= layout.size.height / 4, "\(presentation): alt köşe kart gibi büyük olmamalı")
        }
        // Çentiksiz ekranda ada donanıma bağlı değildir: yüzen kapsül olarak ayrışmaya devam eder.
        let pill = IslandLayoutEngine.layout(for: .expanded(.nook), metrics: .pill(menuBarHeight: 24))
        #expect(pill.elevation > 0 && pill.edgeHighlight > 0)
    }

    /// Revizyon 18: dış boşluklar küçüldü; her açık görünüm Revizyon 17'den (cihazdaki son hali) hem dar hem kısa.
    /// İçerik alanı küçülmez: yükseklik birebir aynı, genişlik aynı veya daha geniş (başlık alt sınırına dayananlar).
    @Test func everyOpenBodyShrinksSinceRevision17WithoutShrinkingContent() {
        let revision17: [(IslandPresentation, ExpandedContent, Int, CGSize)] = [
            (.expanded(.notes), ExpandedContent(launcherItems: 4), 2, CGSize(width: 373, height: 140.5)),
            (.expanded(.clipboard), ExpandedContent(clipboardItems: 7), 2, CGSize(width: 386, height: 152.5)),
            (.expanded(.shelf), ExpandedContent(), 2, CGSize(width: 373, height: 147.5)),
            (.expanded(.shelf), ExpandedContent(shelfItems: 12), 2, CGSize(width: 560, height: 156.5)),
            (.expanded(.focus), ExpandedContent(), 2, CGSize(width: 388, height: 137.5)),
            (.expanded(.media), ExpandedContent(), 2, CGSize(width: 396, height: 137.5)),
            (.expanded(.mirror), ExpandedContent(), 2, CGSize(width: 388, height: 189.5)),
            (.expanded(.nook), ExpandedContent(), 1, CGSize(width: 466, height: 137.5)),
            (.expanded(.nook), ExpandedContent(), 2, CGSize(width: 651, height: 137.5)),
            (.expanded(.nook), ExpandedContent(), 3, CGSize(width: 680, height: 137.5)),
            (.dropTarget, ExpandedContent(), 2, CGSize(width: 460, height: 145.5)),
        ]
        let chromeHeight = notch.notchSize.height + IslandLayoutEngine.headerGap + IslandLayoutEngine.contentInset
        for (presentation, content, widgets, old) in revision17 {
            var metrics = notch
            metrics.content = content
            metrics.nookWidgetCount = widgets
            let layout = IslandLayoutEngine.layout(for: presentation, metrics: metrics)
            let new = layout.size
            #expect(new.width < old.width && new.height < old.height, "\(presentation): \(new) önceki \(old)'den küçük olmalı")
            // Revizyon 17 çerçevesi: yanlarda 12 + 12, altta 12, başlık altında 4 pt (bırakma hedefinde kulak 10).
            let oldSide: CGFloat = presentation == .dropTarget ? 22 : 24
            let oldContent = CGSize(width: old.width - oldSide * 2, height: old.height - notch.notchSize.height - 16)
            let side = IslandLayoutEngine.contentSideInset(for: layout, style: .notch)
            let newContent = CGSize(width: new.width - side * 2, height: new.height - chromeHeight)
            #expect(newContent.height == oldContent.height, "\(presentation): içerik yüksekliği aynı kalmalı")
            #expect(newContent.width >= oldContent.width, "\(presentation): içerik alanı daralmamalı")
        }
    }

    @Test func tabsMorphToDifferentHeights() {
        let heights = Set(ExpandedTab.allCases.map { IslandLayoutEngine.layout(for: .expanded($0), metrics: notch).size.height })
        #expect(heights.count > 1)
    }

    @Test(arguments: [IslandPresentation.compact(.media), .peek(.media), .expanded(.media), .expanded(.nook)])
    func artworkIsConcentricAndInsideBody(_ presentation: IslandPresentation) throws {
        let layout = IslandLayoutEngine.layout(for: presentation, metrics: notch)
        let slot = try #require(IslandLayoutEngine.artworkSlot(for: presentation, metrics: notch))
        let body = CGRect(x: layout.topCornerRadius, y: 0,
                          width: layout.size.width - layout.topCornerRadius * 2, height: layout.size.height)
        #expect(body.contains(slot.rect))
        let bottomInset = layout.size.height - slot.rect.maxY
        let leftInset = slot.rect.minX - layout.topCornerRadius
        #expect(abs(bottomInset - leftInset) < 0.5, "Kapak alt-sol köşeye eşit uzaklıkta olmalı")
        #expect(abs(slot.cornerRadius - (layout.bottomCornerRadius - bottomInset)) < 0.5)
    }

    @Test func waveformStaysInsideTrailingWing() throws {
        let layout = IslandLayoutEngine.layout(for: .compact(.media), metrics: notch)
        let wave = try #require(IslandLayoutEngine.waveformSlot(for: .compact(.media), metrics: notch))
        let notchMaxX = (layout.size.width + notch.notchSize.width) / 2
        #expect(wave.minX >= notchMaxX, "Dalga donanım çentiğinin arkasında kalmamalı")
        #expect(wave.maxX <= layout.size.width - layout.topCornerRadius)
    }

    @Test func pillFloatsBelowMenuBarWithSymmetricRadii() {
        let pill = NotchMetrics.pill(menuBarHeight: 24)
        let layout = IslandLayoutEngine.layout(for: .compact(.media), metrics: pill)
        #expect(layout.topCornerRadius == layout.bottomCornerRadius)
        #expect(layout.topInset > 24, "Harici monitörde ada menü çubuğunun hemen altında yüzmeli")
        #expect(layout.edgeHighlight > 0, "Donanımsız kapsül ince kenar ışığıyla ayrışmalı")
    }
}

@Suite("Pil olay kuralları")
struct PowerRuleTests {
    private func battery(_ level: Double, ac: Bool = false, charging: Bool = false, charged: Bool = false) -> PowerSnapshot {
        PowerSnapshot(level: level, isOnAC: ac, isCharging: charging, isCharged: charged)
    }

    @Test func adapterPlugAndUnplug() {
        #expect(PowerEvent.Kind.transition(from: battery(0.5), to: battery(0.5, ac: true, charging: true)) == .pluggedIn)
        #expect(PowerEvent.Kind.transition(from: battery(0.5, ac: true), to: battery(0.5)) == .unplugged)
    }

    @Test func thresholdsFireOnceWhenCrossedDownward() {
        #expect(PowerEvent.Kind.transition(from: battery(0.21), to: battery(0.20)) == .low)
        #expect(PowerEvent.Kind.transition(from: battery(0.20), to: battery(0.19)) == nil, "Eşiğin altında kalmak tekrar bildirmez")
        #expect(PowerEvent.Kind.transition(from: battery(0.11), to: battery(0.10)) == .critical)
        #expect(PowerEvent.Kind.transition(from: battery(0.10, ac: true), to: battery(0.11, ac: true)) == nil)
    }

    @Test func fullChargeOnlyOnAC() {
        #expect(PowerEvent.Kind.transition(from: battery(0.99, ac: true), to: battery(1, ac: true, charged: true)) == .full)
        #expect(PowerEvent.Kind.transition(from: battery(1, ac: true, charged: true), to: battery(1, ac: true, charged: true)) == nil)
    }
}

@Suite("Tam ekran algılama")
struct FullscreenDetectorTests {
    let display = CGRect(x: 0, y: 0, width: 1710, height: 1107)
    let menuBar = WindowSnapshot(ownerPID: 1, layer: FullscreenDetector.menuBarLayer, bounds: CGRect(x: 0, y: 0, width: 1710, height: 34))

    @Test func fullscreenVideoIsDetected() {
        let video = WindowSnapshot(ownerPID: 42, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1710, height: 1107))
        #expect(FullscreenDetector.isFullscreen(display: display, safeTopInset: 33.5, windows: [video], ownPID: 7))
    }

    @Test func fullscreenBelowCameraHousingIsDetected() {
        // Çentikli Mac'te tam ekran içerik varsayılan olarak çentiğin altından başlar.
        let app = WindowSnapshot(ownerPID: 42, layer: 0, bounds: CGRect(x: 0, y: 33.5, width: 1710, height: 1073.5))
        #expect(FullscreenDetector.isFullscreen(display: display, safeTopInset: 33.5, windows: [app], ownPID: 7))
    }

    @Test func zoomedWindowWithVisibleMenuBarIsNotFullscreen() {
        let zoomed = WindowSnapshot(ownerPID: 42, layer: 0, bounds: CGRect(x: 0, y: 34, width: 1710, height: 1073))
        #expect(!FullscreenDetector.isFullscreen(display: display, safeTopInset: 33.5, windows: [menuBar, zoomed], ownPID: 7))
    }

    @Test func returningWindowMustClearNotchBandEvenIfMenuBarAlreadyReturned() {
        let menuBar = WindowSnapshot(ownerPID: 1, layer: FullscreenDetector.menuBarLayer,
                                     bounds: CGRect(x: 0, y: 0, width: 1710, height: 34))
        let returning = WindowSnapshot(ownerPID: 42, layer: 0,
                                       bounds: CGRect(x: 0, y: 20, width: 1710, height: 1053))
        #expect(FullscreenDetector.isFullscreen(display: display, safeTopInset: 33.5,
                                                windows: [menuBar, returning], ownPID: 7),
                "Pencere üst kenarı fiziksel çentik bandından çıkmadan ada içeriği açılmamalı")

        let settled = WindowSnapshot(ownerPID: 42, layer: 0,
                                     bounds: CGRect(x: 0, y: 34, width: 1710, height: 1039))
        #expect(!FullscreenDetector.isFullscreen(display: display, safeTopInset: 33.5,
                                                 windows: [menuBar, settled], ownPID: 7))

        let backgroundTransition = WindowSnapshot(ownerPID: 43, layer: 0,
                                                  bounds: CGRect(x: 0, y: 20, width: 1710, height: 1053))
        #expect(!FullscreenDetector.isFullscreen(display: display, safeTopInset: 33.5,
                                                 windows: [menuBar, settled, backgroundTransition], ownPID: 7),
                "Öndeki normal pencere güvenli alanı temizlediyse arkadaki pencere geçişi uzatmamalı")
    }

    @Test func ownWindowsAndOtherDisplaysAreIgnored() {
        let own = WindowSnapshot(ownerPID: 7, layer: 0, bounds: display)
        let otherDisplay = WindowSnapshot(ownerPID: 42, layer: 0, bounds: CGRect(x: 1710, y: 0, width: 1920, height: 1080))
        #expect(!FullscreenDetector.isFullscreen(display: display, safeTopInset: 33.5, windows: [own, otherDisplay], ownPID: 7))
    }
}

@Suite("Tam ekrandan çıkış sabitleme")
struct FullscreenExitConfirmationTests {
    @Test func pendingConfirmationTracksIndependentDisplaysAndReset() {
        var confirmation = FullscreenExitConfirmation()
        #expect(!confirmation.needsConfirmation)
        var state = confirmation.apply(current: [1: true, 2: true], detected: [1: false, 2: true])
        #expect(confirmation.needsConfirmation)
        state = confirmation.apply(current: state, detected: [1: true, 2: false])
        #expect(confirmation.needsConfirmation, "İkinci ekrandaki bekleyen çıkış doğrulanmalı")
        state = confirmation.apply(current: state, detected: [1: true, 2: false])
        #expect(!confirmation.needsConfirmation)
        #expect(state[1] == true && state[2] == false)
        _ = confirmation.apply(current: state, detected: [1: false, 2: false])
        confirmation.reset()
        #expect(!confirmation.needsConfirmation)
    }

    @Test func enteringIsImmediateButExitingNeedsTwoStableReads() {
        var confirmation = FullscreenExitConfirmation()
        var state = confirmation.apply(current: [:], detected: [1: true])
        #expect(state[1] == true, "Tam ekrana giriş bekletilmemeli")

        state = confirmation.apply(current: state, detected: [1: false])
        #expect(state[1] == true, "İlk geçici pencere listesi adayı erkenden açmamalı")
        state = confirmation.apply(current: state, detected: [1: false])
        #expect(state[1] == false, "İki kararlı ölçümden sonra ada geri gelebilir")
    }

    @Test func transientFalseSnapshotDoesNotEndFullscreen() {
        var confirmation = FullscreenExitConfirmation()
        var state = confirmation.apply(current: [:], detected: [1: true])
        state = confirmation.apply(current: state, detected: [1: false])
        state = confirmation.apply(current: state, detected: [1: true])
        #expect(state[1] == true, "Tam ekran penceresi geri geldiyse bekleyen çıkış iptal edilir")
        state = confirmation.apply(current: state, detected: [1: false])
        state = confirmation.apply(current: state, detected: [1: false])
        #expect(state[1] == false)
    }
}

extension FullscreenExitConfirmationTests {
    @Test func exitWaitsForSettleDelayAfterLastFullscreenSnapshot() {
        var confirmation = FullscreenExitConfirmation(settleDelay: 1.0)
        var state = confirmation.apply(current: [:], detected: [1: true], now: 10.0)
        state = confirmation.apply(current: state, detected: [1: false], now: 10.35)
        state = confirmation.apply(current: state, detected: [1: false], now: 10.7)
        #expect(state[1] == true, "Animasyon bitmeden (1 sn dolmadan) içerik geri dönmemeli")
        #expect(confirmation.needsConfirmation, "Yeniden ölçüm döngüsü sürmeli")
        state = confirmation.apply(current: state, detected: [1: false], now: 11.05)
        #expect(state[1] == false, "Son tam ekran ölçümünden 1 sn sonra ada geri gelir")
        #expect(!confirmation.needsConfirmation)
    }

    @Test func settleDelayRestartsWhenFullscreenWindowReturns() {
        var confirmation = FullscreenExitConfirmation(settleDelay: 1.0)
        var state = confirmation.apply(current: [:], detected: [1: true], now: 0)
        state = confirmation.apply(current: state, detected: [1: false], now: 0.5)
        state = confirmation.apply(current: state, detected: [1: true], now: 0.9) // çentik bandı hâlâ dolu
        state = confirmation.apply(current: state, detected: [1: false], now: 1.2)
        state = confirmation.apply(current: state, detected: [1: false], now: 1.6)
        #expect(state[1] == true, "Süre, son tam ekran ölçümünden (0,9) itibaren sayılır")
        state = confirmation.apply(current: state, detected: [1: false], now: 1.95)
        #expect(state[1] == false)
    }
}

@Suite("Sistem seviye kontrolü (private API güvenliği)")
struct LevelControlTests {
    final class FakeBackend {
        var value: Float? = 0.5
        var writes: [Float] = []
        var writeSucceeds = true
        var backend: LevelControlBackend {
            LevelControlBackend(read: { self.value }, write: { value in
                self.writes.append(value)
                if self.writeSucceeds { self.value = value }
                return self.writeSucceeds
            })
        }
    }

    @Test func missingFrameworkOrSymbolPassesKeyToSystem() {
        let control = ManagedLevelControl(backend: nil)
        #expect(!control.canHandle)
        #expect(control.adjust(by: 1 / 16) == nil)
        #expect(control.health == .unavailable)
    }

    @Test func successfulAdjustIsQuantizedAndClamped() {
        let fake = FakeBackend()
        let control = ManagedLevelControl(backend: fake.backend)
        #expect(control.adjust(by: 1 / 16) == 0.5625)
        fake.value = 0.99
        #expect(control.adjust(by: 1 / 16) == 1)
        #expect(control.health == .healthy)
    }

    @Test(arguments: [Float.nan, 1.7, -0.4])
    func unexpectedValuesAreNotTrusted(value: Float) {
        let fake = FakeBackend()
        fake.value = value
        let control = ManagedLevelControl(backend: fake.backend)
        #expect(control.adjust(by: 0.1) == nil, "Beklenmeyen değerle yazım yapılmamalı")
        #expect(fake.writes.isEmpty)
    }

    @Test func repeatedFailuresDisableControlUntilReset() {
        let fake = FakeBackend()
        fake.writeSucceeds = false
        let control = ManagedLevelControl(backend: fake.backend)
        for _ in 0..<ManagedLevelControl.failureLimit {
            #expect(control.adjust(by: 0.1) == nil)
        }
        #expect(!control.canHandle, "Art arda başarısızlıktan sonra tuş artık tüketilmemeli")
        let writesBefore = fake.writes.count
        #expect(control.adjust(by: 0.1) == nil)
        #expect(fake.writes.count == writesBefore, "Devre dışıyken aynı başarısız çağrı tekrarlanmamalı")
        fake.writeSucceeds = true
        control.reset()
        #expect(control.adjust(by: 1 / 16) != nil)
    }
}

@Suite("Arka uç sağlığı ve geri çekilme")
struct BackendHealthTests {
    let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func backoffGrowsExponentiallyAndIsBounded() {
        var health = BackendHealth(baseDelay: 30, maxDelay: 600)
        health.recordFailure(at: start)
        #expect(!health.allows(at: start.addingTimeInterval(29)))
        #expect(health.allows(at: start.addingTimeInterval(30)))
        health.recordFailure(at: start)
        #expect(!health.allows(at: start.addingTimeInterval(59)))
        for _ in 0..<10 { health.recordFailure(at: start) }
        #expect(health.allows(at: start.addingTimeInterval(600)), "Geri çekilme üst sınırı aşmamalı")
    }

    @Test func successRestoresAndPermanentFailureDisables() {
        var health = BackendHealth()
        health.recordFailure(at: start)
        health.recordSuccess()
        #expect(health.allows(at: start) && health.consecutiveFailures == 0)
        health.recordFailure(permanent: true, at: start)
        #expect(!health.allows(at: .distantFuture))
        health.reset()
        #expect(health.state == .unsupported, "Kalıcı destek yokluğu uyanmayla düzelmez")
    }

    @Test func permissionDenialUsesMinimumDelay() {
        var health = BackendHealth(baseDelay: 30)
        health.recordFailure(minimumDelay: 600, at: start)
        #expect(!health.allows(at: start.addingTimeInterval(599)))
        health.reset()
        #expect(health.allows(at: start))
    }
}

@Suite("Kompakt tahmini müzik nabzı")
struct CompactPulseTests {
    /// 10 dakikalık hareketi 30 Hz'de örnekler.
    private func samples() -> [[Double]] {
        stride(from: 0.0, to: 600, by: 1.0 / 30).map { time in
            CompactPulse.bars.indices.map { CompactPulse.level(bar: $0, at: time) }
        }
    }

    @Test func fiveBarsWithIndependentTiming() {
        let bars = CompactPulse.bars
        #expect(bars.count == 5)
        let cycles = Set(bars.map { ($0.cycleDuration * 1000).rounded() })
        #expect(cycles.count == bars.count, "Aynı döngü süresine sahip iki çubuk birlikte kilitlenir")
        for bar in bars {
            #expect((0.65...1.1).contains(bar.averagePeriod), "Bir iniş-çıkış ne çok yavaş ne çok hızlı")
            #expect(bar.levels.allSatisfy { (0...1).contains($0) })
        }
    }

    @Test func neverAllBarsAtPeakAndMostlyMidHeight() {
        let all = samples()
        #expect(!all.contains { frame in frame.allSatisfy { $0 >= 0.8 } }, "Beşi birden asla tepede olmamalı")
        let occasionalPeak = Double(all.filter { frame in frame.contains { $0 >= 0.8 } }.count) / Double(all.count)
        #expect((0.05...0.5).contains(occasionalPeak), "Zaman zaman bir-iki çubuk belirgin uzamalı")
        let mean = all.flatMap { $0 }.reduce(0, +) / Double(all.count * 5)
        #expect((0.4...0.65).contains(mean), "Çoğunlukla orta yükseklik")
    }

    @Test func barsMoveIndependentlyNotAsOneEqualizer() {
        let all = samples()
        let spread = all.filter { frame in (frame.max()! - frame.min()!) >= 0.12 }.count
        #expect(Double(spread) / Double(all.count) > 0.95, "Çubuklar aynı yüksekliğe toplanmamalı")
        // Komşu çubukların aynı yöne gitme oranı: senkron olsalardı ~1 olurdu.
        for index in 0..<4 {
            var same = 0, total = 0
            for frame in 1..<all.count {
                let a = all[frame][index] - all[frame - 1][index]
                let b = all[frame][index + 1] - all[frame - 1][index + 1]
                guard abs(a) > 1e-4, abs(b) > 1e-4 else { continue }
                total += 1
                if (a > 0) == (b > 0) { same += 1 }
            }
            #expect(Double(same) / Double(max(total, 1)) < 0.7, "Çubuk \(index) ve \(index + 1) birlikte hareket etmemeli")
        }
    }

    @Test func discreteSamplingKeepsTheMotionAtALowFixedRate() {
        for index in CompactPulse.bars.indices {
            let cycle = CompactPulse.bars[index].cycleDuration
            let samples = CompactPulse.sampledLevels(bar: index)
            let rate = Double(samples.count) / cycle
            #expect(abs(rate - CompactPulse.sampleRate) / CompactPulse.sampleRate < 0.03, "Gerçek hız istenen örnek hızına yakın")
            #expect(samples.allSatisfy { (0...1).contains($0) })
            #expect(abs(samples[0] - CompactPulse.level(bar: index, at: 0)) < 1e-12)
            // Örnekler arası fark küçük kalır (adım adım hareket yumuşak görünür) ve döngü sonu ilk örneğe bağlanır.
            let wrapped = samples + [samples[0]]
            let largestStep = zip(wrapped, wrapped.dropFirst()).map { abs($0 - $1) }.max() ?? 0
            #expect(largestStep < 0.12, "Çubuk \(index): en büyük örnek adımı \(largestStep)")
        }
        #expect(CompactPulse.sampleRate <= 30, "120 Hz'e bağlı sürekli enterpolasyona geri dönülmemeli")
    }

    @Test func loopIsSeamlessAndTransitionsAreCalm() {
        for index in CompactPulse.bars.indices {
            let cycle = CompactPulse.bars[index].cycleDuration
            #expect(abs(CompactPulse.level(bar: index, at: 0) - CompactPulse.level(bar: index, at: cycle - 1e-9)) < 1e-6)
        }
        #expect((0.15...0.25).contains(CompactPulse.settleDuration))
        let resting = CompactPulse.restingLevels
        #expect(resting.count == 5 && resting.allSatisfy { $0 <= 0.35 }, "Duraklatınca sakin, kısa form")
        #expect(resting[0] > resting[1] && resting[1] < resting[2] && resting[2] > resting[3] && resting[3] < resting[4], "▃ ▂ ▃ ▂ ▃")
    }
}

@Suite("Ses aygıtı bildirimi")
struct AudioOutputRulesTests {
    let speakers = AudioDeviceInfo(id: 1, name: "MacBook Air Hoparlörleri", kind: .builtIn, isBluetooth: false)
    let airPods = AudioDeviceInfo(id: 7, name: "AirPods Pro", kind: .airPodsPro, isBluetooth: true)
    let tv = AudioDeviceInfo(id: 9, name: "LG TV", kind: .display, isBluetooth: false)
    let airPlay = AudioDeviceInfo(id: 11, name: "Mutfak", kind: .airPlay, isBluetooth: false)

    @Test func airPodsConnectingIsAnnouncedOnceEvenIfOutputSwitchesLater() {
        // Bağlanma: aygıt listeye eklenir (çıkış henüz değişmemiş olabilir).
        let first = AudioOutputRules.notice(previous: [speakers], current: [speakers, airPods],
                                            previousDefault: 1, currentDefault: 1, recentlyAnnounced: [])
        #expect(first?.device == airPods && first?.connected == true)
        // Hemen ardından macOS çıkışı AirPods'a geçirir: ikinci kez duyurulmaz.
        let second = AudioOutputRules.notice(previous: [speakers, airPods], current: [speakers, airPods],
                                             previousDefault: 1, currentDefault: 7, recentlyAnnounced: [7])
        #expect(second == nil)
    }

    @Test func airPodsConnectingWithImmediateOutputSwitchIsAnnounced() {
        let notice = AudioOutputRules.notice(previous: [speakers], current: [speakers, airPods],
                                             previousDefault: 1, currentDefault: 7, recentlyAnnounced: [])
        #expect(notice?.device == airPods && notice?.connected == true)
    }

    @Test func disconnectingIsAnnouncedAndFallbackToSpeakersIsNot() {
        let notice = AudioOutputRules.notice(previous: [speakers, airPods], current: [speakers],
                                             previousDefault: 7, currentDefault: 1, recentlyAnnounced: [7])
        #expect(notice?.device == airPods && notice?.connected == false)
        #expect(AudioOutputRules.notice(previous: [speakers, tv], current: [speakers, tv],
                                        previousDefault: 9, currentDefault: 1, recentlyAnnounced: []) == nil)
    }

    @Test func switchingToExternalOutputIsAnnouncedButDiscoveredAirPlayIsNot() {
        let hdmi = AudioOutputRules.notice(previous: [speakers, tv], current: [speakers, tv],
                                           previousDefault: 1, currentDefault: 9, recentlyAnnounced: [])
        #expect(hdmi?.device == tv && hdmi?.connected == true)
        #expect(AudioOutputRules.notice(previous: [speakers], current: [speakers, airPlay],
                                        previousDefault: 1, currentDefault: 1, recentlyAnnounced: []) == nil,
                "Ağda beliren AirPlay hoparlörü seçilmedikçe duyurulmaz")
    }

    @Test func losingTheActiveExternalOutputIsAnnouncedButIdleAirPlayVanishingIsNot() {
        let unplugged = AudioOutputRules.notice(previous: [speakers, tv], current: [speakers],
                                                previousDefault: 9, currentDefault: 1, recentlyAnnounced: [])
        #expect(unplugged?.device == tv && unplugged?.connected == false)
        #expect(AudioOutputRules.notice(previous: [speakers, airPlay], current: [speakers],
                                        previousDefault: 1, currentDefault: 1, recentlyAnnounced: []) == nil)
    }

    @Test func bluetoothSpeakerAndAirPodsGetDistinctIcons() {
        #expect(AudioOutputRules.bluetoothKind(named: "AirPods Pro") == .headphones)
        #expect(AudioOutputRules.bluetoothKind(named: "JBL Charge 5") == .headphones)
        #expect(AudioOutputRules.bluetoothKind(named: "Bose SoundLink Flex") == .headphones)
        #expect(AudioOutputRules.bluetoothKind(named: "Sony WH-1000XM5") == .headphones)
    }
}

@Suite("Sürükle-bırak dosya türünü koruma")
struct ShelfImportRulesTests {
    @Test func rawImageBytesKeepTheirAdvertisedType() {
        let tiff = Data([0x49, 0x49, 0x2A, 0x00, 0x01])
        let imported = ShelfImportRules.imageRepresentation(from: [UTType.tiff.identifier: tiff])
        #expect(imported == .init(data: tiff, fileExtension: "tiff"))
    }

    @Test func specificRepresentationTypeWinsOverTemporaryName() {
        #expect(ShelfImportRules.preferredFileExtension(typeIdentifier: UTType.png.identifier,
                                                        suggestedFilename: "foto.heic",
                                                        temporaryFileExtension: "dat") == "heic")
        #expect(ShelfImportRules.preferredFileExtension(typeIdentifier: UTType.jpeg.identifier,
                                                        suggestedFilename: nil,
                                                        temporaryFileExtension: "dat") == "dat")
    }

    @Test func genericDataPreservesSuggestedOrTemporaryExtension() {
        #expect(ShelfImportRules.preferredFileExtension(typeIdentifier: UTType.data.identifier,
                                                        suggestedFilename: "rapor.PDF",
                                                        temporaryFileExtension: "dat") == "PDF")
        #expect(ShelfImportRules.preferredFileExtension(typeIdentifier: UTType.data.identifier,
                                                        suggestedFilename: nil,
                                                        temporaryFileExtension: "zip") == "zip")
    }
}

@Suite("Ses değişimi HUD kuralı")
struct VolumeChangeRulesTests {
    func visible(_ from: Double?, _ to: Double, mutedBefore: Bool = false, mutedAfter: Bool = false) -> Bool {
        VolumeChangeRules.isUserVisible(from: from.map { VolumeReading(level: $0, muted: mutedBefore) },
                                        to: VolumeReading(level: to, muted: mutedAfter))
    }

    @Test func volumeKeyStepsAreShown() {
        #expect(visible(0.5, 0.5625), "dahili hoparlör: 1/16")
        #expect(visible(33.0 / 127, 41.0 / 127), "AirPods: 8/127")
        #expect(visible(0.5625, 0.5), "kısma da gösterilir")
        #expect(visible(0.98, 1.0), "en üste varış")
    }

    /// Cihazda ölçülen AirPods Pro otomatik ayar dizisi: hiçbiri HUD açmaz, birikince de açmaz.
    @Test func automaticPersonalizedVolumeDriftIsIgnored() {
        let measured = [0.5, 0.48, 0.46, 0.47, 0.49, 0.47, 0.46, 0.45, 0.46, 0.48, 0.49, 0.51, 0.53, 0.55, 0.57]
        for (from, to) in zip(measured, measured.dropFirst()) {
            #expect(!visible(from, to), "\(from) → \(to) otomatik ayar")
        }
    }

    @Test func muteChangesAreShownButDriftWhileMutedIsNot() {
        #expect(visible(0.5, 0.5, mutedAfter: true))
        #expect(visible(0.5, 0.5, mutedBefore: true))
        #expect(visible(0.02, 0), "sıfıra inmek sessize almaktır")
        #expect(!visible(0.3, 0.4, mutedBefore: true, mutedAfter: true))
    }

    @Test func firstReadingAfterAttachIsNotAnAction() {
        #expect(!visible(nil, 0.8))
    }
}

@Suite("Space sunumu")
struct SpacePresentationPolicyTests {
    typealias Policy = SpacePresentationPolicy

    @Test func behaviorFollowsMembershipAndVisibility() {
        #expect(Policy.behavior(isOnScreen: true, managedSpaces: []) == .pinned)
        #expect(Policy.behavior(isOnScreen: true, managedSpaces: nil) == .unverified, "üyelik okunamazsa 'sabit' denmez")
        // Cihazda ölçülen public durum: masaüstü (1) ve tam ekran (109) Space'lerinin üyesi → 1774 pt kaydı.
        #expect(Policy.behavior(isOnScreen: true, managedSpaces: [1, 109]) == .slides)
        #expect(Policy.behavior(isOnScreen: false, managedSpaces: []) == .hidden)
        #expect(Policy.behavior(isOnScreen: false, managedSpaces: [1]) == .hidden, "görünmezlik her zaman önce gelir")
    }

    @Test func privateProviderMustPinPublicAndFallbackMustStayVisible() {
        #expect(Policy.accepts(.pinned, from: .privateSpace))
        #expect(Policy.accepts(.unverified, from: .privateSpace))
        #expect(!Policy.accepts(.slides, from: .privateSpace), "kayan private yalıtım işe yaramıyor → sonraki sağlayıcı")
        #expect(!Policy.accepts(.hidden, from: .privateSpace))
        for provider in [SpaceProviderKind.publicStationary, .safeFallback] {
            #expect(Policy.accepts(.slides, from: provider), "public kayar ama görünür: kabul")
            #expect(!Policy.accepts(.hidden, from: provider), "kaybolmak asla kabul edilmez")
        }
    }

    @Test func measuredOrderKeepsPrivatePrimaryAndAlwaysEndsWithSafeFallback() {
        #expect(Policy.measuredOrder == [.privateSpace, .publicStationary, .safeFallback])
        #expect(Policy.order(preferred: nil) == Policy.measuredOrder)
        #expect(Policy.order(preferred: .publicStationary) == [.publicStationary, .privateSpace, .safeFallback], "A/B: public önde")
        for preferred in SpaceProviderKind.allCases {
            let order = Policy.order(preferred: preferred)
            #expect(order.first == preferred && Set(order) == Set(SpaceProviderKind.allCases) && order.count == 3)
        }
    }

    @Test func chainFallsThroughToSafeFallbackThenStops() {
        let order = Policy.measuredOrder
        #expect(Policy.next(after: .privateSpace, in: order) == .publicStationary)
        #expect(Policy.next(after: .publicStationary, in: order) == .safeFallback)
        #expect(Policy.next(after: .safeFallback, in: order) == nil)
    }

    @Test func worstWindowDecidesOverallStatus() {
        #expect(Policy.combine([(.privateSpace, .pinned), (.privateSpace, .pinned)]) == .settled(provider: .privateSpace, behavior: .pinned))
        #expect(Policy.combine([(.privateSpace, .pinned), (.publicStationary, .slides)]) == .settled(provider: .publicStationary, behavior: .slides),
                "ör. harici monitördeki ada yedekte")
        #expect(Policy.combine([(.privateSpace, .pinned), (.safeFallback, .hidden)]) == .settled(provider: .safeFallback, behavior: .hidden))
        #expect(Policy.combine([(.privateSpace, .pinned), (.privateSpace, nil)]) == .pending)
        #expect(Policy.combine([]) == .pending)
    }
}

@Suite("Ekran seçimi")
struct DisplaySelectionTests {
    let macBook = DisplayCandidate(id: 1, isBuiltIn: true, hasNotch: true)
    let external = DisplayCandidate(id: 2, isBuiltIn: false, hasNotch: false)

    @Test func islandNeverAppearsOnExternalMonitorByDefault() {
        #expect(DisplaySelection.targets(.primary, among: [macBook, external]) == [1])
        #expect(DisplaySelection.targets(.primary, among: [external, macBook]) == [1], "harici monitör ana ekran olsa da")
    }

    @Test func lidClosedWithOnlyExternalMonitorShowsNoIsland() {
        #expect(DisplaySelection.targets(.primary, among: [external]).isEmpty)
    }

    @Test func builtInWithoutNotchStillGetsTheIsland() {
        let olderMacBook = DisplayCandidate(id: 3, isBuiltIn: true, hasNotch: false)
        #expect(DisplaySelection.targets(.primary, among: [external, olderMacBook]) == [3])
    }

    @Test func allDisplaysIsAnExplicitOptIn() {
        #expect(DisplaySelection.targets(.allDisplays, among: [macBook, external]) == [1, 2])
    }
}

@Suite("İmleç isabet testi")
struct PointerHitTestTests {
    /// Cihazda ölçülen durum: 1107 pt yüksekliğinde ekranda adanın isabet bölgesi ekranın tepesine kadar uzanır.
    let hit = CGRect(x: 750.5, y: 1069.5, width: 209, height: 37.5)

    @Test func topEdgeOfScreenIsInsideTheHitRect() {
        let topRow = CGPoint(x: 855, y: 1107)
        #expect(!hit.contains(topRow), "CGRect.contains üst kenarı dışarıda sayar: hata buradaydı")
        #expect(hit.containsInclusive(topRow), "imleç ekranın en üst satırındayken isabet sürmeli")
    }

    @Test func allFourEdgesAreInclusiveAndOutsideIsStillOutside() {
        #expect(hit.containsInclusive(CGPoint(x: hit.minX, y: hit.minY)))
        #expect(hit.containsInclusive(CGPoint(x: hit.maxX, y: hit.maxY)))
        #expect(!hit.containsInclusive(CGPoint(x: hit.maxX + 0.5, y: 1100)))
        #expect(!hit.containsInclusive(CGPoint(x: hit.minX - 0.5, y: 1100)))
        #expect(!hit.containsInclusive(CGPoint(x: 855, y: hit.minY - 0.5)))
        #expect(!hit.containsInclusive(CGPoint(x: 855, y: hit.maxY + 0.5)))
    }
}

@Suite("Raf işlemleri")
struct ShelfOperationRulesTests {
    typealias Rules = ShelfOperationRules
    let photo = ShelfFileInfo(name: "Tatil.HEIC", isImage: true)
    let screenshot = ShelfFileInfo(name: "Ekran Resmi.png", isImage: true)
    let archive = ShelfFileInfo(name: "Proje.zip")
    let folder = ShelfFileInfo(name: "Belgeler", isDirectory: true)
    let pdf = ShelfFileInfo(name: "Fatura.pdf")

    @Test func operationsMatchTheSelection() {
        #expect(Rules.available(for: []).isEmpty)
        #expect(Rules.available(for: [pdf]) == [.zip, .copyPath])
        #expect(Rules.available(for: [archive]) == [.zip, .unzip, .copyPath])
        #expect(Rules.available(for: [photo, screenshot]) == [.zip, .compressImage, .copyPath])
        #expect(Rules.available(for: [photo, pdf]) == [.zip, .copyPath], "karışık seçimde yalnızca ortak işlemler")
        #expect(!Rules.available(for: [ShelfFileInfo(name: "Klasör.zip", isDirectory: true)]).contains(.unzip),
                "adı .zip ile biten klasör arşiv değildir")
    }

    @Test func namesFollowFinderConventions() {
        #expect(Rules.archiveName(for: [pdf]) == "Fatura.zip")
        #expect(Rules.archiveName(for: [folder]) == "Belgeler.zip")
        #expect(Rules.archiveName(for: [pdf, photo]) == "Arşiv.zip")
        #expect(Rules.extractedFolderName(for: "Proje.zip") == "Proje")
        #expect(Rules.compressedImageName(for: "Tatil.HEIC", hasAlpha: false) == "Tatil (sıkıştırılmış).jpg")
        #expect(Rules.compressedImageName(for: "Ekran Resmi.png", hasAlpha: true) == "Ekran Resmi (sıkıştırılmış).png")
        #expect(Rules.compressedImageName(for: ".gizli", hasAlpha: false) == ".gizli (sıkıştırılmış).jpg")
    }

    @Test func uniqueNamesNeverOverwrite() {
        #expect(Rules.uniqueName("Arşiv.zip", existing: []) == "Arşiv.zip")
        #expect(Rules.uniqueName("Arşiv.zip", existing: ["Arşiv.zip"]) == "Arşiv 2.zip")
        #expect(Rules.uniqueName("Arşiv.zip", existing: ["Arşiv.zip", "Arşiv 2.zip"]) == "Arşiv 3.zip")
        #expect(Rules.uniqueName("Proje", existing: ["Proje"]) == "Proje 2", "uzantısız klasör adı")
    }

    @Test func imagesShrinkWithoutUpscalingOrDistortion() {
        let big = Rules.targetPixelSize(width: 6048, height: 4024)
        #expect(big.width == 2560 && big.height == 1703)
        let portrait = Rules.targetPixelSize(width: 3024, height: 4032)
        #expect(portrait.height == 2560 && portrait.width == 1920)
        let small = Rules.targetPixelSize(width: 1200, height: 800)
        #expect(small.width == 1200 && small.height == 800, "küçük görsel büyütülmez")
    }

    @Test func onlyRasterImagesAreCompressible() {
        #expect(Rules.isCompressibleImage(name: "IMG_1234.HEIC"))
        #expect(Rules.isCompressibleImage(name: "Ekran Resmi.png"))
        #expect(!Rules.isCompressibleImage(name: "animasyon.gif"), "animasyon kaybolurdu")
        #expect(!Rules.isCompressibleImage(name: "logo.svg"), "vektör")
        #expect(!Rules.isCompressibleImage(name: "rapor.pdf"))
    }

    @Test func largerResultIsDiscarded() {
        #expect(Rules.keepsCompressedResult(originalBytes: 5_000_000, resultBytes: 900_000))
        #expect(!Rules.keepsCompressedResult(originalBytes: 80_000, resultBytes: 120_000), "zaten küçük görsel")
        #expect(!Rules.keepsCompressedResult(originalBytes: 80_000, resultBytes: 0))
    }
}
