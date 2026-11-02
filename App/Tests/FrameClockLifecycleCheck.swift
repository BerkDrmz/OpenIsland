import AppKit
import QuartzCore

/// Hidden-window lifetime reproduction; no keyboard, permissions or user data.
@main struct FrameClockLifecycleCheck {
 @MainActor static func main() {
  _ = NSApplication.shared
  var retired:[WeakDriver]=[]
  for _ in 0..<100 {
   autoreleasepool {
    let window=NSPanel(contentRect:CGRect(x:40,y:70,width:100,height:40),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let view=NSView(frame:CGRect(x:0,y:0,width:100,height:40));window.contentView=view
    let driver=FrameDriver(view:view){[weak view] _ in view != nil}
    retired.append(WeakDriver(driver));driver.start()
    // No frame callback is guaranteed for a hidden or closing window.
    window.close()
   }
  }
  for _ in 0..<100 {
   autoreleasepool {
    let view=NSView(frame:CGRect(x:0,y:0,width:100,height:40))
    let driver=FrameDriver(view:view){[weak view] _ in view != nil}
    retired.append(WeakDriver(driver));driver.start()
   }
  }
  let alive=retired.filter{$0.value != nil}.count
  guard alive == 0 else{print("FAIL: \(alive) closed-window FrameDrivers retained without a future frame callback");exit(1)}
  print("PASS: 100 closing/hidden windows and 100 windowless drivers release without another display callback")
 }
 @MainActor private final class WeakDriver {
  weak var value:FrameDriver?
  init(_ driver:FrameDriver){value=driver}
 }
}
