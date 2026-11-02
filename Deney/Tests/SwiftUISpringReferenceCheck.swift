import AppKit
import QuartzCore
import SwiftUI

/// Public SwiftUI.Spring math is an independent SDK oracle, not another copy
/// of our analytic formula. This does not exercise matchedGeometry/layout,
/// transaction blending or actual screen frames.
@main struct SwiftUISpringReferenceCheck {
 @MainActor static func main() {
  var checks=0,worstX=0.0,worstV=0.0
  for spec in [DeneyMotion.naturalResize,DeneyMotion.livelyResize,DeneyMotion.reduced,DeneyMotion.expand,DeneyMotion.collapse] {
   let oracle=SwiftUI.Spring(response:spec.response,dampingRatio:spec.damping)
   for ms in [650,350,300,150,80,50] {
    var x=7.0,v=0.0,time=0.0,target=7.0,impulses:[CapsuleImpulse]=[]
    for selection in 0..<80 {
     let next=[7.0,350,73,201,410,65][selection%6]
     impulses.append(.init(displacement:target-next,started:time,spec:spec,
       duration:CapsuleImpulse.settlingDuration(displacement:target-next,spec:spec),key:"oracle-test"))
     target=next
     for _ in 0..<ms {
      let dt=0.001
      oracle.update(value:&x,velocity:&v,target:target,deltaTime:dt);time += dt
      let actualX=target+impulses.reduce(0){$0+$1.sample(at:time).value}
      let actualV=impulses.reduce(0){$0+$1.sample(at:time).velocity}
      worstX=max(worstX,abs(actualX-x));worstV=max(worstV,abs(actualV-v));checks += 1
      if abs(actualX-x)>0.03 || abs(actualV-v)>0.05 {
       print("FAIL: independent SwiftUI oracle response=\(spec.response),rate=\(ms), xError=\(abs(actualX-x)),vError=\(abs(actualV-v))");exit(1)
      }
     }
     impulses.removeAll{time >= $0.started+$0.duration}
    }
   }
  }
  print("PASS: \(checks) public SwiftUI.Spring oracle comparisons; maximum position error \(worstX) pt; velocity error \(worstV) pt/s")
 }
}
