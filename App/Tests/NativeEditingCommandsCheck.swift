import AppKit

/// Cocoa menu routing/undo contract. Not physical keyboard or VoiceOver proof.
@MainActor private final class EditingPanel:NSPanel { override var canBecomeKey:Bool {true}
 override func sendEvent(_ event:NSEvent) {
  if NativeEditingCommands.route(event,in:self){return};super.sendEvent(event)
 }
}
@main @MainActor final class EditingCheck:NSObject,NSApplicationDelegate {
 static var retained:EditingCheck?
 var nonEditingCalls=0
 @objc func nonEditingCommand(_ sender:Any?){nonEditingCalls += 1}
 static func main(){let app=NSApplication.shared;app.setActivationPolicy(.accessory);let d=EditingCheck();retained=d;app.delegate=d;app.run()}
 func applicationDidFinishLaunching(_ n:Notification){
  let w=EditingPanel(contentRect:CGRect(x:40,y:70,width:260,height:90),styleMask:[.nonactivatingPanel,.borderless],backing:.buffered,defer:false)
  w.isReleasedWhenClosed=false;w.ignoresMouseEvents=true
  let editor=NSTextView(frame:CGRect(x:0,y:0,width:260,height:90));editor.allowsUndo=true;editor.string="Private fixture"
  w.contentView=editor;w.makeKeyAndOrderFront(nil);w.makeFirstResponder(editor)
  // Services/AppKit can install a menu before the delegate. Preserve it and
  // still supply missing native edit commands.
  let existing=NSMenu();existing.addItem(NSMenuItem(title:"Existing fixture",action:nil,keyEquivalent:""))
  let other=existing.addItem(withTitle:"Unrelated fixture command",action:#selector(nonEditingCommand(_:)),keyEquivalent:"k")
  other.target=self
  NSApp.mainMenu=existing
  NativeEditingCommands.install()
  let installedCount=existing.items.count
  for _ in 0..<100 {NativeEditingCommands.install()}
  guard existing.items.count==installedCount else{print("FAIL: repeated install duplicated commands");exit(1)}
  guard NSApp.mainMenu === existing else{print("FAIL: existing menu replaced");exit(1)}
  editor.setSelectedRange(NSRange(location:7,length:0));editor.insertText("Z",replacementRange:editor.selectedRange())
  guard editor.string=="PrivateZ fixture",editor.undoManager?.canUndo==true else{print("FAIL: fixture has no undo");exit(1)}
  func event(_ shift:Bool)->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:shift ? [.command,.shift]:[.command],timestamp:0,windowNumber:w.windowNumber,context:nil,characters:shift ? "Z":"z",charactersIgnoringModifiers:shift ? "Z":"z",isARepeat:false,keyCode:6)!}
  let otherEvent=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.command],timestamp:0,windowNumber:w.windowNumber,context:nil,characters:"k",charactersIgnoringModifiers:"k",isARepeat:false,keyCode:40)!
  guard !NativeEditingCommands.route(otherEvent,in:w),nonEditingCalls==0 else{print("FAIL: edit fallback intercepted an unrelated command");exit(1)}
  w.sendEvent(event(false));let handled=editor.string=="Private fixture"
  guard handled,editor.string=="Private fixture" else{print("FAIL: native undo menu did not route to text responder");exit(1)}
  w.sendEvent(event(true));let redone=editor.string=="PrivateZ fixture"
  guard redone,editor.string=="PrivateZ fixture" else{print("FAIL: native redo menu did not route");exit(1)}
  w.close();print("PASS: native menu command-Z/shift-command-Z undo and redo through Cocoa responder chain")
  exit(0)
 }
}
