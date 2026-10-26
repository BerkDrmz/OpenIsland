import AppKit
import QuartzCore

@main @MainActor final class CapsuleRetirementDiagnostic: NSObject, NSApplicationDelegate {
    static var retained: CapsuleRetirementDiagnostic?
    static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        let d=CapsuleRetirementDiagnostic();retained=d;app.delegate=d;app.run()
    }
    func applicationDidFinishLaunching(_ n:Notification){Task{await run()}}
    func run() async {
        let locked=(CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        guard !locked else {print("NOT_TESTED: locked");exit(3)}
        let window=NSPanel(contentRect:CGRect(x:40,y:70,width:470,height:38),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.ignoresMouseEvents=true;window.level = .floating
        let view=NSView(frame:CGRect(x:0,y:0,width:470,height:38));view.wantsLayer=true;window.contentView=view
        let layer=CALayer();layer.backgroundColor=NSColor.white.cgColor;view.layer!.addSublayer(layer)
        window.orderFrontRegardless()
        var rows:[[String:Any]]=[]
        func snapshot(_ phase:String) {
            let local=layer.convertTime(CACurrentMediaTime(),from:nil)
            let animations=(layer.animationKeys() ?? []).map{key -> [String:Any] in
                let a=layer.animation(forKey:key)!
                return ["key":key,"begin":a.beginTime,"duration":a.duration,"elapsed":local-a.beginTime,"removedOnCompletion":a.isRemovedOnCompletion,"fillMode":a.fillMode.rawValue,"speed":a.speed]
            }
            rows.append(["phase":phase,"localTime":local,"modelX":layer.position.x,"presentationX":layer.presentation()?.position.x ?? -999,"animations":animations,
                         "layerSpeed":layer.speed,"parentSpeed":view.layer!.speed,"windowVisible":window.isVisible,"occlusionVisible":window.occlusionState.contains(.visible)])
        }
        for mode in ["native","basic-control"] {
            layer.removeAllAnimations()
            let driver=NativeCapsuleMotion(layer:layer)
            driver.move(to:CGRect(x:0,y:4,width:14,height:24),spec:nil)
            for i in 0..<10 {
                if mode == "native" {
                    driver.move(to:CGRect(x:i%2==0 ? 350:70,y:4,width:14,height:24),spec:DeneyMotion.naturalResize)
                } else {
                    CATransaction.begin();CATransaction.setDisableActions(true)
                    let a=CABasicAnimation(keyPath:"position.x");a.fromValue=layer.presentation()?.position.x ?? layer.position.x;a.toValue=i%2==0 ? 357:77;a.duration=0.3
                    layer.position.x=i%2==0 ? 357:77;layer.add(a,forKey:"control");CATransaction.commit()
                }
                try? await Task.sleep(for:.milliseconds(50))
            }
            snapshot("\(mode)-last-event")
            try? await Task.sleep(for:.milliseconds(1600))
            snapshot("\(mode)-after-idle")
            CATransaction.flush();snapshot("\(mode)-after-flush")
            try? await Task.sleep(for:.milliseconds(120))
            snapshot("\(mode)-after-flush-and-wait")
        }
        window.close()
        let path=CommandLine.arguments[1]
        try! JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        print("Diagnostic recorded (not a performance or equivalence pass)")
        exit(0)
    }
}
