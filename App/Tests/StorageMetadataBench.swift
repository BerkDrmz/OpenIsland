// Actual baseline and candidate StorageVolume.read(), compiled into one process.
// Read-only system volume metadata; this is not a tab/GPU/battery benchmark.
import Foundation
import Darwin
@main struct StorageMetadataBench {
    static func cpuSeconds() -> Double {
        var r = rusage(); precondition(getrusage(RUSAGE_SELF, &r) == 0)
        return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
    }
    static func main() throws {
        let a = BaselineStorageVolume.read(), b = StorageVolume.read()
        precondition(a.map(\.id) == b.map(\.id))
        for (x,y) in zip(a,b) {
            precondition(x.name == y.name && x.total == y.total && x.isInternal == y.isInternal)
            precondition(y.available >= 0 && y.available <= y.total)
        }
        var runs: [[String:Any]] = []
        for block in 1...3 {
            for variant in ["A", "B", "B", "A"] {
                let before = cpuSeconds(), t0 = DispatchTime.now().uptimeNanoseconds
                let n = 8
                var count = 0
                for _ in 0..<n {
                    count += autoreleasepool { variant == "A" ? BaselineStorageVolume.read().count : StorageVolume.read().count }
                }
                let wall = Double(DispatchTime.now().uptimeNanoseconds - t0)/1e6
                let cpu = (cpuSeconds() - before)*1000
                let row: [String:Any] = ["block":block,"variant":variant,"reads":n,"returnedVolumes":count,
                    "cpuMSPerRead":cpu/Double(n),"wallMSPerRead":wall/Double(n)]
                runs.append(row)
            }
        }
        let data = try JSONSerialization.data(withJSONObject:["runs":runs,"identityTotalNameInternalEqual":true,"volumeCount":a.count,
            "scope":"Read-only metadata operation only. No claim about tabs, GPU, WindowServer, or battery."], options:[.prettyPrinted,.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
}
