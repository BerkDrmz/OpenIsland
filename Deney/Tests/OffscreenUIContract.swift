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
    static func main(){let app=NSApplication.shared;app.setActivationPolicy(.accessory);let d=OffscreenUIContract();retained=d;app.delegate=d;app.run()}
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
        let data:[String:Any]=["checks":checks,"failures":failures,"status":failures.isEmpty ? "PASS":"FAIL","scope":"In-process UI/hit/AX endpoint/lifecycle contracts; NOT real keyboard, VoiceOver, drag, frame or visible-screen proof."]
        let path=CommandLine.arguments.dropFirst().first!
        try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        print("UI contracts \(checks), failures \(failures.count)")
        exit(failures.isEmpty ? 0:1)
    }
}
