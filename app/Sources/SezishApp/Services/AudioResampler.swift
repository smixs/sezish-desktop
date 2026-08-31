@preconcurrency import AVFoundation
import Foundation

/// Shared 16 kHz mono resampler used by the mic recorder and the system tap.
/// Called from realtime audio threads: single pass, no allocations beyond the
/// converter's own buffers.
enum AudioResampler {
    nonisolated static func resample(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> [Float] {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }

        // The converter pulls input synchronously inside `convert`; feed the buffer once.
        nonisolated(unsafe) var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status == .haveData || status == .inputRanDry,
              output.frameLength > 0,
              let channel = output.floatChannelData
        else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
