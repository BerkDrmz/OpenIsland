import AppKit

/// Actual display callbacks, but NOT an FPS or performance benchmark.
@main @MainActor final class FrameClockReopenCheck:NSObject,NSApplicationDelegate {
 static var retained:FrameClockReopenCheck?
 static func main(){let app=NSApplication.shared;app.setActivationPolicy(.accessory);let d=FrameClockReopenCheck();retained=d;app.delegate=d;app.run()}
 func applicationDidFinishLaunching(_ n:Notification){Task{await run()}}
 func run() async{
  guard ((CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false)==false else{print("NOT_TESTED: locked");exit(3)}
  let window=NSPanel(contentRect:CGRect(x:40,y:70,width:100,height:40),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  window.isReleasedWhenClosed=false;window.ignoresMouseEvents=true
  let view=NSView(frame:CGRect(x:0,y:0,width:100,height:40));window.contentView=view
  var ticks=0
  var driver:FrameDriver?=FrameDriver(view:view){_ in ticks += 1;return true}
  weak var released=driver
  window.orderFrontRegardless();driver!.start()
  try? await Task.sleep(for:.milliseconds(350))
  guard ticks>1 else{print("FAIL: no original display callbacks");exit(1)}
  let first=ticks;window.close()
  try? await Task.sleep(for:.milliseconds(100))
  window.orderFrontRegardless()
  let before=ticks
  try? await Task.sleep(for:.milliseconds(350))
  guard ticks>before+1,driver!.isRunning else{print("FAIL: cached-window reopen froze active driver, before \(before) after \(ticks)");exit(1)}
  driver!.stop();driver=nil;window.close()
  guard released==nil else{print("FAIL: reopened driver retained");exit(1)}
  print("PASS: real callbacks before close \(first), after reopening \(ticks-before); active driver preserved then released")
  exit(0)
 }
}
