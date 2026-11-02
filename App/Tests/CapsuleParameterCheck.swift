import AppKit
import QuartzCore
import SwiftUI

/// Public SDK spring oracle plus actual CA animation objects, not rendered frames.
@main struct CapsuleParameterCheck {
 @MainActor static func main() {
  _ = NSApplication.shared
  let window=NSPanel(contentRect:CGRect(x:40,y:70,width:470,height:38),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  window.isReleasedWhenClosed=false;window.ignoresMouseEvents=true
  let view=NSView(frame:CGRect(x:0,y:0,width:470,height:38));view.wantsLayer=true;window.contentView=view
  let layer=CALayer();view.layer!.addSublayer(layer);window.orderFrontRegardless()
  defer{window.close()}
  let driver=NativeCapsuleMotion(layer:layer), now=CACurrentMediaTime()
  driver.move(to:CGRect(x:0,y:4,width:14,height:24),spec:nil,now:now)
  driver.move(to:CGRect(x:343,y:4,width:14,height:24),spec:AppMotion.naturalResize,now:now)
  let oldKeys=layer.animationKeys() ?? []
  driver.move(to:CGRect(x:343,y:4,width:14,height:24),spec:AppMotion.livelyResize,now:now+0.08)
  let keys=layer.animationKeys() ?? []
  guard !keys.isEmpty,keys != oldKeys,keys.allSatisfy({ key in
   guard let a=layer.animation(forKey:key) as? CASpringAnimation else{return false}
   return abs(a.stiffness-pow(2 * .pi/AppMotion.livelyResize.response,2))<1e-8
  }) else {print("FAIL: same-target response/damping change ignored while capsule is moving");exit(1)}
  var x=7.0,v=0.0
  let oldOracle=SwiftUI.Spring(response:AppMotion.naturalResize.response,dampingRatio:AppMotion.naturalResize.damping)
  oldOracle.update(value:&x,velocity:&v,target:350,deltaTime:0.08)
  var configuredX=layer.position.x,configuredV=0.0
  for key in keys {
   let a=layer.animation(forKey:key) as! CASpringAnimation
   let d=(a.fromValue as! NSNumber).doubleValue
   configuredX += d; configuredV += -d * a.initialVelocity
  }
  guard abs(configuredX-x)<0.0001,abs(configuredV-v)<0.001 else{
   print("FAIL: parameter retarget discarded position/velocity: \(configuredX-x),\(configuredV-v)");exit(1)
  }
  print("PASS: same-target parameter retarget preserves physical position and velocity against public SwiftUI oracle")
 }
}
