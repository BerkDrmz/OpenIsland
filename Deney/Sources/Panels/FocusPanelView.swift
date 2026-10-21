import AppKit
import IslandCore

/// Odak zamanlayıcısı ve kalıcı odak/mola süreleri (SwiftUI `FocusPanel`).
@MainActor
final class FocusPanelView: FlippedView, IslandPanel {
    private let timer: FocusTimer
    private let ring = TimeProgressLayerView(style: .ring(lineWidth: 5))
    private let countdown = TextLabel("", font: Fonts.numericLarge, alignment: .center)
    private let phaseLabel = TextLabel("", font: Fonts.caption2, color: Palette.secondary, alignment: .center)
    private let playPause: IconButtonView
    private let reset: IconButtonView
    private let skip: IconButtonView
    private let sessions = TextLabel("", font: Fonts.numericSmall, color: Palette.tertiary, alignment: .center)
    private let separator = SeparatorView()
    private var rows: [DurationRowView] = []
    private let durations = FlippedView()
    private lazy var ticker = SecondTicker { [weak self] in self?.updateCountdown() }
    private lazy var observer = Observer(track: { [timer] in
        _ = timer.runState; _ = timer.phase; _ = timer.completedFocusSessions
        for phase in FocusTimer.Phase.allCases { _ = timer.minutes(for: phase) }
    }, apply: { [weak self] in self?.update() })

    init(timer: FocusTimer) {
        self.timer = timer
        playPause = IconButtonView(symbol: "play.fill", label: "Başlat", size: 15, isProminent: true) {
            // Başlatmadan önce dakika alanında henüz uygulanmamış yazımı tamamla.
            NSApp.keyWindow?.makeFirstResponder(nil)
            timer.toggle()
        }
        reset = IconButtonView(symbol: "arrow.counterclockwise", label: "Sıfırla", size: 10) { timer.reset() }
        skip = IconButtonView(symbol: "forward.end.fill", label: "Sonraki faza geç", size: 10) { timer.skip() }
        super.init(frame: .zero)
        sessions.minimumScaleFactor = 0.8
        countdown.minimumScaleFactor = 0.65
        ring.addSubview(countdown)
        ring.addSubview(phaseLabel)
        for phase in FocusTimer.Phase.allCases {
            let row = DurationRowView(phase: phase, timer: timer)
            rows.append(row)
            durations.addSubview(row)
        }
        [ring, playPause, reset, skip, sessions, separator, durations].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() { observer.start() }
    func didHide() { observer.stop(); ticker.stop() }

    private func update() {
        ring.configure(timing: timer.progressTiming, tint: NSColor(timer.phase.tint), track: .white.withAlphaComponent(0.18))
        phaseLabel.set(timer.phase.title)
        playPause.setSymbol(timer.isRunning ? "pause.fill" : "play.fill", label: timer.isRunning ? "Duraklat" : "Başlat")
        sessions.set("\(timer.completedFocusSessions) oturum")
        let anchor: Date = if case .running(let end) = timer.runState { end } else { .now }
        ticker.set(running: timer.isRunning, anchor: anchor)
        updateCountdown()
        let running = timer.isRunning
        durations.toolTip = running ? "Süreyi değiştirmek için zamanlayıcıyı duraklat." : "Odak ve mola süreleri: 1–180 dakika."
        rows.forEach { $0.update(enabled: !running) }
        needsLayout = true
    }

    private func updateCountdown() {
        let remaining = timer.remaining(at: .now).rounded(.up)
        countdown.set(remaining.clockString)
        countdown.textColor = NSColor(timer.phase.tint)
        countdown.setAccessibilityLabel("\(timer.phase.title), kalan \(remaining.clockString)")
    }

    override func layout() {
        super.layout()
        let f = IslandLayoutEngine.Focus.self
        let ring = f.ringSize
        let gap = IslandLayoutEngine.columnGap
        // Zamanlayıcı sütunu: halka + denetimler (aralarında 12 pt), sütun genişliğinde ortalı.
        let big = IconButtonView.diameter(for: 15), small = IconButtonView.diameter(for: 10)
        let controlsWidth = max(big, 2 * small + Spacing.xxs, sessions.naturalWidth)
        let groupWidth = ring + Spacing.m + controlsWidth
        let x0 = (f.timerWidth - groupWidth) / 2
        self.ring.frame = CGRect(x: x0, y: (bounds.height - ring) / 2, width: ring, height: ring)
        let ch = countdown.lineHeight, ph = phaseLabel.lineHeight
        let ty = (ring - ch - ph) / 2
        countdown.frame = CGRect(x: 8, y: ty, width: ring - 16, height: ch)
        phaseLabel.frame = CGRect(x: 0, y: ty + ch, width: ring, height: ph)
        let cx = x0 + ring + Spacing.m
        let colHeight = big + Spacing.s + small + Spacing.s + sessions.lineHeight
        var y = (bounds.height - colHeight) / 2
        playPause.frame = pixelRect(CGRect(x: cx + (controlsWidth - big) / 2, y: y, width: big, height: big))
        y += big + Spacing.s
        let pairX = cx + (controlsWidth - 2 * small - Spacing.xxs) / 2
        reset.frame = pixelRect(CGRect(x: pairX, y: y, width: small, height: small))
        skip.frame = pixelRect(CGRect(x: pairX + small + Spacing.xxs, y: y, width: small, height: small))
        y += small + Spacing.s
        sessions.frame = CGRect(x: cx, y: y, width: controlsWidth, height: sessions.lineHeight)
        separator.frame = pixelRect(CGRect(x: f.timerWidth + gap, y: 0, width: 0.5, height: bounds.height))
        let dx = f.timerWidth + gap + 0.5 + gap
        let total = CGFloat(rows.count) * f.durationRowHeight + CGFloat(rows.count - 1) * f.durationRowSpacing
        durations.frame = CGRect(x: dx, y: (bounds.height - total) / 2, width: f.durationWidth, height: total)
        for (i, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(i) * (f.durationRowHeight + f.durationRowSpacing), width: f.durationWidth, height: f.durationRowHeight)
        }
    }
}

/// Süre satırı: başlık, dakika alanı (28 × 14, dolgu kutusunda), "dk" ve mini adımlayıcı.
@MainActor
private final class DurationRowView: FlippedView, NSTextFieldDelegate {
    private let phase: FocusTimer.Phase
    private let timer: FocusTimer
    private let title: TextLabel
    private let fieldBackground = RoundedView(radius: 5, fill: Palette.fillHover)
    private let field = DurationTextField()
    private let unit = TextLabel("dk", font: Fonts.caption2, color: Palette.secondary)
    private let stepper = NSStepper()

    init(phase: FocusTimer.Phase, timer: FocusTimer) {
        self.phase = phase
        self.timer = timer
        title = TextLabel(phase.title, font: Fonts.caption)
        super.init(frame: .zero)
        fieldBackground.layer?.cornerCurve = .circular
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        field.textColor = .white
        field.alignment = .right
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        field.delegate = self
        field.setAccessibilityLabel("\(phase.title) süresi, dakika")
        stepper.controlSize = .mini
        stepper.minValue = 1
        stepper.maxValue = 180
        stepper.increment = 1
        stepper.target = self
        stepper.action = #selector(stepped(_:))
        stepper.setAccessibilityLabel("\(phase.title) süresini ayarla")
        fieldBackground.addSubview(field)
        [title, fieldBackground, unit, stepper].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    private var minutes: Int { Int(timer.minutes(for: phase)) }

    func update(enabled: Bool) {
        field.isEnabled = enabled
        stepper.isEnabled = enabled
        if !enabled, field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        if field.currentEditor() == nil { field.stringValue = String(minutes) }
        stepper.integerValue = minutes
        alphaValue = 1
        title.textColor = enabled ? Palette.primary : Palette.primary.withAlphaComponent(0.5)
    }

    @objc private func stepped(_ sender: NSStepper) {
        timer.setMinutes(Double(sender.integerValue), for: phase)
    }

    func controlTextDidChange(_ notification: Notification) {
        let digits = String(field.stringValue.filter { $0 >= "0" && $0 <= "9" }.prefix(3))
        if digits != field.stringValue {
            field.stringValue = digits
            field.currentEditor()?.string = digits
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) { commit() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commit()
            field.window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            field.stringValue = String(minutes)
            textView.string = field.stringValue
            field.window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private func commit() {
        if field.isEnabled, let value = Int(field.stringValue) {
            timer.setMinutes(Double(min(max(value, 1), 180)), for: phase)
        }
        field.stringValue = String(minutes)
        field.currentEditor()?.string = field.stringValue
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let ss = stepper.fittingSize
        stepper.frame = CGRect(x: bounds.width - ss.width, y: (h - ss.height) / 2, width: ss.width, height: ss.height)
        let uw = unit.naturalWidth
        let ux = stepper.frame.minX - 4 - uw
        unit.frame = CGRect(x: ux, y: (h - unit.lineHeight) / 2, width: uw, height: unit.lineHeight)
        let bw: CGFloat = 28 + 8, bh: CGFloat = 14 + 6
        let bx = ux - 4 - bw
        fieldBackground.frame = CGRect(x: bx, y: (h - bh) / 2, width: bw, height: bh)
        field.frame = CGRect(x: 4, y: 3, width: 28, height: 14)
        title.frame = CGRect(x: 0, y: (h - title.lineHeight) / 2, width: max(bx - 2, 0), height: title.lineHeight)
    }
}

/// Apple Anımsatıcılar listesi (SwiftUI `RemindersList`): bugün ve gecikmiş olanlar, tek tıkla tamamla, satır içi ekle.
@MainActor
final class RemindersListView: FlippedView, NSTextFieldDelegate {
    private let reminders: RemindersService
    private let limit: Int
    private let draft = NSTextField()
    private var content: [NSView] = []
    private lazy var observer = Observer(track: { [reminders] in
        _ = reminders.items; _ = reminders.hasAccess; _ = reminders.lastError
    }, apply: { [weak self] in self?.rebuild() })

    init(reminders: RemindersService, limit: Int) {
        self.reminders = reminders
        self.limit = limit
        super.init(frame: .zero)
        draft.isBordered = false
        draft.isBezeled = false
        draft.drawsBackground = false
        draft.focusRingType = .none
        draft.font = Fonts.caption
        draft.textColor = Palette.primary
        draft.placeholderAttributedString = NSAttributedString(string: "Yeni anımsatıcı",
            attributes: [.font: Fonts.caption, .foregroundColor: Palette.tertiary])
        draft.delegate = self
        draft.target = self
        draft.action = #selector(submit)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() { reminders.beginViewing(); observer.start() }
    func didHide() { observer.stop(); reminders.endViewing() }

    @objc private func submit() {
        let text = draft.stringValue
        reminders.add(title: text)
        draft.stringValue = ""
    }

    private func rebuild() {
        content.forEach { $0.removeFromSuperview() }
        content.removeAll()
        if !reminders.hasAccess {
            content.append(TextLabel("Bugünkü anımsatıcılarınızı görmek için erişim verin.", font: Fonts.caption, color: Palette.secondary))
            let button = PlainButton { [reminders] in reminders.requestAccess() }
            let label = TextLabel("Erişim ver", font: Fonts.caption2)
            label.setAccessibilityElement(false)
            button.addSubview(label)
            button.setAccessibilityLabel("Erişim ver")
            content.append(button)
        } else {
            if reminders.items.isEmpty {
                let button = PlainButton { [reminders] in reminders.openApp() }
                let label = TextLabel("Bugün için anımsatıcı yok", font: Fonts.caption, color: Palette.tertiary)
                label.setAccessibilityElement(false)
                button.addSubview(label)
                button.toolTip = "Anımsatıcılar'da aç"
                button.setAccessibilityLabel(label.stringValue)
                button.setAccessibilityHelp("Anımsatıcılar'da aç")
                content.append(button)
            }
            for item in reminders.items.prefix(limit) { content.append(ReminderRowView(item: item, reminders: reminders)) }
            content.append(draft)
            if let error = reminders.lastError {
                content.append(TextLabel(error, font: Fonts.caption2, color: .systemOrange))
            }
        }
        content.forEach(addSubview)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for view in content {
            let h: CGFloat
            switch view {
            case let t as TextLabel: h = t.lineHeight; t.frame = CGRect(x: 0, y: y, width: min(t.naturalWidth, bounds.width), height: h)
            case let b as PlainButton:
                let label = b.subviews.first as? TextLabel
                h = label?.lineHeight ?? 14
                b.frame = CGRect(x: 0, y: y, width: min(label?.naturalWidth ?? 0, bounds.width), height: h)
                label?.frame = b.bounds
            case let r as ReminderRowView: h = r.preferredHeight; r.frame = CGRect(x: 0, y: y, width: bounds.width, height: h)
            default: h = TextMetrics.lineHeight(for: Fonts.caption); view.frame = CGRect(x: 0, y: y, width: bounds.width, height: h)
            }
            y += h + Spacing.xs
        }
    }
}

@MainActor
private final class ReminderRowView: FlippedView {
    private let complete: PlainButton
    private let circle: SymbolView
    private let open: PlainButton
    private let title: TextLabel
    private let overdue: TextLabel?

    init(item: ReminderItem, reminders: RemindersService) {
        complete = PlainButton { reminders.complete(item) }
        circle = SymbolView("circle", size: 12, color: item.listColor ?? Palette.secondary)
        open = PlainButton { reminders.open(item) }
        title = TextLabel(item.title, font: Fonts.caption)
        let differentiate = NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
        overdue = item.isOverdue ? TextLabel(differentiate ? "Gecikti ⚠︎" : "Gecikti", font: Fonts.caption2, color: .systemOrange) : nil
        super.init(frame: .zero)
        complete.addSubview(circle)
        complete.setAccessibilityLabel("\(item.title) tamamlandı olarak işaretle")
        title.setAccessibilityElement(false)
        open.addSubview(title)
        open.toolTip = "Anımsatıcılar'da aç"
        open.setAccessibilityLabel(item.title)
        open.setAccessibilityHelp("Anımsatıcılar uygulamasında açar")
        [complete, open, overdue].compactMap { $0 }.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    var preferredHeight: CGFloat { max(circle.intrinsicContentSize.height, title.lineHeight) }

    override func layout() {
        super.layout()
        let h = bounds.height
        let s = circle.intrinsicContentSize
        complete.frame = pixelRect(CGRect(x: 0, y: (h - s.height) / 2, width: s.width, height: s.height))
        circle.frame = complete.bounds
        var x = s.width + 6
        let ow = overdue?.naturalWidth ?? 0
        let tw = min(title.naturalWidth, bounds.width - x - (overdue == nil ? 0 : ow + 6))
        open.frame = CGRect(x: x, y: (h - title.lineHeight) / 2, width: max(tw, 0), height: title.lineHeight)
        title.frame = open.bounds
        x += tw + 6
        if let overdue { overdue.frame = CGRect(x: x, y: (h - overdue.lineHeight) / 2, width: ow, height: overdue.lineHeight) }
    }
}
