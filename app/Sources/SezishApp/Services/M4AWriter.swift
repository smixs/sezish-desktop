@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// AAC .m4a writer with an honoured bit rate: `AVAudioFile` ignores
/// `AVEncoderBitRateKey` (writes ~208 kbps regardless — see CloudTranscriber),
/// so encode through AVAssetWriter instead. 48 kbps mono ≈ 21 MB/hour.
enum M4AWriter {
    enum M4AWriterError: LocalizedError {
        case setupFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .setupFailed: "m4a writer setup failed"
            case .writeFailed(let message): "m4a write failed: \(message)"
            }
        }
    }

    nonisolated static func write(
        samples16k: [Float], to url: URL, bitRate: Int = 48_000
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else {
            throw M4AWriterError.writeFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else { throw M4AWriterError.setupFailed }

        let chunkFrames = 32_768
        var offset = 0
        while offset < samples16k.count {
            let count = min(chunkFrames, samples16k.count - offset)
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let buffer = try makeSampleBuffer(
                samples16k[offset..<(offset + count)],
                atFrame: offset,
                format: formatDescription
            )
            input.append(buffer)
            offset += count
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw M4AWriterError.writeFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    private nonisolated static func makeSampleBuffer(
        _ samples: ArraySlice<Float>, atFrame frameOffset: Int, format: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        let byteCount = samples.count * MemoryLayout<Float>.size

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer
        )
        guard let blockBuffer else { throw M4AWriterError.setupFailed }
        let copyStatus = samples.withUnsafeBufferPointer { pointer in
            CMBlockBufferReplaceDataBytes(
                with: pointer.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: byteCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { throw M4AWriterError.setupFailed }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 16_000),
            presentationTimeStamp: CMTime(value: CMTimeValue(frameOffset), timescale: 16_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: format, sampleCount: samples.count,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw M4AWriterError.setupFailed }
        return sampleBuffer
    }
}
