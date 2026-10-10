import Accelerate
import CoreAudio

/// Float32 stereo: interleaved/planar arasında allocation olmadan kanal bazında aktarır.
/// Aggregate'in fiziksel girişleri varsa tap en sondadır; mikrofon verileri kullanılmaz.
enum AudioGainProcessor {
    /// Startup only: distinguish a usable tap from permission-denied zero buffers.
    /// Silence alone is not proof of denied permission, so callers report either
    /// unavailable audio or access, and keep the original sound path untouched.
    static func containsSignal(input: UnsafePointer<AudioBufferList>) -> Bool {
        let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let last = sources.last else { return false }
        let count = last.mNumberChannels == 2 ? 1 : 2
        for source in sources.suffix(count) {
            guard let data = source.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<min(Int(source.mDataByteSize) / MemoryLayout<Float>.size, 64) {
                if samples[index].isFinite && samples[index] != 0 { return true }
            }
        }
        return false
    }

    static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                       from oldGain: Float, to gain: Float) {
        let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let targets = UnsafeMutableAudioBufferListPointer(output)
        // Valid, full stereo buffers are completely overwritten below. Clearing them
        // first doubled output writes on every realtime callback. Keep the clear for
        // missing/short inputs, extra channels or partial samples so no stale audio leaks.
        if !fullyOverwritesOutput(sources: sources, targets: targets) {
            for target in targets { if let data = target.mData { memset(data, 0, Int(target.mDataByteSize)) } }
        }
        guard let last = sources.last else { return }
        let inputInterleaved = last.mNumberChannels == 2
        guard inputInterleaved || (sources.count >= 2 && last.mNumberChannels == 1 && sources[sources.count - 2].mNumberChannels == 1) else { return }
        let outputInterleaved = targets.count == 1 && targets[0].mNumberChannels == 2
        guard outputInterleaved || (targets.count >= 2 && targets[0].mNumberChannels == 1 && targets[1].mNumberChannels == 1) else { return }
        for channel in 0..<2 {
            let source = sources[inputInterleaved ? sources.count - 1 : sources.count - 2 + channel]
            let target = targets[outputInterleaved ? 0 : channel]
            guard let sourceData = source.mData, let targetData = target.mData else { continue }
            let sourceStride = inputInterleaved ? 2 : 1
            let targetStride = outputInterleaved ? 2 : 1
            let count = min(Int(source.mDataByteSize) / (4 * sourceStride), Int(target.mDataByteSize) / (4 * targetStride))
            let sourcePointer = sourceData.assumingMemoryBound(to: Float.self).advanced(by: inputInterleaved ? channel : 0)
            let targetPointer = targetData.assumingMemoryBound(to: Float.self).advanced(by: outputInterleaved ? channel : 0)
            // Slider hareketinde patlama/tık olmaması için en fazla 128 örneklik gain rampası.
            let ramp = oldGain == gain ? 0 : min(count, 128)
            for index in 0..<ramp {
                let value = oldGain + (gain - oldGain) * Float(index + 1) / Float(ramp)
                targetPointer[index * targetStride] = sourcePointer[index * sourceStride] * value
            }
            if count > ramp {
                var value = gain
                vDSP_vsmul(sourcePointer.advanced(by: ramp * sourceStride), vDSP_Stride(sourceStride), &value,
                           targetPointer.advanced(by: ramp * targetStride), vDSP_Stride(targetStride), vDSP_Length(count - ramp))
            }
        }
    }

    private static func fullyOverwritesOutput(sources: UnsafeMutableAudioBufferListPointer,
                                             targets: UnsafeMutableAudioBufferListPointer) -> Bool {
        guard let last = sources.last else { return false }
        let inputInterleaved = last.mNumberChannels == 2
        guard inputInterleaved || (sources.count >= 2 && last.mNumberChannels == 1
            && sources[sources.count - 2].mNumberChannels == 1) else { return false }
        let outputInterleaved = targets.count == 1 && targets[0].mNumberChannels == 2
        guard outputInterleaved || (targets.count == 2 && targets[0].mNumberChannels == 1
            && targets[1].mNumberChannels == 1) else { return false }
        for channel in 0..<2 {
            let source = sources[inputInterleaved ? sources.count - 1 : sources.count - 2 + channel]
            let target = targets[outputInterleaved ? 0 : channel]
            let inputFrameBytes = UInt32(MemoryLayout<Float>.size * (inputInterleaved ? 2 : 1))
            let outputFrameBytes = UInt32(MemoryLayout<Float>.size * (outputInterleaved ? 2 : 1))
            guard source.mData != nil, target.mData != nil,
                  target.mDataByteSize % outputFrameBytes == 0,
                  source.mDataByteSize / inputFrameBytes >= target.mDataByteSize / outputFrameBytes else { return false }
        }
        return true
    }
}
