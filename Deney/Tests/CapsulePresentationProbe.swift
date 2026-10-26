import AppKit
import QuartzCore
import ApplicationServices

/// Real rendered layer telemetry. All timers/display links are TEST-ONLY.
/// Never requests TCC permissions, records audio or controls another application.
@main @MainActor final class CapsulePresentationProbe: NSObject, NSApplicationDelegate {
    private static var retained: CapsulePresentationProbe?
    static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        let d=CapsulePresentationProbe();retained=d;app.delegate=d;app.run()
    }
    private var window:NSPanel!, view:NSView!, capsule=CALayer(), motion:NativeCapsuleMotion!
    private var link:CADisplayLink?
    private var phase="", samples:[[String:Any]]=[], events:[[String:Any]]=[], series:[CapsuleImpulse]=[]
    private var target=7.0, spec=DeneyMotion.naturalResize
    private var maxActive=0
    func applicationDidFinishLaunching(_ note:Notification) {
        let locked=(CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        guard !locked else {
            let data:[String:Any]=["status":"NOT_TESTED","sessionLocked":true,"reason":"Visible presentation telemetry requires an unlocked rendering session."]
            let path=CommandLine.arguments.dropFirst().first!
            try! JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
            print("NOT_TESTED: session locked; no capture, window or input automation started")
            exit(3)
        }
        window=NSPanel(contentRect:CGRect(x:40,y:70,width:470,height:38),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.level = .floating;window.ignoresMouseEvents=true;window.backgroundColor = .black
        view=NSView(frame:CGRect(x:0,y:0,width:470,height:38));view.wantsLayer=true;window.contentView=view
        capsule.backgroundColor=NSColor.white.cgColor;capsule.cornerRadius=7;view.layer!.addSublayer(capsule)
        motion=NativeCapsuleMotion(layer:capsule);window.orderFrontRegardless()
        let d=view.displayLink(target:self,selector:#selector(frame(_:)));d.add(to:.main,forMode:.common);link=d
        Task { await run() }
    }
    private func expected(_ t:Double)->Double {
        let elapsed=series.filter{$0.started<=t}
        let lastTarget=7-elapsed.reduce(0){$0+$1.displacement}
        return lastTarget+elapsed.reduce(0){$0+$1.sample(at:t).value}
    }
    @objc private func frame(_ d:CADisplayLink) {
        guard !phase.isEmpty, let p=capsule.presentation() else{return}
        maxActive=max(maxActive,capsule.animationKeys()?.count ?? 0)
        samples.append(["phase":phase,"observed":CACurrentMediaTime(),"timestamp":d.timestamp,"targetTimestamp":d.targetTimestamp,
                        "x":p.position.x,"expectedAtTimestamp":expected(d.timestamp),"expectedAtTarget":expected(d.targetTimestamp),
                        "expectedAtObserved":expected(CACurrentMediaTime()),"active":capsule.animationKeys()?.count ?? 0])
    }
    private func run() async {
        for (name,style) in [("natural",DeneyMotion.naturalResize),("expressive",DeneyMotion.livelyResize),("reduced",DeneyMotion.reduced)] {
            spec=style
            for ms in [650,350,300,150,80,50] {
                phase="";motion.move(to:CGRect(x:0,y:4,width:14,height:24),spec:nil);target=7;series=[]
                try? await Task.sleep(for:.milliseconds(120))
                phase="\(name)-\(ms)"
                for x in [350.0,73,201,410,65,7] {
                    let now=CACurrentMediaTime(), old=target
                    let before=capsule.presentation()?.position.x ?? capsule.position.x
                    let beforeKeys=capsule.animationKeys() ?? []
                    motion.move(to:CGRect(x:x-7,y:4,width:14,height:24),spec:spec,now:now)
                    series.append(.init(displacement:old-x,started:now,spec:spec,duration:CapsuleImpulse.settlingDuration(displacement:old-x,spec:spec),key:"reference"))
                    events.append(["phase":phase,"time":now,"oldTarget":old,"target":x,"visibleBefore":before,
                                   "oldAnimationsKept":beforeKeys.allSatisfy{capsule.animation(forKey:$0) != nil}])
                    target=x
                    try? await Task.sleep(for:.milliseconds(ms))
                }
                try? await Task.sleep(for:.milliseconds(1100))
                events.append(["phase":phase,"settledX":capsule.presentation()?.position.x ?? capsule.position.x,
                               "settledAnimations":capsule.animationKeys()?.count ?? 0])
            }
        }
        phase="";link?.invalidate();link=nil;window.close()
        let result:[String:Any] = ["samples":samples,"events":events,"maxActiveAnimations":maxActive,
                                   "AXTrusted":AXIsProcessTrusted(),"screenCaptureAllowed":CGPreflightScreenCaptureAccess(),
                                   "note":"Presentation-layer telemetry, not a screenshot/photodiode or CPU benchmark. No permissions requested."]
        let path=CommandLine.arguments.dropFirst().first ?? "/tmp/openisland-capsule-presentation.json"
        do { try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path)) }
        catch { print(error);exit(2) }
        NSApp.terminate(nil)
    }
}
