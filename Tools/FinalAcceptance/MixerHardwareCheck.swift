import AppKit
import CoreAudio
import Foundation
import IslandCore

enum MotionStyle { case expressive, natural, reduced }
@main @MainActor final class MixerAcceptance:NSObject,NSApplicationDelegate {
 static var retained:MixerAcceptance?
 var mixer:AudioMixerController!
 var output:URL!
 var start=ProcessInfo.processInfo.systemUptime
 var rows:[[String:Any]]=[]
 var failure=false
 var commandStart:[String:Double]=[:]
 static func main(){let app=NSApplication.shared;app.setActivationPolicy(.accessory);let d=MixerAcceptance();retained=d;app.delegate=d;app.run()}
 func record(_ event:String,_ extra:[String:Any]=[:]){
  var row=extra;row["event"]=event;row["elapsed"]=ProcessInfo.processInfo.systemUptime-start
  if event.hasSuffix(".begin") {commandStart[String(event.dropLast(6))]=row["elapsed"] as? Double}
  let suffix=event.hasSuffix(".commandReturned") ? ".commandReturned" : (event.hasSuffix(".end") ? ".end" : "")
  if !suffix.isEmpty,let began=commandStart[String(event.dropLast(suffix.count))],let ended=row["elapsed"] as? Double,ended-began>1 {
   failure=true;row["mainThreadResponsivenessFailureSeconds"]=ended-began
  }
  rows.append(row)
  let data=try! JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]);var line=data;line.append(10)
  let path=output.appendingPathComponent("timeline.jsonl")
  if !FileManager.default.fileExists(atPath:path.path){FileManager.default.createFile(atPath:path.path,contents:nil)}
  let file=try! FileHandle(forWritingTo:path);try! file.seekToEnd();try! file.write(contentsOf:line);try! file.close()
 }
 func applicationDidFinishLaunching(_ note:Notification){
  let args=CommandLine.arguments
  guard let raw=ProcessInfo.processInfo.environment["OPENISLAND_ACCEPTANCE_ROOT"],raw.hasPrefix("/")else{exit(78)}
  let root=URL(fileURLWithPath:raw).resolvingSymlinksInPath()
  guard FileManager.default.fileExists(atPath:root.appendingPathComponent(".openisland-acceptance").path),args.count==4,
        let pid=Int32(args[1]),let source=NSRunningApplication(processIdentifier:pid),
        source.executableURL?.path==root.appendingPathComponent("apps/AudioFixture.app/Contents/MacOS/AudioFixture").path,
        source.executableURL?.path==args[2]else{exit(78)}
  output=URL(fileURLWithPath:args[3]).resolvingSymlinksInPath()
  guard output.path.hasPrefix(root.appendingPathComponent("runs").path+"/")else{exit(78)}
  mixer=AudioMixerController()
  Task {await run(pid:pid)}
 }
 func state(_ pid:pid_t)->[String:Any]{
  let app=mixer.applications.first{$0.id==pid}
  return ["route":mixer.diagnosticState(pid:pid),"routes":mixer.activeRouteCount,"listeners":mixer.listenerCount,"playing":app?.isPlaying ?? false,"processes":app?.processes ?? [],"error":mixer.error ?? "none","requested":mixer.volumes[pid] ?? 1]
 }
 func awaitState(_ name:String,pid:pid_t,check:([String:Any])->Bool)async->Bool{
  let deadline=ProcessInfo.processInfo.systemUptime+12;var old=""
  while ProcessInfo.processInfo.systemUptime<deadline {
   let x=state(pid);let current=String(describing:x)
   if current != old {record(name+".state",x);old=current}
   if check(x){record(name+".accepted",x);return true}
   if x["error"] as? String != "none"{break}
   try? await Task.sleep(for:.milliseconds(100))
  }
  record(name+".NOT_ACCEPTED",state(pid));failure=true;return false
 }
 func run(pid:pid_t)async {
  record("show.begin");mixer.showPanel();record("show.end",state(pid))
  let registered=await awaitState("registered",pid:pid){($0["playing"] as? Bool)==true && !((($0["processes"] as? [AudioObjectID]) ?? []).isEmpty)}
  if registered {
   for value:Float in [0.25,0.5,0.75,0,0.25,1] {
    let name="gain.\(value)";record(name+".begin");mixer.setApplicationVolume(value,pid:pid);record(name+".commandReturned",state(pid))
    _=await awaitState(name,pid:pid){x in
     let text=x["route"] as? String ?? ""
     if value==1{return x["routes"] as? Int==0 && text=="no route"}
     if value==0{return text.contains("tap=") && !text.contains("tap=0 ") && text.contains("device=0 ") && text.contains("starting=false")}
     return text.contains("ready=true") && text.contains("signal=true") && text.contains("target=\(value)") && text.contains("current=\(value)")
    }
    try? await Task.sleep(for:.milliseconds(400))
    record(name+".settled",state(pid))
   }
   record("restoreForRecovery.begin");mixer.setApplicationVolume(0.5,pid:pid);record("restoreForRecovery.end",state(pid))
   _=await awaitState("recovery-ready",pid:pid){($0["route"] as? String ?? "").contains("ready=true")}
   record("interrupt.begin");mixer.interruptRouteForDiagnostics(pid:pid);record("interrupt.end",state(pid))
   _=await awaitState("interrupt-recovery",pid:pid){let t=$0["route"] as? String ?? "";return t.contains("ready=true") && t.contains("operational=true")}
   let uid=AudioHardwareAccess.string(mixer.output,kAudioDevicePropertyDeviceUID) ?? ""
   record("explicit-route.begin");mixer.setApplicationOutput(uid,pid:pid);record("explicit-route.end",state(pid))
   _=await awaitState("explicit-route",pid:pid){($0["route"] as? String ?? "").contains("ready=true")}
   record("default-route.begin");mixer.setApplicationOutput("",pid:pid);record("default-route.end",state(pid))
   record("sleep.begin");NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.willSleepNotification,object:nil);record("sleep.end",state(pid))
   if mixer.activeRouteCount != 0 {failure=true}
   NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.didWakeNotification,object:nil)
   _=await awaitState("wake",pid:pid){($0["route"] as? String ?? "").contains("ready=true")}
   let expectedListeners=mixer.listenerCount
   for i in 0..<100 {mixer.hidePanel();mixer.showPanel();if mixer.activeRouteCount != 1 || mixer.listenerCount != expectedListeners {failure=true};await Task.yield();record("active-cycle.\(i)",state(pid))}
  }
  record("restore.begin");mixer.restoreApplication(pid);record("restore.end",state(pid));mixer.hidePanel();record("hide",state(pid))
  let resourcesReleased=mixer.activeRouteCount==0 && mixer.listenerCount==0
  if resourcesReleased {
   for i in 0..<100 {record("cycle.\(i).begin");mixer.showPanel();mixer.hidePanel();record("cycle.\(i).end",state(pid));if mixer.listenerCount != 0 || mixer.activeRouteCount != 0 {failure=true;break};await Task.yield()}
  }else{failure=true}
  // Replay a genuine retired HAL block after shutdown while the requested gain
  // is still non-default. Without the generation check this can revive routing.
  mixer.showPanel();mixer.setApplicationVolume(0.5,pid:pid)
  _=await awaitState("last-active",pid:pid){($0["route"] as? String ?? "").contains("ready=true")}
  let captured=Mirror(reflecting:mixer!).children.first{$0.label=="listeners"}?.value as? [(AudioObjectID,AudioObjectPropertyAddress,AudioObjectPropertyListenerBlock)]
  let queue=Mirror(reflecting:mixer!).children.first{$0.label=="listenerQueue"}?.value as? DispatchQueue
  mixer.shutdown();record("shutdown",state(pid))
  if let last=captured?.last,let queue {
   let callback=RetiredCallback(last.1,last.2)
   await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
    queue.async {callback.deliver();continuation.resume()}
   }
   try? await Task.sleep(for:.milliseconds(300))
   if mixer.activeRouteCount != 0 || mixer.listenerCount != 0 {failure=true}
   record("retired-callback.checked",state(pid))
  }else{failure=true;record("retired-callback.fixtureMissing")}
  mixer.shutdown()
  let result:[String:Any]=["status":failure ? "FUNCTIONAL_SCOPE_INCOMPLETE":"PASS_ACTUAL_BACKEND_SCOPE","sourceFile":"actual AudioMixerController + ApplicationAudioRoute","resourcesReleased":mixer.activeRouteCount==0 && mixer.listenerCount==0,"rows":rows.count,"scope":"real private source PID only; route-to-current-output and default; no physical audible-RMS or alternate physical-device claim"]
  try! JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("result.json"))
  exit(failure ? 1 : 0)
 }
 func applicationWillTerminate(_ note:Notification){mixer?.shutdown()}
}

// Test-only transfer of a captured HAL callback to its real registered queue.
// The address lives through the synchronous delivery; no pointer escapes.
private final class RetiredCallback:@unchecked Sendable {
 var address:AudioObjectPropertyAddress
 let block:AudioObjectPropertyListenerBlock
 init(_ address:AudioObjectPropertyAddress,_ block:@escaping AudioObjectPropertyListenerBlock){self.address=address;self.block=block}
 func deliver(){block(1,&address)}
}
