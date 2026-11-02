import AppKit
import IslandCore

// Actual MediaScrubberView is extracted unchanged by the runner. Only its
// services/drawing dependencies are spies: no Apple Events, capture or user data.
@MainActor class FlippedView:NSView { override var isFlipped:Bool {true} }
@MainActor protocol TransientStateResettable:NSView {func resetTransientState()}
@MainActor final class MediaController {
 var nowPlaying:NowPlayingInfo?
 var canSeek=true
 var seeks:[Double]=[]
 func seek(to value:Double){seeks.append(value);nowPlaying?.elapsed=value;nowPlaying?.timestamp=Date()}
}
@MainActor final class TextLabel:FlippedView {
 var naturalWidth:CGFloat {30};var lineHeight:CGFloat{12}
 init(_ text:String,font:NSFont,color:NSColor,alignment:NSTextAlignment = .left){super.init(frame:.zero)}
 required init?(coder:NSCoder){fatalError()}
 func set(_ text:String){}
}
enum Fonts {static var numericSmall:NSFont{.systemFont(ofSize:10)}}
enum Palette {static var tertiary:NSColor{.gray}}
enum Spacing {static let s:CGFloat=8}
@MainActor final class TimeProgressLayerView:FlippedView {
 enum Style {case bar};init(style:Style){super.init(frame:.zero)}
 required init?(coder:NSCoder){fatalError()}
 func configure(timing:TimeProgressView.Timing,tint:NSColor,track:NSColor){}
}
enum TimeProgressView {struct Timing {let progress:Double;let reference:Date;let rate:Double;let isRunning:Bool}}
@MainActor final class SecondTicker {init(fire:@escaping ()->Void){};func set(running:Bool,anchor:Date){};func stop(){}}
@MainActor final class FrameDriver {init(view:NSView,tick:@escaping(Double)->Bool){};func start(){}}
struct Spring {var value:Double;var target:Double;init(_ x:Double){value=x;target=x};var isActive:Bool{false};mutating func step(_ dt:Double){};mutating func set(_ x:Double){value=x;target=x};mutating func animate(to x:Double,spec:Int){target=x}}
enum AppMotion {static let control=0}
@main @MainActor struct Check {
 static func main(){
  _ = NSApplication.shared
  let media=MediaController()
  let initial=NowPlayingInfo(title:"fixture",artist:"",album:"",duration:100,elapsed:0,timestamp:Date(),playbackRate:0,isPlaying:false,artworkData:nil,bundleIdentifier:nil)
  media.nowPlaying=initial
  let view=MediaScrubberView(media:media)
  view.update(info:initial,tint:.white,canSeek:true)
  // No run-loop yield: Observation onChange re-application is asynchronous.
  // A real second AX action must use the latest optimistic model, not the old
  // rendering snapshot while a source reply/observer callback is pending.
  for _ in 0..<12 {precondition(view.accessibilityPerformIncrement())}
  guard media.seeks == [10,20,30,40,50,60,70,80,90,100,100,100] else {
   print("FAIL: rapid native increments reused stale panel info: \(media.seeks)");exit(1)
  }
  for _ in 0..<12 {precondition(view.accessibilityPerformDecrement())}
  guard Array(media.seeks.suffix(12)) == [90,80,70,60,50,40,30,20,10,0,0,0] else {
   print("FAIL: native decrements do not preserve intent/bounds");exit(1)
  }
  guard view.accessibilityValue() as? String == "0:00 / 1:40" else {
   print("FAIL: native accessibility value did not reflect optimistic seek");exit(1)
  }
  media.canSeek=false
  let count=media.seeks.count
  guard !view.accessibilityPerformIncrement(),media.seeks.count==count else{print("FAIL: stale seek eligibility accepted an unavailable source");exit(1)}
  media.canSeek=true;media.nowPlaying=nil
  guard !view.accessibilityPerformDecrement() else{print("FAIL: stale track accepted seek after source ended");exit(1)}
  print("PASS: actual native scrubber retains 24 rapid AX selections, clamps endpoints, publishes immediate AX value and rejects stale source eligibility")
 }
}
