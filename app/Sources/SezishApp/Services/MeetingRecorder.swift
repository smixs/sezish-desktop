import Foundation
import SezishCore

/// Orchestrates a meeting capture: mic stem (own AVAudioEngine instance,
/// independent of the dictation recorder) + system-audio stem (process tap),
/// both spooled to disk, mixed to one mono track on stop.
@MainActor
final class MeetingRecorder {
    enum StartOutcome {
        case full
        /// System-audio tap failed (typically TCC denied): recording continues
        /// with the mic only — a one-sided record beats none.
        case micOnly(Error)
    }

    struct Capture: Sendable {
        let mixed16k: [Float]
        let duration: TimeInterval
        let systemAudioCaptured: Bool
        let tempDir: URL
    }

    enum MeetingRecorderError: Error {
        case notRecording
    }

    private var mic: MicRecorder?
    private var tap: SystemAudioTap?
    private var micStem: MeetingStem?
    private var systemStem: MeetingStem?
    private var tempDir: URL?
    private(set) var startDate: Date?

    var isRecording: Bool { startDate != nil }

    static var meetingsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sezish", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// `pipeline` (optional) gets the same sample streams the stems spool, for
    /// incremental transcription while the recording is still running.
    func start(pipeline: MeetingTranscriptionPipeline? = nil) throws -> StartOutcome {
        guard !isRecording else { return .full }

        let dir = Self.meetingsDirectory
            .appendingPathComponent(".rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let micStem = MeetingStem(
            spool: try PCMSpoolFile(url: dir.appendingPathComponent("mic.wav")), label: "mic"
        )
        let systemStem = MeetingStem(
            spool: try PCMSpoolFile(url: dir.appendingPathComponent("system.wav")), label: "system"
        )

        // Mic first: the user's own voice is the non-negotiable half.
        let mic = MicRecorder(onSamples16k: {
            micStem.ingest($0)
            pipeline?.ingestMic($0)
        })
        do {
            try mic.start()
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }

        var outcome = StartOutcome.full
        let tap = SystemAudioTap(onSamples16k: {
            systemStem.ingest($0)
            pipeline?.ingestSystem($0)
        })
        do {
            try tap.start()
            self.tap = tap
        } catch {
            outcome = .micOnly(error)
            self.tap = nil
            pipeline?.systemStreamUnavailable()
        }

        self.mic = mic
        self.micStem = micStem
        self.systemStem = self.tap != nil ? systemStem : nil
        self.tempDir = dir
        self.startDate = Date()
        return outcome
    }

    func stop() async throws -> Capture {
        guard let startDate, let tempDir, let mic, let micStem else {
            throw MeetingRecorderError.notRecording
        }
        let duration = Date().timeIntervalSince(startDate)
        let systemStem = systemStem
        let systemCaptured = tap != nil

        _ = try? await mic.stop() // streaming mode returns []
        tap?.stop()
        resetState()

        // Finalize + chunked mixdown off the main actor (hundreds of MB for long calls).
        return try await Task.detached(priority: .userInitiated) {
            _ = try micStem.finish()
            _ = try systemStem?.finish()

            let micReader = try PCMSpoolReader(url: tempDir.appendingPathComponent("mic.wav"))
            let systemReader = systemCaptured
                ? try? PCMSpoolReader(url: tempDir.appendingPathComponent("system.wav"))
                : nil

            var mixed: [Float] = []
            mixed.reserveCapacity(max(micReader.frameCount, systemReader?.frameCount ?? 0))
            while true {
                let a = try micReader.readChunk(maxFrames: 65_536)
                let b = try systemReader?.readChunk(maxFrames: 65_536)
                if a == nil, b == nil { break }
                mixed.append(contentsOf: AudioMixdown.mix((a ?? [])[...], (b ?? [])[...]))
            }

            return Capture(
                mixed16k: mixed,
                duration: duration,
                systemAudioCaptured: systemReader != nil,
                tempDir: tempDir
            )
        }.value
    }

    private func resetState() {
        mic = nil
        tap = nil
        micStem = nil
        systemStem = nil
        tempDir = nil
        startDate = nil
    }
}
