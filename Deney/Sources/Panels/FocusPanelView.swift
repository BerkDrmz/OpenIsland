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
        for phase in FocusTimer.Phase.allCases {
            let row = DurationRowView(phase: phase, timer: timer)
            rows.append(row)
            durations.addSubview(row)
        }
        // Sayaç ve faz etiketi halkanın üstünde kardeş görünümlerdir (halka görünümü çevrik değil; yerleşim panelin
        // çevrik koordinatlarında yapılır). AX sırası SwiftUI ZStack ile aynı: halka içeriği önce.
        [ring, countdown, phaseLabel, playPause, reset, skip, sessions, separator, durations].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() { observer.start() }
    func didHide() { observer.stop(); ticker.stop() }

    /// SwiftUI AX sırası geometriktir: dikeyde örtüşen öğeler aynı satır sayılır, satır içinde soldan sağa. Halka
    /// içeriği (ZStack) önce gelir; denetim sütunu ile süre satırları satır satır iç içe geçer.
    override func accessibilityChildren() -> [Any]? {
        let durationsOrder = rows.map(\.accessibilityElements)
        var result: [Any] = [countdown, phaseLabel, playPause]
        result += durationsOrder[0]
        result += [reset, skip]
        result += durationsOrder[1]
        result.append(sessions)
        result += durationsOrder[2]
        // Denetimlerin gerçek AX öğesi hücreleridir (NSTextField/NSStepper): görmezden gelinmeyen torun alınır.
        return result.filter { ($0 as? NSView)?.isHidden != true }.compactMap { NSAccessibility.unignoredDescendant(of: $0) }
    }

    private func update() {
        ring.configure(timing: timer.progressTiming, tint: NSColor(timer.phase.tint), track: .white.withAlphaComponent(0.18))
        phaseLabel.set(timer.phase.title)
        playPause.setSymbol(timer.isRunning ? "pause.fill" : "play.fill", label: timer.isRunning ? "Duraklat" : "Başlat")
        sessions.set("\(timer.completedFocusSessions) oturum")
        let anchor: Date = if case .running(let end) = timer.runState { end } else { .now }
        ticker.set(running: timer.isRunning, anchor: anchor)
        updateCountdown()
        let running = timer.isRunning
        // SwiftUI `.help` sütundaki her öğeye hem araç ipucu hem AX yardımı olarak uygulanır.
        let help = running ? "Süreyi değiştirmek için zamanlayıcıyı duraklat." : "Odak ve mola süreleri: 1–180 dakika."
        durations.toolTip = help
        rows.forEach { $0.update(enabled: !running, help: help) }
        needsLayout = true
    }

    private func updateCountdown() {
        let remaining = timer.remaining(at: .now).rounded(.up)
        let text = remaining.clockString
        // Karakter sayısı değişince (ör. 1:00:00 → 59:59) küçülme ve satır yüksekliği değişebilir.
        if text.count != countdown.stringValue.count { needsLayout = true }
        countdown.set(text)
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
        let ringFrame = CGRect(x: x0, y: (bounds.height - ring) / 2, width: ring, height: ring)
        self.ring.frame = ringFrame
        let ch = countdown.fittedLineHeight(forWidth: ring - 16), ph = phaseLabel.lineHeight
        let ty = ringFrame.minY + (ring - ch - ph) / 2
        countdown.frame = CGRect(x: ringFrame.minX + 8, y: ty, width: ring - 16, height: ch)
        phaseLabel.frame = CGRect(x: ringFrame.minX, y: ty + ch, width: ring, height: ph)
        let cx = x0 + ring + Spacing.m
        let colHeight = big + Spacing.s + small + Spacing.s + sessions.lineHeight
        var y = (bounds.height - colHeight) / 2
        playPause.setLayoutFrame(CGRect(x: cx + (controlsWidth - big) / 2, y: y, width: big, height: big))
        y += big + Spacing.s
        let pairX = cx + (controlsWidth - 2 * small - Spacing.xxs) / 2
        reset.setLayoutFrame(CGRect(x: pairX, y: y, width: small, height: small))
        skip.setLayoutFrame(CGRect(x: pairX + small + Spacing.xxs, y: y, width: small, height: small))
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
    private let field = BoxedDurationField()
    private let unit = TextLabel("dk", font: Fonts.caption2, color: Palette.secondary)
    private let stepper = AlignedStepper()

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
        // SwiftUI `Stepper(başlık)` + `.accessibilityLabel`: AX etiketi ikisinin birleşimidir.
        stepper.setAccessibilityLabel("\(phase.title), \(phase.title) süresini ayarla")
        fieldBackground.addSubview(field)
        [title, fieldBackground, unit, stepper].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    private var minutes: Int { Int(timer.minutes(for: phase)) }

    var accessibilityElements: [NSView] { [title, field, unit, stepper] }

    func update(enabled: Bool, help: String) {
        for element in [title, field, unit, stepper] as [NSView] { element.setAccessibilityHelp(help) }
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
        // SwiftUI HStack(spacing: 4) ölçüleri (çalışma anında ölçülmüştür): metin genişlikleri piksele yukarı
        // yuvarlanır, adımlayıcı hizalama dikdörtgeniyle (mini: 9 × 13) yerleşir; görünüm çerçevesi bunun dışına taşar.
        let h = bounds.height
        let size = stepper.intrinsicContentSize, insets = stepper.alignmentRectInsets
        let align = CGRect(x: bounds.width - size.width, y: (h - size.height) / 2, width: size.width, height: size.height)
        stepper.frame = CGRect(x: align.minX - insets.left, y: align.minY - insets.top,
                               width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
        let uw = pixelCeil(unit.exactWidth)
        let ux = align.minX - 4 - uw
        unit.frame = CGRect(x: ux, y: (h - unit.lineHeight) / 2, width: uw, height: unit.lineHeight)
        let bw: CGFloat = 28 + 8, bh: CGFloat = 14 + 6
        let bx = ux - 4 - bw
        fieldBackground.frame = CGRect(x: bx, y: (h - bh) / 2, width: bw, height: bh)
        field.frame = CGRect(x: 4, y: 3, width: 28, height: 14)
        title.frame = CGRect(x: 0, y: (h - title.lineHeight) / 2, width: min(pixelCeil(title.exactWidth), max(bx - 10, 0)),
                             height: title.lineHeight)
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

    /// Son kurulan içeriğin girdisi: panel her gösterildiğinde aynı veriyle yeniden kurulmaz.
    private var builtState: (hasAccess: Bool, items: [ReminderItem], error: String?, day: Date)?

    private func rebuild() {
        let state = (hasAccess: reminders.hasAccess, items: Array(reminders.items.prefix(limit)), error: reminders.lastError,
                     day: Calendar.current.startOfDay(for: Date()))
        if let last = builtState, last.hasAccess == state.hasAccess, last.items == state.items, last.error == state.error,
           last.day == state.day { return }
        builtState = state
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

    var preferredHeight: CGFloat { max(circle.layoutSize.height, title.lineHeight) }

    override func layout() {
        super.layout()
        let h = bounds.height
        let s = circle.layoutSize
        circle.place(asLabelOf: complete, layoutOrigin: CGPoint(x: 0, y: (h - s.height) / 2))
        var x = s.width + 6
        let ow = overdue?.naturalWidth ?? 0
        let tw = min(title.naturalWidth, bounds.width - x - (overdue == nil ? 0 : ow + 6))
        open.frame = CGRect(x: x, y: (h - title.lineHeight) / 2, width: max(tw, 0), height: title.lineHeight)
        title.frame = open.bounds
        x += tw + 6
        if let overdue { overdue.frame = CGRect(x: x, y: (h - overdue.lineHeight) / 2, width: ow, height: overdue.lineHeight) }
    }
}

/// `DurationTextField` (SwiftUI sürümünün `NSViewRepresentable` alanı) ile aynı davranış; tek fark AX çerçevesi:
/// SwiftUI etiketi dolgulu kutuya uyguladığı için öğe kutunun çerçevesini (36 × 20) bildirir.
@MainActor
private final class BoxedDurationField: NSTextField {
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isEnabled { window?.makeKey() }
        super.mouseDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        window?.makeKey()
        selectText(nil)
        return true
    }

    override func accessibilityFrame() -> NSRect {
        guard let box = superview, let window else { return super.accessibilityFrame() }
        return window.convertToScreen(box.convert(box.bounds, to: nil))
    }
}

/// SwiftUI'nin barındırdığı `NSStepper` gibi AX çerçevesi hizalama dikdörtgenidir (mini: 9 × 13).
private final class AlignedStepper: NSStepper {
    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        let i = alignmentRectInsets
        let rect = CGRect(x: i.left, y: isFlipped ? i.top : i.bottom,
                          width: bounds.width - i.left - i.right, height: bounds.height - i.top - i.bottom)
        return window.convertToScreen(convert(rect, to: nil))
    }
}
