import AppKit
import IslandCore

/// Native, non-interactive UI contracts. Works while the session is locked,
/// but does NOT claim real keyboard/VoiceOver/drag or visible-screen parity.
@MainActor private final class CountingPanel: FlippedView, IslandPanel {
    var shows=0,hides=0
    func didShow(){shows += 1}
    func didHide(){hides += 1}
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
        container.removeFromSuperview();panel.close();model.cancelPendingEffects();env.shutdown()
        let data:[String:Any]=["checks":checks,"failures":failures,"status":failures.isEmpty ? "PASS":"FAIL",
                              "storageRoot":AppPaths.support.path,"defaultsSuite":ProcessInfo.processInfo.environment["OPENISLAND_TEST_DEFAULTS"]!,
                              "scope":"In-process UI/hit/AX endpoint/lifecycle contracts; NOT real keyboard, VoiceOver, drag, frame or visible-screen proof."]
        let path=CommandLine.arguments.dropFirst().first!
        try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        print("UI contracts \(checks), failures \(failures.count)")
        exit(failures.isEmpty ? 0:1)
    }
}
