import AVFoundation
import Foundation
import SezishCore

public enum CloudTranscriberError: LocalizedError {
    case badResponse(Int, String)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code, let body):
            return "Облачный сервер ответил \(code): \(body)"
        case .encodingFailed(let reason):
            return "Не удалось закодировать аудио: \(reason)"
        }
    }
}

/// Sends 16 kHz mono PCM to the sezish cloud endpoint (asr.sezi.sh) and returns the transcript.
/// A drop-in `Transcriber` alternative to the local `GigaAmTranscriber` — no model on disk.
public struct CloudTranscriber: Transcriber {
    private let endpoint: URL
    private let apiKey: String

    public init(endpoint: URL, apiKey: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
    }

    /// Opens the TLS connection to the ASR host while recording is
    /// still in progress. The GET returns instantly without running inference — the point
    /// is the side effect: a pooled keep-alive connection for the POST that follows.
    public func warmup() async {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        _ = try? await URLSession.shared.data(for: request)
    }

    public func transcribe(_ samples16k: [Float]) async throws -> String {
        guard !samples16k.isEmpty else { return "" }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("audio/aac", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = try Self.aacData(samples16k)
        request.timeoutInterval = Self.timeout(forSampleCount: samples16k.count)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw CloudTranscriberError.badResponse(
                status, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }

        struct Reply: Decodable { let text: String }
        return try JSONDecoder().decode(Reply.self, from: data).text
    }

    /// `timeoutInterval` is an *idle* timer: it ticks while no bytes flow, i.e.
    /// during server-side inference (upload keeps the connection busy). The h1
    /// CPU transcribes at ≈4× realtime, so the timeout must scale with clip
    /// length — the fixed 120 s killed every meeting longer than ~8 minutes.
    static func timeout(forSampleCount count: Int) -> TimeInterval {
        let duration = TimeInterval(count) / 16_000
        return max(120, 60 + duration * 0.35)
    }

    /// Encodes float samples as 32 kbps mono AAC in an ADTS stream (.aac) — ~8× smaller
    /// than WAV, which is most of the perceived upload latency on a slow uplink.
    /// AVAudioConverter is used directly because AVAudioFile ignores bitrate settings
    /// (writes ~208 kbps regardless of AVEncoderBitRateKey — measured, not documented).
    static func aacData(_ samples16k: [Float]) throws -> Data {
        let inFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        var desc = AudioStreamBasicDescription()
        desc.mSampleRate = 16_000
        desc.mFormatID = kAudioFormatMPEG4AAC
        desc.mChannelsPerFrame = 1
        desc.mFramesPerPacket = 1024
        guard let outFormat = AVAudioFormat(streamDescription: &desc),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw CloudTranscriberError.encodingFailed("AVAudioConverter init")
        }
        converter.bitRate = 32_000

        let pcm = AVAudioPCMBuffer(
            pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples16k.count))!
        pcm.frameLength = AVAudioFrameCount(samples16k.count)
        samples16k.withUnsafeBufferPointer { src in
            pcm.floatChannelData![0].update(from: src.baseAddress!, count: samples16k.count)
        }

        var fed = false
        var out = Data()
        while true {
            let buffer = AVAudioCompressedBuffer(
                format: outFormat, packetCapacity: 64,
                maximumPacketSize: converter.maximumOutputPacketSize)
            var convertError: NSError?
            let status = converter.convert(to: buffer, error: &convertError) { _, outStatus in
                if fed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return pcm
            }
            if status == .error {
                throw CloudTranscriberError.encodingFailed(
                    convertError?.localizedDescription ?? "convert")
            }
            if let packets = buffer.packetDescriptions {
                for i in 0..<Int(buffer.packetCount) {
                    let packet = packets[i]
                    out.append(Self.adtsHeader(payloadSize: Int(packet.mDataByteSize)))
                    out.append(Data(
                        bytes: buffer.data.advanced(by: Int(packet.mStartOffset)),
                        count: Int(packet.mDataByteSize)))
                }
            }
            if status == .endOfStream || buffer.packetCount == 0 { break }
        }
        return out
    }

    /// 7-byte ADTS header: AAC-LC, 16 kHz (sampling index 8), mono, no CRC.
    private static func adtsHeader(payloadSize: Int) -> Data {
        let frameLength = payloadSize + 7
        return Data([
            0xFF, 0xF1,
            UInt8((1 << 6) | (8 << 2)),                     // AAC-LC, sfi=8
            UInt8((1 << 6) | ((frameLength >> 11) & 0x03)), // mono, len high bits
            UInt8((frameLength >> 3) & 0xFF),
            UInt8(((frameLength & 0x07) << 5) | 0x1F),
            0xFC,
        ])
    }
}
