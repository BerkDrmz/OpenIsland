import AppKit
import IslandCore

/// NotchNook'un ana görünümü (SwiftUI `NookPanel`): medya parçacığı solda sabit; takvim, anımsatıcılar ve kısayollar
/// sağda yatay kayar. Alt görünüm sırası SwiftUI ağaç sırasıdır (AX sırası buradan gelir).
@MainActor
final class NookPanelView: FlippedView, IslandPanel {
    private let environment: AppEnvironment
    private let model: IslandViewModel
    private let media: NookMediaWidgetView
    private let divider = SeparatorView()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let calendar: NookCalendarView
    private let remindersDivider = SeparatorView()
    private let reminders: NookRemindersView
    private let shortcutsDivider = SeparatorView()
    private let shortcuts: NookShortcutsView
    private lazy var observer = Observer(track: { [environment] in
        _ = environment.preferences.nookLayout
    }, apply: { [weak self] in self?.needsLayout = true })

    init(environment: AppEnvironment, model: IslandViewModel) {
        self.environment = environment
        self.model = model
        media = NookMediaWidgetView(media: environment.media, model: model)
        calendar = NookCalendarView(calendar: environment.calendar)
        reminders = NookRemindersView(reminders: environment.reminders)
        shortcuts = NookShortcutsView(launcher: environment.launcher, openTools: { environment.maintenance.open() })
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        [calendar, remindersDivider, reminders, shortcutsDivider, shortcuts].forEach(document.addSubview)
        [media, divider, scroll].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() {
        func timed(_ name: String, _ body: () -> Void) {
            let t0 = CACurrentMediaTime(); body()
            if FrameDriver.isLogging { FrameDriver.note(String(format: "nook.didShow %@ %.2f ms", name, (CACurrentMediaTime() - t0) * 1000)) }
        }
        timed("observer") { observer.start() }
        timed("media") { media.didShow() }
        timed("calendar") { calendar.didShow() }
        timed("shortcuts") { shortcuts.didShow() }
        if environment.preferences.nookLayout.showsReminders { timed("reminders") { reminders.didShow() } }
    }

    func didHide() {
        observer.stop()
        media.didHide(); calendar.didHide(); reminders.didHide(); shortcuts.didHide()
    }

    func prewarm() { calendar.prewarm(); shortcuts.prewarm() }

    override func layout() {
        super.layout()
        let layout = environment.preferences.nookLayout
        let m = Spacing.m
        let mediaWidth = media.preferredWidth
        media.frame = CGRect(x: 0, y: 0, width: mediaWidth, height: bounds.height)
        divider.frame = pixelRect(CGRect(x: mediaWidth + m, y: 0, width: 0.5, height: bounds.height))
        let sx = mediaWidth + m + 0.5 + m
        scroll.frame = CGRect(x: sx, y: 0, width: bounds.width - sx, height: bounds.height)
        let widths = IslandLayoutEngine.nookWidgetWidths
        var x: CGFloat = 0
        calendar.frame = CGRect(x: x, y: 0, width: widths[0], height: bounds.height)
        x += widths[0]
        remindersDivider.isHidden = !layout.showsReminders
        reminders.isHidden = !layout.showsReminders
        if layout.showsReminders {
            remindersDivider.frame = pixelRect(CGRect(x: x + m, y: 0, width: 0.5, height: bounds.height))
            x += m + 0.5 + m
            reminders.frame = CGRect(x: x, y: 0, width: widths[1], height: bounds.height)
            x += widths[1]
            if window != nil, !reminders.isViewing { reminders.didShow() }
        } else if reminders.isViewing {
            reminders.didHide()
        }
        shortcutsDivider.isHidden = !layout.showsShortcuts
        shortcuts.isHidden = !layout.showsShortcuts
        if layout.showsShortcuts {
            shortcutsDivider.frame = pixelRect(CGRect(x: x + m, y: 0, width: 0.5, height: bounds.height))
            x += m + 0.5 + m
            shortcuts.frame = CGRect(x: x, y: 0, width: widths[2], height: bounds.height)
            x += widths[2]
        }
        document.frame = CGRect(x: 0, y: 0, width: max(x, scroll.contentSize.width), height: bounds.height)
    }
}

// MARK: - Medya

@MainActor
private final class NookMediaWidgetView: FlippedView {
    private let media: MediaController
    private let model: IslandViewModel
    private let placeholder = RoundedView(radius: 12, fill: Palette.fill)
    private let placeholderIcon = SymbolView("music.note", size: 13, color: Palette.tertiary)
    private let artworkButton = PlainButton()
    private let textButton = PlainButton()
    private let title = TextLabel("", font: Fonts.bodyEmphasized)
    private let artist = TextLabel("", font: Fonts.caption, color: Palette.secondary)
    private let previous: IconButtonView
    private let playPause: IconButtonView
    private let next: IconButtonView
    private lazy var observer = Observer(track: { [media] in
        _ = media.nowPlaying; _ = media.isPlaying; _ = media.sourceApplication
    }, apply: { [weak self] in self?.update() })

    init(media: MediaController, model: IslandViewModel) {
        self.media = media
        self.model = model
        previous = IconButtonView(symbol: "backward.fill", label: "Önceki parça", size: 11) { media.previousTrack() }
        playPause = IconButtonView(symbol: "play.fill", label: "Oynat", size: 14, isProminent: true) { media.togglePlayPause() }
        next = IconButtonView(symbol: "forward.fill", label: "Sonraki parça", size: 11) { media.nextTrack() }
        super.init(frame: .zero)
        placeholderIcon.exposeAsImage(frameOf: placeholder) // SwiftUI: kaplama görseli kutunun çerçevesini bildirir
        placeholder.addSubview(placeholderIcon)
        artworkButton.action = { media.revealSourceApplication() }
        textButton.action = { media.revealSourceApplication() }
        textButton.addSubview(title)
        textButton.addSubview(artist)
        [title, artist].forEach { $0.setAccessibilityElement(false) }
        [placeholder, artworkButton, textButton, previous, playPause, next].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() { observer.start() }
    func didHide() { observer.stop() }

    private var artworkSize: CGSize {
        IslandLayoutEngine.artworkSlot(for: .expanded(.nook), metrics: model.metrics)?.rect.size ?? .zero
    }

    var preferredWidth: CGFloat { artworkSize.width + Spacing.m + IslandLayoutEngine.nookMediaTextWidth }

    private func update() {
        let info = media.nowPlaying
        placeholder.isHidden = info != nil
        artworkButton.isHidden = info == nil
        title.set(info?.title ?? "Çalan yok")
        artist.set(info?.artist ?? "")
        textButton.setAccessibilityLabel(title.stringValue)
        let app = media.sourceApplication
        for button in [artworkButton, textButton] {
            button.isEnabled = app != nil
            button.toolTip = app?.localizedName.map { "\($0) uygulamasında aç" }
            button.setAccessibilityHelp(app?.localizedName.map { "\($0) uygulamasını öne getirir" })
        }
        playPause.setSymbol(media.isPlaying ? "pause.fill" : "play.fill", label: media.isPlaying ? "Duraklat" : "Oynat")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = artworkSize
        placeholder.frame = CGRect(origin: .zero, size: size)
        placeholderIcon.frame = placeholderIcon.drawingFrame(centeredIn: CGRect(origin: .zero, size: size))
        artworkButton.frame = CGRect(origin: .zero, size: size)
        let x = size.width + Spacing.m
        let w = IslandLayoutEngine.nookMediaTextWidth
        let blockH = title.lineHeight + Spacing.xxs + artist.lineHeight
        // Metin düğmesi SwiftUI'deki gibi içeriği kadar geniştir (tıklama alanı ve AX çerçevesi aynı).
        let textW = min(w, pixelCeil(max(title.exactWidth, artist.exactWidth)))
        textButton.frame = CGRect(x: x, y: 0, width: textW, height: blockH)
        title.frame = CGRect(x: 0, y: 0, width: textW, height: title.lineHeight)
        artist.frame = CGRect(x: 0, y: title.lineHeight + Spacing.xxs, width: textW, height: artist.lineHeight)
        let big = IconButtonView.diameter(for: 14), small = IconButtonView.diameter(for: 11)
        let y = size.height - big
        var cx = x
        previous.setLayoutFrame(CGRect(x: cx, y: y + (big - small) / 2, width: small, height: small))
        cx += small + Spacing.m
        playPause.setLayoutFrame(CGRect(x: cx, y: y, width: big, height: big))
        cx += big + Spacing.m
        next.setLayoutFrame(CGRect(x: cx, y: y + (big - small) / 2, width: small, height: small))
    }
}

// MARK: - Takvim

@MainActor
private final class NookCalendarView: FlippedView {
    private let calendar: CalendarService
    private let monthButton: PlainButton
    private let month = TextLabel("", font: NSFont.systemFont(ofSize: 22, weight: .bold))
    private var days: [DayCellView] = []
    private let events = FlippedView()
    private lazy var observer = Observer(track: { [calendar] in
        _ = calendar.today; _ = calendar.dayOffset; _ = calendar.dayEvents; _ = calendar.hasAccess
    }, apply: { [weak self] in self?.update() })

    init(calendar: CalendarService) {
        self.calendar = calendar
        monthButton = PlainButton { calendar.openInCalendarApp() }
        super.init(frame: .zero)
        month.minimumScaleFactor = 0.7
        month.setAccessibilityElement(false)
        monthButton.addSubview(month)
        monthButton.toolTip = "Takvim'de aç"
        monthButton.setAccessibilityHelp("Takvim'de aç")
        addSubview(monthButton)
        for offset in -2...2 {
            let cell = DayCellView(offset: offset) { calendar.showDay(offset: offset) }
            days.append(cell)
            addSubview(cell)
        }
        addSubview(events)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() { observer.start() }
    func prewarm() { update() }
    func didHide() { observer.stop() }

    private func update() {
        let today = calendar.today
        let selected = Calendar.current.date(byAdding: .day, value: calendar.dayOffset, to: today) ?? today
        month.set(selected.formatted(.dateTime.month(.abbreviated)))
        monthButton.setAccessibilityLabel(month.stringValue)
        for cell in days { cell.update(today: today, selectedOffset: calendar.dayOffset) }
        rebuildEvents()
        needsLayout = true
    }

    /// Son kurulan etkinlik satırlarının girdisi: panel her gösterildiğinde aynı veriyle yeniden kurulmaz (yeni
    /// görünümler ve sembol rasterleştirme her sekme geçişinde tekrar ediyordu).
    private var eventsState: (hasAccess: Bool, events: [UpcomingEvent], times: [String])?

    private func rebuildEvents() {
        let shown = Array(calendar.dayEvents.prefix(2))
        let state = (hasAccess: calendar.hasAccess, events: calendar.dayEvents,
                     times: shown.map { $0.isAllDay ? "" : $0.start.formatted(date: .omitted, time: .shortened) })
        if let last = eventsState, last.hasAccess == state.hasAccess, last.events == state.events, last.times == state.times { return }
        eventsState = state
        events.subviews.forEach { $0.removeFromSuperview() }
        if !calendar.hasAccess {
            let button = PlainButton { [calendar] in calendar.requestAccess() }
            let icon = SymbolView("calendar.badge.plus", size: 11, color: Palette.secondary)
            let text = TextLabel("Takvimini bağla", font: Fonts.caption, color: Palette.secondary)
            text.setAccessibilityElement(false)
            button.addSubview(icon); button.addSubview(text)
            button.setAccessibilityLabel("Takvimini bağla")
            events.addSubview(button)
        } else if calendar.dayEvents.isEmpty {
            let button = PlainButton { [calendar] in calendar.openInCalendarApp() }
            let text = TextLabel("Etkinlik yok", font: Fonts.caption, color: Palette.tertiary)
            text.setAccessibilityElement(false)
            button.addSubview(text)
            button.toolTip = "Takvim'de aç"
            button.setAccessibilityLabel("Etkinlik yok")
            button.setAccessibilityHelp("Takvim'de aç")
            events.addSubview(button)
        } else {
            for event in calendar.dayEvents.prefix(2) {
                let button = PlainButton { [calendar] in calendar.open(event) }
                let bar = RoundedView(radius: 1.5, fill: event.calendarColor ?? .systemBlue)
                let time = TextLabel(event.isAllDay ? "Tüm gün" : event.start.formatted(date: .omitted, time: .shortened),
                                     font: Fonts.numericSmall, color: Palette.secondary)
                let title = TextLabel(event.title, font: Fonts.caption)
                [time, title].forEach { $0.setAccessibilityElement(false) }
                [bar, time, title].forEach(button.addSubview)
                button.toolTip = "Takvim'de aç"
                button.setAccessibilityLabel("\(time.stringValue) \(event.title)")
                button.setAccessibilityHelp("Takvim'de aç")
                events.addSubview(button)
            }
            if calendar.dayEvents.count > 2 {
                let button = PlainButton { [calendar] in calendar.openInCalendarApp() }
                let text = TextLabel("+\(calendar.dayEvents.count - 2) etkinlik", font: Fonts.caption2, color: Palette.tertiary)
                text.setAccessibilityElement(false)
                button.addSubview(text)
                button.setAccessibilityLabel(text.stringValue)
                events.addSubview(button)
            }
        }
    }

    override func layout() {
        super.layout()
        // Üst satır: ay (sol) + 5 günlük şerit (sağ), dikeyde ortalı.
        let cellSize = days.first?.preferredSize ?? CGSize(width: 24, height: 35)
        let rowH = max(month.lineHeight, cellSize.height)
        let stripWidth = CGFloat(days.count) * cellSize.width
        let monthWidth = min(month.naturalWidth, bounds.width - stripWidth - Spacing.s)
        monthButton.frame = CGRect(x: 0, y: (rowH - month.lineHeight) / 2, width: monthWidth, height: month.lineHeight)
        month.frame = monthButton.bounds
        var x = bounds.width - stripWidth
        for cell in days {
            cell.frame = CGRect(x: x, y: (rowH - cellSize.height) / 2, width: cellSize.width, height: cellSize.height)
            x += cellSize.width
        }
        let ey = rowH + 6
        events.frame = CGRect(x: 0, y: ey, width: bounds.width, height: bounds.height - ey)
        var y: CGFloat = 0
        for button in events.subviews {
            guard let button = button as? PlainButton else { continue }
            let labels = button.subviews
            var bx: CGFloat = 0
            var h: CGFloat = 0
            for v in labels {
                switch v {
                case let s as SymbolView:
                    let size = s.layoutSize // yerleşim kutusu; çizim çerçevesi aşağıda dikey ortalamada
                    h = max(h, size.height)
                    s.frame = CGRect(x: bx, y: 0, width: size.width, height: size.height)
                    bx += size.width + 5
                case let r as RoundedView:
                    r.frame = CGRect(x: bx, y: 0, width: 3, height: 12)
                    bx += 3 + 6
                    h = max(h, 12)
                case let t as TextLabel:
                    let w = min(t.naturalWidth, bounds.width - bx)
                    t.frame = CGRect(x: bx, y: 0, width: w, height: t.lineHeight)
                    bx += w + 6
                    h = max(h, t.lineHeight)
                default: break
                }
            }
            // Satır içinde dikey ortalama.
            for v in labels {
                if let s = v as? SymbolView {
                    let size = s.layoutSize
                    s.frame = s.drawingFrame(layoutOrigin: CGPoint(x: v.frame.minX, y: (h - size.height) / 2))
                } else {
                    v.frame.origin.y = (h - v.frame.height) / 2
                }
            }
            button.frame = pixelRect(CGRect(x: 0, y: y, width: labels.count == 1 && labels.first is TextLabel ? bounds.width : bx - 6, height: h))
            y += h + 3
        }
    }
}

/// Takvim şeridindeki gün hücresi: haftanın günü + gün numarası (bugün vurgu renginde, seçili/hover dairesi).
@MainActor
private final class DayCellView: PlainButton, TransientStateResettable {
    func resetTransientState() {
        guard isHovering else { return }
        isHovering = false
        updateCircle(animated: false)
    }

    let offset: Int
    private let weekday = TextLabel("", font: NSFont.systemFont(ofSize: 9, weight: .semibold), color: Palette.tertiary, alignment: .center)
    private let number = TextLabel("", font: Fonts.rounded(14, .semibold), alignment: .center)
    private let circle = RoundedView(radius: 11, fill: .clear)
    private var isSelected = false
    private var isHovering = false { didSet { if isHovering != oldValue { updateCircle(animated: true) } } }
    private var hoverArea: NSTrackingArea?

    init(offset: Int, select: @escaping () -> Void) {
        self.offset = offset
        super.init(action: select)
        [weekday, number].forEach { $0.setAccessibilityElement(false) }
        addSubview(weekday)
        addSubview(circle)
        addSubview(number)
    }

    var preferredSize: CGSize { CGSize(width: 24, height: weekday.lineHeight + 2 + 22) }

    func update(today: Date, selectedOffset: Int) {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: today) ?? today
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let wd = Calendar.current.component(.weekday, from: date)
        weekday.set(symbols[(wd - 1) % symbols.count])
        number.set("\(Calendar.current.component(.day, from: date))")
        let isToday = offset == 0
        let wasSelected = isSelected
        isSelected = offset == selectedOffset
        number.textColor = isToday ? .controlAccentColor : (isSelected ? Palette.primary : Palette.secondary)
        setAccessibilityLabel(Self.completeDate(date) + (isToday ? ", bugün" : ""))
        setAccessibilitySelected(isSelected)
        updateCircle(animated: window != nil && wasSelected != isSelected) // gün seçimi `IslandMotion.control` içinde
    }

    /// `date.formatted(date: .complete, time: .omitted)` gün başına bir kez (her açılışta beş tarih biçimlendirilmez).
    private static var dateCache: [Date: String] = [:]
    private static func completeDate(_ date: Date) -> String {
        let day = Calendar.current.startOfDay(for: date)
        if let cached = dateCache[day] { return cached }
        if dateCache.count > 64 { dateCache.removeAll() }
        let text = date.formatted(date: .complete, time: .omitted)
        dateCache[day] = text
        return text
    }

    /// SwiftUI: daire `if seçili || hover` ile eklenir/kalkar (varsayılan opaklık geçişi); hover ve gün seçimi
    /// `IslandMotion.control` ile canlanır.
    private lazy var visibility = LayerSpring(0) { [weak self] v in
        guard let layer = self?.circle.layer else { return [] }
        return [(layer, "opacity", Float(v))]
    }

    private func updateCircle(animated: Bool = false) {
        circle.fill = isSelected ? Palette.fillHover : Palette.fill
        visibility.animate(to: isSelected || isHovering ? 1 : 0, spec: animated ? DeneyMotion.control : nil)
    }

    override func layout() {
        super.layout()
        weekday.frame = CGRect(x: 0, y: 0, width: bounds.width, height: weekday.lineHeight)
        let y = weekday.lineHeight + 2
        circle.frame = CGRect(x: (bounds.width - 22) / 2, y: y, width: 22, height: 22)
        number.frame = CGRect(x: (bounds.width - 22) / 2, y: y + (22 - number.lineHeight) / 2, width: 22, height: number.lineHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
}

// MARK: - Anımsatıcılar

@MainActor
private final class NookRemindersView: FlippedView {
    private let header: PlainButton
    private let headerLabel = TextLabel("ANIMSATICILAR", font: Fonts.sectionLabel, color: Palette.secondary)
    private let list: RemindersListView
    private(set) var isViewing = false

    init(reminders: RemindersService) {
        header = PlainButton { reminders.openApp() }
        list = RemindersListView(reminders: reminders, limit: 2)
        super.init(frame: .zero)
        headerLabel.setAccessibilityElement(false)
        header.addSubview(headerLabel)
        header.toolTip = "Anımsatıcılar'da aç"
        header.setAccessibilityLabel("ANIMSATICILAR")
        header.setAccessibilityHelp("Anımsatıcılar'da aç")
        [header, list].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() { guard !isViewing else { return }; isViewing = true; list.didShow() }
    func didHide() { guard isViewing else { return }; isViewing = false; list.didHide() }

    override func layout() {
        super.layout()
        header.frame = CGRect(x: 0, y: 0, width: headerLabel.naturalWidth, height: headerLabel.lineHeight)
        headerLabel.frame = header.bounds
        let y = headerLabel.lineHeight + Spacing.xs
        list.frame = CGRect(x: 0, y: y, width: bounds.width, height: bounds.height - y)
    }
}

// MARK: - Kısayollar

@MainActor
private final class NookShortcutsView: FlippedView {
    private let launcher: LauncherStore
    private let header = TextLabel("KISAYOLLAR", font: Fonts.sectionLabel, color: Palette.secondary)
    private let tools: PlainButton
    private let empty = TextLabel("Notlar sekmesinden öğe ekleyin", font: Fonts.caption2, color: Palette.tertiary)
    private let grid = FlippedView()
    private lazy var observer = Observer(track: { [launcher] in _ = launcher.items }, apply: { [weak self] in self?.update() })

    init(launcher: LauncherStore, openTools: @escaping () -> Void) {
        self.launcher = launcher
        tools = PlainButton(action: openTools)
        super.init(frame: .zero)
        let icon = SymbolView("wrench.and.screwdriver", size: 11, color: Palette.secondary)
        tools.addSubview(icon)
        tools.toolTip = "Araçlar: kaldırıcı, önbellek temizleyici ve uygulama güncelleyici"
        tools.setAccessibilityLabel("Araçlar")
        tools.setAccessibilityHelp("Araçlar: kaldırıcı, önbellek temizleyici ve uygulama güncelleyici")
        [header, tools, empty, grid].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    func didShow() { observer.start() }
    func prewarm() { update() }
    func didHide() { observer.stop() }

    private var shownItems: [LauncherItem.ID] = []

    /// Öğeler değişmedikçe düğmeler yeniden kurulmaz (açılışta ilk güncelleme bedava); simgeler hazır küçük görsel.
    private func update() {
        empty.isHidden = !launcher.items.isEmpty
        let items = Array(launcher.items.prefix(8))
        guard items.map(\.id) != shownItems else { return }
        shownItems = items.map(\.id)
        grid.subviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let button = PlainButton { [launcher] in launcher.launch(item) }
            let image = DecorativeImageView()
            image.image = LauncherIconThumbnails.thumbnail(for: item, launcher: launcher)
            image.imageScaling = .scaleProportionallyUpOrDown
            image.setAccessibilityElement(false)
            button.addSubview(image)
            let title = launcher.title(for: item)
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.setAccessibilityHelp(title)
            grid.addSubview(button)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        header.frame = CGRect(x: 0, y: 0, width: header.naturalWidth, height: header.lineHeight)
        if let icon = tools.subviews.first as? SymbolView {
            let s = icon.layoutSize
            icon.place(asLabelOf: tools, layoutOrigin: CGPoint(x: bounds.width - s.width, y: (header.lineHeight - s.height) / 2))
        }
        let y = header.lineHeight + Spacing.xs
        empty.frame = CGRect(x: 0, y: y, width: bounds.width, height: empty.lineHeight)
        grid.frame = CGRect(x: 0, y: y, width: bounds.width, height: bounds.height - y)
        // 4 sabit 30 pt sütun, aralık 8; satır yüksekliği 28 (simge), aralık 8. Izgara yatayda ortalanır.
        let gridWidth = 4 * 30 + 3 * 8.0
        let x0 = (bounds.width - gridWidth) / 2
        for (index, button) in grid.subviews.enumerated() {
            let col = index % 4, row = index / 4
            button.frame = CGRect(x: x0 + CGFloat(col) * 38, y: CGFloat(row) * 36, width: 30, height: 28)
            button.subviews.first?.frame = CGRect(x: 1, y: 0, width: 28, height: 28)
        }
    }
}

/// Başlatıcı simgeleri için 28 pt'lik hazır küçük görseller (2×, bir kez). Uygulama simgeleri çok çözünürlüklüdür;
/// her açılışta büyük temsilden küçültmek ilk karenin çiziminde zaman alıyordu. Görünüm aynı (aynı en iyi temsilden
/// yüksek kaliteli küçültme).
@MainActor
enum LauncherIconThumbnails {
    private static var cache: [LauncherItem.ID: NSImage] = [:]

    static func thumbnail(for item: LauncherItem, launcher: LauncherStore) -> NSImage {
        if let cached = cache[item.id] { return cached }
        let source = launcher.icon(for: item)
        let side = 28 * 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return source }
        rep.size = NSSize(width: 28, height: 28)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: 28, height: 28), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.isTemplate = source.isTemplate
        cache[item.id] = image
        return image
    }
}
