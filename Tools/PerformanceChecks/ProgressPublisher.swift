import Foundation

// A separate process is needed to verify NSProgress's real publisher/subscriber transport.
let progress = Progress(totalUnitCount: 100)
progress.kind = .file
progress.fileURL = URL(fileURLWithPath: CommandLine.arguments[1])
progress.completedUnitCount = 25
progress.publish()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
progress.completedUnitCount = 100
RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
progress.unpublish()
