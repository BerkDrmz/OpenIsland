import AppKit
import IslandCore
import os

/// Native, non-interactive UI contracts. Works while the session is locked,
/// but does NOT claim real keyboard/VoiceOver/drag or visible-screen parity.
@MainActor private final class CountingPanel: FlippedView, IslandPanel {
    var shows=0,hides=0
    func didShow(){shows += 1}
    func didHide(){hides += 1}
}
private final class CountingSymbolDescriptionImage: NSImage {
    nonisolated private let counter = OSAllocatedUnfairLock(initialState: 0)
    var reads: Int { counter.withLock { $0 } }
    override var accessibilityDescription: String? {
        get { counter.withLock { $0 += 1 }; return "özel simge" }
        set {}
    }
}
@main @MainActor final class OffscreenUIContract:NSObject,NSApplicationDelegate {
    static var retained:OffscreenUIContract?
    static func main(){
        // Production storage redirection intentionally requires DIAGNOSTICS,
        // not merely PERFORMANCE_SCRIPT. Fail BEFORE constructing any service
        // when the harness forgot that opt-in; never fall back to user data.
        let values=ProcessInfo.processInfo.environment
        guard let diagnostics=values["OPENISLAND_DIAGNOSTICS"],diagnostics.hasPrefix("/"),
              Bundle.main.bundleIdentifier?.hasPrefix("io.github.openisland.validation.") == true,
              let suite=values["OPENISLAND_TEST_DEFAULTS"],suite.hasPrefix("io.github.openisland.motion."),
              let support=values["OPENISLAND_TEST_SUPPORT"],support.hasPrefix("/"),support != "/",
              !support.contains("/Library/Application Support/") else {
            print("REFUSED: explicit diagnostics and isolated motion test defaults/support are required")
            exit(78)
        }
        guard AppPaths.support.standardizedFileURL.path == URL(fileURLWithPath:support).standardizedFileURL.path else {
            print("REFUSED: application storage was not redirected to the fixture")
            exit(78)
        }
        let app=NSApplication.shared;app.setActivationPolicy(.accessory);let d=OffscreenUIContract();retained=d;app.delegate=d;app.run()
    }
    var failures:[String]=[],checks=0
    func check(_ b:Bool,_ note:String){checks += 1;if !b{failures.append(note);print("FAIL: \(note)")}}
    func applicationDidFinishLaunching(_ n:Notification){Task{await run()}}
    func run() async {
        let env=AppEnvironment()
        env.preferences.focusModule=true;env.preferences.notesModule=true;env.preferences.mirrorModule=true;env.preferences.systemModule=true
        env.system.privateEnabled=false
        let panel=NSPanel(contentRect:CGRect(x:60,y:60,width:900,height:400),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false;panel.ignoresMouseEvents=true;panel.backgroundColor = .black
        let root=FlippedView(frame:CGRect(x:0,y:0,width:900,height:400));panel.contentView=root
        // Hidden placeholders must not read the system symbol localization
        // tables until an accessibility client actually asks for the label.
        // Native image roles, explicit overrides and immediate symbol changes
        // remain readable; no accessibility feature is disabled or delayed.
        let symbol = SymbolView("doc.on.clipboard", size: 12)
        let described = CountingSymbolDescriptionImage(size: NSSize(width: 14, height: 14))
        symbol.image = described
        symbol.exposeAsImage()
        check(described.reads == 0, "symbol exposure eagerly read localization metadata")
        check(symbol.accessibilityLabel() == "Özel Simge", "symbol label did not use the existing image")
        check(described.reads == 1, "first AX query did not resolve exactly once")
        check(symbol.accessibilityLabel() == "Özel Simge" && described.reads == 1, "repeated AX query repeated metadata work")
        symbol.setAccessibilityLabel("Explicit fixture")
        check(symbol.accessibilityLabel() == "Explicit fixture", "explicit symbol AX label was overwritten")
        symbol.exposeAsImage()
        check(symbol.accessibilityLabel() == "Özel Simge", "automatic AX labeling did not resume")
        symbol.set("folder", animated: false)
        let folderLabel = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?.accessibilityDescription?.capitalized(with: Locale(identifier: "tr_TR")) ?? ""
        check(symbol.accessibilityLabel() == folderLabel, "replaced symbol retained a stale AX label")
        symbol.set("display", animated: true)
        let displayLabel = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?.accessibilityDescription?.capitalized(with: Locale(identifier: "tr_TR")) ?? ""
        check(symbol.accessibilityLabel() == displayLabel, "animated symbol replacement retained a stale AX label")
        symbol.image = nil
        symbol.exposeAsImage()
        check(symbol.accessibilityLabel() == displayLabel, "missing configured image lost the named-symbol AX fallback")
        let stableSymbol = SymbolView("music.note", size: 12, weight: .semibold)
        stableSymbol.setConfiguration(size: 12, weight: .semibold)
        let originalGlyph = stableSymbol.image
        for _ in 0..<120 { stableSymbol.setConfiguration(size: 12, weight: .semibold) }
        check(stableSymbol.image === originalGlyph, "unchanged symbol configuration recreated the backing image")
        stableSymbol.setConfiguration(size: 20, weight: .bold)
        check(stableSymbol.image !== originalGlyph, "changed symbol configuration kept stale glyph")
        let art = ArtworkLayerView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        let placeholderGlyph = art.subviews.compactMap { $0 as? SymbolView }.first!
        art.image = NSImage(size: NSSize(width: 24, height: 24))
        let hiddenGlyph = placeholderGlyph.image
        for size in 25...120 {
            art.frame.size = NSSize(width: size, height: size)
            art.cornerRadius = CGFloat(size) / 5
        }
        check(placeholderGlyph.isHidden && placeholderGlyph.image === hiddenGlyph,
              "artwork morph rebuilt the fully hidden placeholder")
        art.image = nil
        check(!placeholderGlyph.isHidden && placeholderGlyph.image !== hiddenGlyph,
              "artwork removal did not immediately restore the current placeholder")
        check(placeholderGlyph.frame == placeholderGlyph.drawingFrame(centeredIn: art.bounds),
              "restored artwork placeholder retained stale geometry")
        for name in ["doc.on.clipboard", "tray.and.arrow.down", "hand.raised.fill", "speaker.wave.2.fill", "play.fill", "stopwatch", "plus", "cpu", "memorychip", "display", "airpods", "doc", "folder", "xmark", "arrow.counterclockwise"] {
            for size in [7.0, 10, 12, 20, 28] { for weight in [NSFont.Weight.regular, .semibold, .bold] {
                let v = SymbolView(name, size: size, weight: weight)
                let geometry = v.layoutSize
                v.exposeAsImage()
                let expected = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.accessibilityDescription?.capitalized(with: Locale(identifier: "tr_TR")) ?? ""
                check(v.accessibilityLabel() == expected, "system symbol label differs: \(name)/\(size)")
                check(v.layoutSize == geometry, "symbol AX exposure changed visual geometry")
            } }
        }
        // Actual Cocoa text system and stores, but private clipboard and injected
        // shortcut data. These are NOT global keyboard/VoiceOver commands.
        let fixture="OpenIsland K8c fixture\nİkinci satır • 123"
        let notes=NotesStore();notes.text=fixture
        let launcher=LauncherStore(fetchShortcuts:{ .success(["OpenIsland fixture shortcut"]) })
        let notePanel=NotesPanelView(notes:notes,launcher:launcher)
        notePanel.frame=CGRect(x:0,y:0,width:600,height:220);root.addSubview(notePanel);notePanel.didShow()
        notePanel.layoutSubtreeIfNeeded()
        func textView(in view:NSView)->NSTextView? {
            if let editor=view as? NSTextView{return editor}
            for child in view.subviews {if let editor=textView(in:child){return editor}}
            return nil
        }
        if let editor=textView(in:notePanel) {
            check(editor.acceptsFirstMouse(for:nil),"Notes discards the first explicit editor click in the nonactivating panel")
            check(editor.string==fixture,"Notes initial text differs from private store")
            let range=NSRange(location:4,length:7);editor.setSelectedRange(range)
            await launcher.refreshShortcutsIfNeeded()
            try? await Task.sleep(for:.milliseconds(20))
            check(editor.selectedRange()==range,"unrelated launcher update reset Notes selection")
            let board=NSPasteboard(name:.init("OpenIsland.private-notes-"+UUID().uuidString))
            check(editor.writeSelection(to:board,types:editor.writablePasteboardTypes),"native Notes private-board copy failed")
            check(board.string(forType:.string)==(fixture as NSString).substring(with:range),"native Notes selection text differs")
            board.releaseGlobally()
            check(notes.text==fixture,"selection/copy changed Notes store")
        } else {check(false,"native Notes NSTextView missing")}
        notePanel.didHide();notePanel.removeFromSuperview();launcher.shutdown();notes.flush()
        // These are real AppKit child views, not a SwiftUI opaque provider.
        // An opaque role exposes the buttons to AX queries but traps actual
        // VoiceOver linear navigation on the first launcher tile.
        let accessibleStack = LazyStackView(frame: CGRect(x: 0, y: 0, width: 160, height: 40))
        root.addSubview(accessibleStack)
        let stackLabels = ["Fixture One", "Fixture Two", "Fixture Three"]
        for (index, label) in stackLabels.enumerated() {
            let button = PlainButton()
            button.setAccessibilityLabel(label)
            button.frame = CGRect(x: index * 40, y: 0, width: 28, height: 28)
            accessibleStack.addSubview(button)
        }
        check(accessibleStack.accessibilityRole() == .group, "AppKit stack uses an opaque provider instead of a native accessible group")
        let accessibleChildren = (accessibleStack.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        check(accessibleChildren.map { $0.accessibilityLabel() ?? "" } == stackLabels, "native accessible group lost children or their source order")
        check(accessibleStack.accessibilityFrame().width == 108, "native accessible group changed its tight child-union geometry")
        accessibleStack.removeFromSuperview()
        // Native settings controls need their own accessible names. Nearby
        // static text is not a reliable VoiceOver/control association.
        let switchRow=SettingsToggleRow("Fixture switch",get:{false},set:{_ in})
        let segmentRow=SettingsSegmentedRow("Fixture motion",items:["One","Two"],get:{0},set:{_ in})
        let popupRow=SettingsPopUpRow("Fixture display",items:["One","Two"],get:{0},set:{_ in})
        for (row,label) in [(switchRow as NSView,"Fixture switch"),(segmentRow,"Fixture motion"),(popupRow,"Fixture display")] {
            let control=row.subviews.first{$0 is NSControl}
            check(control != nil && control?.accessibilityLabel()==label,"native settings control has no accessible name: \(label)")
        }

        // Removing the updater must leave two usable native tools, not just hide
        // a menu entry while leaving a third section or its tasks reachable.
        let maintenance=MaintenanceController()
        let tools=MaintenanceWindowView(controller:maintenance)
        tools.frame=CGRect(x:0,y:0,width:880,height:590);root.addSubview(tools)
        func toolLabels(_ view:NSView)->[String] {
            [view.accessibilityLabel()].compactMap{$0} + view.subviews.flatMap(toolLabels)
        }
        check(MaintenanceController.Section.allCases == [.uninstaller,.cleaner],"removed updater remains a reachable tools section")
        for section in MaintenanceController.Section.allCases {
            maintenance.select(section)
            try? await Task.sleep(for:.milliseconds(20))
            tools.layoutSubtreeIfNeeded()
            let labels=toolLabels(tools)
            check(labels.contains("Kaldırıcı") && labels.contains("Önbellek temizleyici"),"remaining native tool buttons missing")
            check(!labels.contains("Uygulama güncelleyici"),"removed updater remains in native AX tree")
            check(maintenance.section==section && !maintenance.hasActiveTask && maintenance.observerCount==0,
                  "dormant tool selection started background work or lost selection")
            check(tools.bounds.size==CGSize(width:880,height:590),"remaining tool section changed window content size")
        }
        tools.removeFromSuperview();maintenance.shutdown()

        // Exercise the actual native row/menu/copy route on a named PRIVATE
        // pasteboard. Never read or change the user's general clipboard.
        let linkBoard=NSPasteboard(name:.init("OpenIsland.private-link-cleaner-"+UUID().uuidString))
        let linkHistory=ClipboardHistory(storeURL:AppPaths.support.appendingPathComponent("link-cleaner-fixture.json"),pasteboard:linkBoard)
        let originalLink="https://example.invalid/p%2f?utm_source=fixture&id=42&x=1&x=2#keep"
        let cleanLink="https://example.invalid/p%2f?id=42&x=1&x=2#keep"
        let originalItem=ClipItem(content:.text(originalLink),date:Date(),sourceApp:"Private fixture")
        linkHistory.copy(originalItem)
        let clips=ClipboardPanelView(history:linkHistory,downloader:LinkDownloader())
        clips.frame=CGRect(x:0,y:0,width:760,height:220);root.addSubview(clips);clips.didShow();clips.layoutSubtreeIfNeeded()
        func clipRow(_ view:NSView,_ label:String)->NSView? {
            if view.accessibilityLabel()==label {return view}
            return view.subviews.lazy.compactMap{clipRow($0,label)}.first
        }
        if let row=clipRow(clips,originalLink),let event=NSEvent.mouseEvent(with:.rightMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1),
           let menu=row.menu(for:event),let index=menu.items.firstIndex(where:{$0.title=="Takipsiz bağlantıyı kopyala"}) {
            check(row.accessibilityCustomActions()?.contains{$0.name=="Takipsiz bağlantıyı kopyala"} == true,"link cleanup missing from native AX actions")
            menu.performActionForItem(at:index)
            check(linkBoard.string(forType:.string)==cleanLink,"native clean-link menu did not write exact cleaned URL to private board")
            check(linkHistory.items.contains{$0.id==originalItem.id && $0.content == .text(originalLink)},"clean-link copy mutated or lost the original history entry")
            check(linkHistory.items.first?.content == .text(cleanLink),"cleaned URL was not added as a separate history entry")
            let count=linkBoard.changeCount
            _ = row.accessibilityCustomActions()
            check(linkBoard.changeCount==count,"querying link actions performed a clipboard write")
        } else {check(false,"actual native tracked-link context menu missing")}
        clips.didHide();clips.removeFromSuperview();linkHistory.stop();linkBoard.releaseGlobally()

        // Legacy scrollbars consume viewport width. The mixer document and its
        // row controls must fit that viewport, not the outer NSScrollView frame.
        let mixerFit=MixerPanelView(mixer:AudioMixerController(),settings:{})
        root.addSubview(mixerFit)
        if let scroll=mixerFit.subviews.first(where:{$0 is NSScrollView}) as? NSScrollView {
            for autohide in [false,true] { scroll.autohidesScrollers=autohide
            for style in [NSScroller.Style.legacy,.overlay] {
                scroll.scrollerStyle=style
                for width:CGFloat in [320,400,620] {
                    mixerFit.frame=CGRect(x:0,y:0,width:width,height:180)
                    mixerFit.needsLayout=true;mixerFit.layoutSubtreeIfNeeded()
                    let viewport=scroll.contentSize.width
                    check((scroll.documentView?.frame.width ?? .infinity)<=viewport+0.01,
                          "mixer document overflows \(style) viewport at \(width) pt")
                    for row in scroll.documentView?.subviews ?? [] where !row.isHidden {
                        check(row.frame.minX>=0 && row.frame.maxX<=viewport+0.01,
                              "mixer control row is clipped behind \(style) scroller at \(width) pt")
                    }
                }
            }}
        } else {check(false,"mixer scroll view missing")}
        mixerFit.removeFromSuperview()
        check(ExpandedTab.focus.symbolName=="stopwatch","focus tab must use the complete stopwatch symbol")
        check(NSImage(systemSymbolName:ExpandedTab.focus.symbolName,accessibilityDescription:nil) != nil,
              "complete stopwatch symbol is unavailable")

        for tab in ExpandedTab.allCases {
            let model=IslandViewModel(metrics:NotchMetrics(notchSize:CGSize(width:192,height:33.5),style:.notch),configuration:.init(),hapticPerformer:{_ in})
            let content=PanelFactory.make(tab,model:model,environment:env)
            content.frame=CGRect(x:0,y:0,width:760,height:240);root.addSubview(content);content.layoutSubtreeIfNeeded()
            check(content.bounds.width>0 && content.bounds.height>0,"dormant panel geometry missing for \(tab)")
            // Never didShow Mirror/Mixer: mounting is not permission to capture.
            content.removeFromSuperview();model.cancelPendingEffects()
        }
        // Only the authorized keyboard-navigation cohort exercises this gate.
        // Cached hidden panels must not contribute native tab stops.
        if NSApp.isFullKeyboardAccessEnabled {
            let wrapper=FlippedView(frame:CGRect(x:0,y:0,width:100,height:40))
            let button=PlainButton();button.frame=wrapper.bounds
            root.addSubview(wrapper);wrapper.addSubview(button)
            check(button.canBecomeKeyView,"visible native button lost keyboard navigation")
            wrapper.isHidden=true
            check(!button.canBecomeKeyView,"hidden cached panel button remains in the key-view loop")
            wrapper.isHidden=false
            button.isEnabled=false
            check(!button.canBecomeKeyView,"disabled native button remains in key-view loop")
            wrapper.removeFromSuperview()
        }
        check(!env.system.isRunning,"dormant nine-panel construction started System worker")
        check(env.audioMixer.activeRouteCount==0,"dormant nine-panel construction started audio routing")
        // Deliberately not orderFront: this is not a claim about visible UI.
        // Test-fixture switch only: run the identical ownership reproduction
        // against an archived old source without coupling it to header changes.
        let ownershipOnly = ProcessInfo.processInfo.environment["OPENISLAND_UI_OWNERSHIP_ONLY"] == "1"
        if !ownershipOnly { for scale in [1.0,2.0] { for surface in ExpandedSurfaceSize.allCases {
            let metrics=NotchMetrics(notchSize:CGSize(width:192,height:33.5),style:.notch,scale:scale,expandedSurfaceSize:surface)
            let model=IslandViewModel(metrics:metrics,configuration:.init(),hapticPerformer:{_ in})
            model.hapticsEnabled=false;model.send(.demoModeChanged(isOn:true));model.send(.tapped)
            let header=HeaderView(model:model,environment:env);header.frame=CGRect(x:0,y:0,width:900,height:metrics.notchSize.height);root.addSubview(header)
            for style in MotionStyle.allCases { model.motionStyle=style
                for tab in ExpandedTab.allCases {
                    model.send(.selectTab(tab));header.refresh();header.layoutRow(tab:tab,frameWidth:900);header.layoutSubtreeIfNeeded()
                    let buttons=header.subviews.compactMap{$0 as? TabButtonView}
                    check(buttons.count==9,"nine tabs at \(scale)/\(surface)")
                    check(buttons.filter{$0.isSelected}.map(\.tab)==[tab],"selected tab/AX model \(tab)")
                    for button in buttons {
                        check(button.isAccessibilityElement() && button.accessibilityRole() == .button,"AX role \(button.tab)")
                        check(button.accessibilityLabel()==button.tab.title && button.toolTip==button.tab.title,"AX label/tooltip \(button.tab)")
                        let p=NSPoint(x:button.frame.midX,y:button.frame.midY)
                        let hit=header.hitTest(p)
                        check(hit === button || hit?.isDescendant(of:button)==true,"native hit region \(button.tab)")
                        let expected=NSAccessibility.screenRect(fromView:header,rect:button.frame)
                        check(button.accessibilityFrame().size==expected.size,"AX endpoint size \(button.tab)")
                    }
                    if let button=buttons.first(where:{$0.tab==tab}),let capsule=header.layer?.sublayers?.first {
                        check(abs(capsule.position.x-capsule.bounds.width/2-button.frame.minX)<0.01,"capsule endpoint \(tab)")
                    }
                }
            }
            model.send(.selectTab(.notes));header.refresh();header.layoutRow(tab:.notes,frameWidth:900)
            env.preferences.focusModule=false;header.refresh()
            check(header.subviews.compactMap{$0 as? TabButtonView}.filter{$0.isSelected}.map(\.tab)==[.notes],"module rebuild lost selected state")
            env.preferences.focusModule=true
            header.removeFromSuperview();model.cancelPendingEffects()
        }}}
        // Two independent owners: deallocating a suspended cached panel must
        // NOT consume another window's live System/Mirror ownership count.
        let metrics=NotchMetrics(notchSize:CGSize(width:192,height:33.5),style:.notch)
        let model=IslandViewModel(metrics:metrics,configuration:.init(),hapticPerformer:{_ in})
        model.hapticsEnabled=false;model.send(.demoModeChanged(isOn:true));model.send(.tapped);model.send(.selectTab(.system))
        check(model.presentation.expandedTab == .system,"ownership fixture did not select System")
        env.system.panelDidAppear()
        weak var retired:ExpandedContentView?
        autoreleasepool {
            let expanded=ExpandedContentView(model:model,environment:env,dormant:true)
            retired=expanded
            root.addSubview(expanded);expanded.activate();expanded.suspend();expanded.removeFromSuperview()
        }
        try? await Task.sleep(for:.milliseconds(30))
        check(retired == nil,"ownership fixture did not destroy the suspended view")
        check(env.system.isRunning,"destroying suspended panel stopped another System owner")
        env.system.panelDidDisappear();check(!env.system.isRunning,"last System owner did not stop")
        let fake=CountingPanel();let container=PanelContainer(panel:fake);root.addSubview(container)
        container.fadeIn(duration:0);container.suspend();container.suspend();check(fake.shows==1 && fake.hides==1,"unbalanced panel ownership")
        container.fadeIn(duration:0)
        for _ in 0..<100 {
            container.fadeOut(duration:0.01)
            container.fadeIn(duration:0.15)
            check(!container.isHidden && !container.isFadingOut,"rapid retarget lost selected panel")
        }
        try? await Task.sleep(for:.milliseconds(60))
        check(!container.isHidden && !container.isFadingOut && fake.shows==2 && fake.hides==1,
              "retired fade callback hid or released the reopened panel")
        container.fadeOut(duration:0.01)
        try? await Task.sleep(for:.milliseconds(60))
        check(container.isHidden && !container.isFadingOut && fake.hides==2,"final fade did not release owner")
        container.suspend();check(fake.hides==2,"suspending a completed fade released owner twice")
        checkSettingsPersistence(env)
        checkPrivateClipboardFormats(root)
        container.removeFromSuperview();panel.close();model.cancelPendingEffects();env.shutdown()
        let data:[String:Any]=["checks":checks,"failures":failures,"status":failures.isEmpty ? "PASS":"FAIL",
                              "storageRoot":AppPaths.support.path,"defaultsSuite":ProcessInfo.processInfo.environment["OPENISLAND_TEST_DEFAULTS"]!,
                              "scope":"In-process UI/hit/AX endpoint/lifecycle contracts; NOT real keyboard, VoiceOver, drag, frame or visible-screen proof."]
        let path=CommandLine.arguments.dropFirst().first!
        try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        print("UI contracts \(checks), failures \(failures.count)")
        exit(failures.isEmpty ? 0:1)
    }
    /// Native action/serialization coverage, deliberately without a coordinator.
    /// This must not register login items or enable global app-closing monitors.
    private func checkSettingsPersistence(_ env: AppEnvironment) {
        let suite=ProcessInfo.processInfo.environment["OPENISLAND_TEST_DEFAULTS"]!
        let defaults=UserDefaults(suiteName:suite)!
        let keys:[String:String]=[
            "Dokunsal geri bildirim (Force Touch trackpad)":"hapticsEnabled",
            "Düşük Güç Modu'nda pil tasarrufu":"energySaving",
            "Müzik nabzı albüm renginde":"albumColoredPulse",
            "Ağ bağlantısı kesildi / geri geldi":"networkNotices",
            "Harici ekran ve ekran düzeni değişikliği":"displayNotices",
            "Pil ve şarj (adaptör, %20, %10, %100)":"batteryNotices",
            "Ses aygıtı bağlandı / ayrıldı (AirPods, kulaklık)":"audioDeviceNotices",
            "Parça değişimi":"trackChangeNotices", "Toplantı hatırlatması (5 dk önce)":"meetingReminders",
            "Kilit açıldı":"unlockNotices", "Dock'ta pencere önizlemeleri":"dockWindowPreviews",
            "Son pencereyi kırmızı düğmeden kapatınca uygulamadan çık":"quitOnLastWindowClose",
            "Klavye kısayolu ⌃⌥⌘I ile aç/kapat":"globalHotKey",
            "Pano geçmişi ve renk seçici":"clipboardHistoryEnabled",
            "Odak: zamanlayıcı, takvim, anımsatıcılar":"focusModule",
            "Notlar ve uygulama kısayolları":"notesModule", "Ayna (kamera önizlemesi)":"mirrorModule",
            "Sistem: CPU, GPU, bellek, sıcaklık, parlaklık":"systemModule",
            "Sıcaklık, parlaklık ve klavye ışığı":"systemPrivateSensors",
            "Trackpad jestleri (yatay: parça, dikey: ses)":"gesturesEnabled",
            "Medya jestini ters çevir (sağa kaydır: sonraki parça)":"reversesMediaSwipe",
            "İndirme / aktarım canlı etkinliği":"transferActivity"
        ]
        func all(_ v:NSView)->[NSView] { [v]+v.subviews.flatMap(all) }
        let forms=[SettingsContent.general(env),SettingsContent.notifications(env),SettingsContent.system(env),SettingsContent.modules(env.preferences)]
        var tested=Set<String>()
        for view in forms {
            guard let form=view as? SettingsFormView else{check(false,"settings form missing");continue}
            form.refresh()
            for control in all(form).compactMap({$0 as? NSSwitch}) {
                guard let label=control.accessibilityLabel(),let key=keys[label]else{continue}
                let original=control.state
                for desired in [original == .on ? NSControl.StateValue.off:.on,original] {
                    control.state=desired
                    check(control.sendAction(control.action,to:control.target),"native switch action missing: \(label)")
                    form.refresh()
                    check(defaults.object(forKey:key) as? Bool == (desired == .on),"native switch did not persist: \(label)")
                    check(control.state==desired,"native switch refresh did not round-trip: \(label)")
                }
                tested.insert(key)
            }
            let enums:[String:(String,[String])]=[
                "Açık ada boyutu":("expandedSurfaceSize",[ExpandedSurfaceSize.compact.rawValue,ExpandedSurfaceSize.standard.rawValue]),
                "Hareket":("motionStyle",MotionStyle.allCases.map(\.rawValue)),
                "Nook düzeni":("nookLayout",NookLayout.allCases.map(\.rawValue))
            ]
            for control in all(form).compactMap({$0 as? NSSegmentedControl}) {
                let label=control.accessibilityLabel() ?? "";let original=control.selectedSegment
                for index in Array(0..<control.segmentCount)+[original] where index>=0 {
                    control.selectedSegment=index
                    check(control.sendAction(control.action,to:control.target),"native segment action missing: \(label)")
                    form.refresh()
                    check(control.selectedSegment==index,"native segment refresh lost selection: \(label)")
                    if let (key,values)=enums[label] {check(defaults.string(forKey:key)==values[index],"native segment did not persist: \(label)")}
                    else if label=="Üzerine gelince aç" {
                        let preset=HoverPreset.allCases[index]
                        check(defaults.bool(forKey:"expandsOnHover")==((preset != .off)),"hover enabled state did not persist")
                        if let delay=preset.delay{check(defaults.double(forKey:"hoverDelay")==delay,"hover delay did not persist")}
                    }
                }
            }
            let menus:[String:(String,[String])]=[
                "Gösterilecek ekran":("displayTarget",DisplayTarget.allCases.map(\.rawValue)),
                "Tam ekranda":("fullscreenBehavior",FullscreenBehavior.allCases.map(\.rawValue))
            ]
            for control in all(form).compactMap({$0 as? NSPopUpButton}) {
                guard let (key,values)=menus[control.accessibilityLabel() ?? ""]else{continue}
                let original=control.indexOfSelectedItem
                for index in Array(0..<control.numberOfItems)+[original] where index>=0 {
                    control.selectItem(at:index)
                    check(control.sendAction(control.action,to:control.target),"native popup action missing")
                    form.refresh()
                    check(control.indexOfSelectedItem==index && defaults.string(forKey:key)==values[index],"native popup did not round-trip: \(key)")
                }
            }
        }
        check(tested==Set(keys.values),"settings switch coverage incomplete: \(Set(keys.values).subtracting(tested))")
        // Login registration and permission-grant buttons intentionally NOT run.
    }

    private func checkPrivateClipboardFormats(_ root:NSView) {
        let board=NSPasteboard(name:.init("OpenIsland.private-formats-"+UUID().uuidString))
        defer{board.releaseGlobally()}
        let history=ClipboardHistory(storeURL:AppPaths.support.appendingPathComponent("format-history.json"),pasteboard:board)
        let image=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let png=image.representation(using:.png,properties:[:])!
        let file=AppPaths.support.appendingPathComponent("OpenIsland format 你好.bin")
        let bytes=Data([0,1,2,127,128,255]);try! bytes.write(to:file)
        let formats:[ClipItem.Content]=[.text("OpenIsland private format"),.image(png),.files([file])]
        let panel=ClipboardPanelView(history:history,downloader:LinkDownloader())
        panel.frame=CGRect(x:0,y:0,width:760,height:220);root.addSubview(panel);panel.didShow()
        defer{panel.didHide();panel.removeFromSuperview()}
        func row(_ v:NSView,_ label:String)->NSView? { if v.accessibilityLabel()==label{return v};return v.subviews.lazy.compactMap{row($0,label)}.first }
        for content in formats {
            let item=ClipItem(content:content,date:Date(),sourceApp:"Private format fixture")
            history.copy(item);panel.didHide();panel.didShow();panel.layoutSubtreeIfNeeded()
            let label:String
            switch content{case .text(let t):label=t;case .image:label="Görsel";case .files:label=file.lastPathComponent}
            guard let native=row(panel,label)else{check(false,"native clipboard format row missing");continue}
            check(native.accessibilityPerformPress(),"native clipboard format row press failed")
            switch content {
            case .text(let text):check(board.string(forType:.string)==text,"native text copy altered bytes")
            case .image(let data):check(board.data(forType:.png)==data,"native image copy altered bytes")
            case .files(let files):check(board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] == files,"native file copy changed original URL")
            }
            let remove=native.accessibilityCustomActions()?.first{$0.name=="Geçmişten sil"}
            check(remove?.handler?() == true,"native clipboard remove custom action failed")
            check(!history.items.contains{$0.id==item.id},"deleted native row remained in history")
        }
        check((try? Data(contentsOf:file))==bytes,"clipboard file bytes changed")
        history.clear();check(history.items.isEmpty,"private clipboard clear failed")
    }

}
