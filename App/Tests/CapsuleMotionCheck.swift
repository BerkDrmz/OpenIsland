import AppKit
import QuartzCore

@main struct CapsuleMotionCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var checks=0, worst=0.0
        func check(_ value: Bool, _ text: String) { checks += 1; if !value { print("FAIL: \(text)"); exit(1) } }
        for spec in [AppMotion.naturalResize, AppMotion.livelyResize, AppMotion.reduced] {
            for interval in [0.65,0.35,0.3,0.15,0.08,0.05] {
                var reference=Spring(7), target=7.0
                var impulses:[CapsuleImpulse]=[]
                var now=0.0
                for selection in 0..<80 {
                    let next=[7.0,350,73,201,410,65][selection%6]
                    let old=target
                    let animation=CASpringAnimation(keyPath:"position.x")
                    animation.mass=1;animation.stiffness=pow(2 * .pi / spec.response,2);animation.damping=4 * .pi * spec.damping/spec.response
                    impulses.append(.init(displacement:old-next,started:now,spec:spec,duration:CapsuleImpulse.settlingDuration(displacement:old-next,spec:spec),key:"fixture"))
                    target=next; reference.animate(to:next,spec:spec)
                    for _ in 0..<Int((interval*960).rounded()) {
                        now += 1.0/960;reference.step(1.0/960)
                        let result=target+impulses.reduce(0){$0+$1.sample(at:now).value}
                        let error=abs(result-reference.value);worst=max(worst,error)
                        check(error<0.025,"additive curve mismatch \(error) @\(interval)")
                    }
                    impulses.removeAll{now >= $0.started+$0.duration}
                    check(impulses.count<50,"unbounded impulses")
                }
            }
        }
        let window=NSPanel(contentRect:CGRect(x:20,y:20,width:460,height:28),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.ignoresMouseEvents=true
        let view=NSView(frame:CGRect(x:0,y:0,width:460,height:28));view.wantsLayer=true;window.contentView=view
        let layer=CALayer();layer.backgroundColor=NSColor.white.cgColor;view.layer!.addSublayer(layer)
        window.orderFrontRegardless();RunLoop.current.run(until:Date().addingTimeInterval(0.1))
        defer{window.close()}
        let driver=NativeCapsuleMotion(layer:layer);let start=CACurrentMediaTime()
        driver.move(to:CGRect(x:0,y:0,width:14,height:24),spec:nil,now:start)
        driver.move(to:CGRect(x:200,y:0,width:14,height:24),spec:AppMotion.naturalResize,now:start)
        let before=layer.animationKeys() ?? []
        check(!before.isEmpty,"native animation missing from rendered layer")
        for _ in 0..<100 { driver.move(to:CGRect(x:200,y:0,width:14,height:24),spec:AppMotion.naturalResize,now:start+0.08) }
        check(layer.animationKeys()==before,"same-target layout changed native animations")
        driver.move(to:CGRect(x:30,y:0,width:14,height:24),spec:AppMotion.naturalResize,now:start+0.08)
        check((layer.animationKeys() ?? []).count==2,"retarget did not preserve old momentum")
        check(layer.position.x==37,"last selection endpoint lost")
        check((layer.animationKeys() ?? []).allSatisfy{(layer.animation(forKey:$0) as? CASpringAnimation)?.isAdditive==true},"not a native additive spring")
        print("PASS: \(checks) actual-source spring/layout contracts; worst error \(worst) pt; all 6 rates / 3 styles / 80 retargets")
    }
}
