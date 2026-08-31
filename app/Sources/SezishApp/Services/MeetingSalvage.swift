import Foundation
import SezishCore

/// Rescues meeting stems orphaned by a crash or a force-quit mid-recording.
///
/// Stems spool to `.rec-<UUID>/{mic,system}.wav` and their WAV sizes are patched
/// only in `finalize()`, so a process that dies mid-call leaves an hour of PCM
/// behind a header claiming "empty". The old launch-time cleaner simply deleted
/// those dirs — the single worst thing to do to a recording the user can never
/// make again. Instead we repair the headers and re-run the very same pipeline a
/// normal meeting takes: mix → encode → transcribe on-device → write .md.
///
/// The filesystem is the queue: a salvage that fails leaves the orphan dir on
/// disk untouched and the next launch tries again. Only proven garbage (not one
/// frame in either stem) is deleted.
nonisolated enum MeetingSalvage {
    enum Outcome: Sendable {
        /// Artifacts written; the orphan dir is gone.
        case recovered(md: URL)
        /// Both stems were empty — nothing to save, dir removed.
        case discarded
        /// Nothing could be written; the dir stays for the next launch.
        case failed
    }

    /// What a retry of stashed stems produced.
    enum RetryOutcome: Sendable {
        /// The .md was rewritten with the recognised text; the stems are gone.
        case retranscribed(md: URL)
        /// Part of the take came out and is in the .md; the rest is still in the
        /// stems, so they stay and the retry can be retried.
        case partial(md: URL)
        /// Silence, not a failure: nothing will ever come out of these stems,
        /// so they are gone too and the .md is left as it was.
        case nothingToRecover
        /// Some or all of the take is still unrecognised; the stems stay.
        case failed
    }

    /// Marks a hidden stems folder; shared with the reader of that folder.
    static let stemsPrefix = ".stems-"

    private static let sampleRate = 16_000
    /// Same chunk size the stop()-time mixdown uses: 128 KB of PCM per read.
    private static let chunkFrames = 65_536

    /// `.rec-*` directories in `meetingsDir`, sorted by name so a batch is
    /// salvaged in a deterministic (and, since names carry no time, at least
    /// stable) order. Empty on any error — discovery must never fail a launch.
    static func discoverOrphans(in meetingsDir: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: meetingsDir.path) else { return [] }
        return entries
            .filter { $0.hasPrefix(".rec-") }
            .sorted()
            .map { meetingsDir.appendingPathComponent($0, isDirectory: true) }
            .filter { url in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
    }

    /// `.stems-*` directories in `meetingsDir`, sorted by name: the takes whose
    /// transcript never came out, kept for a retry. `discoverOrphans` cannot see
    /// them (different prefix), so launch-time salvage leaves them alone.
    static func discoverStems(in meetingsDir: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: meetingsDir.path) else { return [] }
        return entries
            .filter { $0.hasPrefix(stemsPrefix) }
            .sorted()
            .map { meetingsDir.appendingPathComponent($0, isDirectory: true) }
            .filter { url in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
    }

    /// Parks a meeting's stems next to the meeting itself, hidden, so a retry has
    /// audio to read. A move on the same volume, so an hour of PCM costs nothing.
    /// A caller whose move fails must delete the spool dir: the audio and the .md
    /// are already on disk, and a stray `.rec-` dir becomes a second meeting on
    /// the next launch.
    static func stash(stems tempDir: URL, base: String, in meetingsDir: URL) throws -> URL {
        let destination = meetingsDir.appendingPathComponent(stemsPrefix + base, isDirectory: true)
        try FileManager.default.moveItem(at: tempDir, to: destination)
        return destination
    }

    /// Every artifact a meeting can leave under one base name, including the
    /// stems of a take waiting for a retry. Both writers of a meeting name ask
    /// this, so the two never disagree about what counts as taken.
    static func nameIsTaken(_ name: String, in meetingsDir: URL) -> Bool {
        let fm = FileManager.default
        return ["\(name).m4a", "\(name).md", "\(name).wav", stemsPrefix + name].contains {
            fm.fileExists(atPath: meetingsDir.appendingPathComponent($0).path)
        }
    }

    /// Turns one orphan dir into the artifacts a finished meeting produces.
    /// Best-effort throughout: every step swallows its own errors, because a
    /// half-salvaged meeting still beats a deleted one.
    static func salvage(
        orphan: URL,
        meetingsDir: URL,
        transcriber: (any Transcriber)?,
        strings: Strings,
        language: AppLanguage
    ) async -> Outcome {
        let fm = FileManager.default
        let micURL = orphan.appendingPathComponent("mic.wav")
        let systemURL = orphan.appendingPathComponent("system.wav")

        // Rebuild the sizes finalize() never got to write. A stem we cannot read
        // at all counts as no frames, but it is remembered: the take is then kept
        // for a retry instead of being called empty.
        let micCount = stemFrames(at: micURL)
        let systemCount = stemFrames(at: systemURL)
        var readFailed = micCount == nil || systemCount == nil
        let micFrames = micCount ?? 0
        let systemFrames = systemCount ?? 0

        guard micFrames > 0 || systemFrames > 0 || readFailed else {
            // Proven garbage: a start() that died before the first buffer, or a
            // dir holding nothing of ours. Same net effect as the old cleaner —
            // but only for the case where there is demonstrably nothing to lose.
            try? fm.removeItem(at: orphan)
            return .discarded
        }

        let duration = Double(max(micFrames, systemFrames)) / Double(sampleRate)
        // The stem files were created when the recording started, so the disk
        // remembers the meeting's clock even though the app's memory is gone.
        let startedAt = creationDate(of: micURL)
            ?? creationDate(of: systemURL)
            ?? Date().addingTimeInterval(-duration)

        var mixed: [Float] = []
        mixed.reserveCapacity(max(micFrames, systemFrames))
        do {
            let micReader = micFrames > 0 ? try PCMSpoolReader(url: micURL) : nil
            let systemReader = systemFrames > 0 ? try PCMSpoolReader(url: systemURL) : nil
            while true {
                let a = try micReader?.readChunk(maxFrames: chunkFrames)
                let b = try systemReader?.readChunk(maxFrames: chunkFrames)
                if a == nil, b == nil { break }
                mixed.append(contentsOf: AudioMixdown.mix((a ?? [])[...], (b ?? [])[...]))
            }
        } catch {
            // Keep whatever was read before the stem turned unreadable.
        }

        let base = MeetingFileNamer.uniqueBaseName(for: startedAt) {
            nameIsTaken($0, in: meetingsDir)
        }

        // Audio FIRST: once the take is on disk nothing later can lose it.
        var audioName = base + ".m4a"
        do {
            try await M4AWriter.write(
                samples16k: mixed, to: meetingsDir.appendingPathComponent(audioName)
            )
        } catch {
            // Fallback: raw WAV — bigger, but the take is never lost. No actor
            // hop needed, unlike the live path: salvage is already nonisolated.
            audioName = base + ".wav"
            do {
                let spool = try PCMSpoolFile(url: meetingsDir.appendingPathComponent(audioName))
                try spool.append(mixed)
                try spool.finalize()
            } catch {
                // Not one byte of audio landed: leave the orphan alone and let
                // the next launch retry rather than destroy the only copy.
                return .failed
            }
        }

        var transcript: String?
        var failedChunks = 0
        if let transcriber {
            let result = await transcribe(
                transcriber: transcriber,
                micURL: micFrames > 0 ? micURL : nil,
                systemURL: systemFrames > 0 ? systemURL : nil,
                strings: strings
            )
            transcript = result.text
            failedChunks = result.failedChunks
            readFailed = readFailed || result.readFailed
        }

        let markdown = AppState.meetingMarkdown(
            strings: strings,
            language: language,
            date: startedAt,
            duration: duration,
            audioFile: audioName,
            transcript: transcript,
            recovered: true
        )
        let mdURL = meetingsDir.appendingPathComponent(base + ".md")
        try? markdown.write(to: mdURL, atomically: true, encoding: .utf8)

        // Only now, with the artifacts on disk, is the spool expendable, and
        // only if there is nothing left to recognise. No model on disk yet, a
        // transcript with holes, or a stem we could not read to the end: each
        // means this take still has text in it.
        if transcriber == nil || failedChunks > 0 || readFailed {
            if (try? stash(stems: orphan, base: base, in: meetingsDir)) == nil {
                try? fm.removeItem(at: orphan)
            }
        } else {
            try? fm.removeItem(at: orphan)
        }
        return .recovered(md: mdURL)
    }

    /// Recognises stashed stems again and rewrites the meeting's .md with what
    /// comes out. The stems survive anything short of a clean full transcript:
    /// the whole point of keeping them is that a retry can be retried.
    static func retranscribe(
        stems: URL,
        meetingsDir: URL,
        transcriber: any Transcriber,
        strings: Strings,
        language: AppLanguage
    ) async -> RetryOutcome {
        let fm = FileManager.default
        let base = String(stems.lastPathComponent.dropFirst(stemsPrefix.count))
        let micURL = stems.appendingPathComponent("mic.wav")
        let systemURL = stems.appendingPathComponent("system.wav")
        // Unreadable is not empty: the broken stem counts as no frames, the other
        // one is still recognised, and the lost audio keeps the stems on disk.
        let micCount = stemFrames(at: micURL)
        let systemCount = stemFrames(at: systemURL)
        var readFailed = micCount == nil || systemCount == nil
        let micFrames = micCount ?? 0
        let systemFrames = systemCount ?? 0

        guard micFrames > 0 || systemFrames > 0 else {
            // Both stems unreadable: nothing to work with, but nothing to delete
            // either. Only a confirmed zero on both is silence.
            if readFailed { return .failed }
            try? fm.removeItem(at: stems)
            return .nothingToRecover
        }

        let (text, failedChunks, playbackReadFailed) = await transcribe(
            transcriber: transcriber,
            micURL: micFrames > 0 ? micURL : nil,
            systemURL: systemFrames > 0 ? systemURL : nil,
            strings: strings
        )
        readFailed = readFailed || playbackReadFailed
        guard let text else {
            // Nothing failed and still no text: the take is silence, and offering
            // it for a retry forever would be the bug. Anything else keeps it.
            if failedChunks == 0, !readFailed {
                try? fm.removeItem(at: stems)
                return .nothingToRecover
            }
            return .failed
        }

        let duration = Double(max(micFrames, systemFrames)) / Double(sampleRate)
        // moveItem keeps the creation date, so the stems still remember when the
        // meeting started even though the app has long forgotten.
        let startedAt = creationDate(of: micURL)
            ?? creationDate(of: systemURL)
            ?? Date().addingTimeInterval(-duration)
        let audioName = fm.fileExists(atPath: meetingsDir.appendingPathComponent(base + ".m4a").path)
            ? base + ".m4a"
            : base + ".wav"

        let markdown = AppState.meetingMarkdown(
            strings: strings,
            language: language,
            date: startedAt,
            duration: duration,
            audioFile: audioName,
            transcript: text,
            recovered: false
        )
        let mdURL = meetingsDir.appendingPathComponent(base + ".md")
        do {
            try markdown.write(to: mdURL, atomically: true, encoding: .utf8)
        } catch {
            return .failed
        }

        // Holes left in the transcript, or audio we never got to the end of: the
        // text is worth writing down, but the stems must stay so the rest can
        // still be filled in later.
        guard failedChunks == 0, !readFailed else { return .partial(md: mdURL) }
        try? fm.removeItem(at: stems)
        return .retranscribed(md: mdURL)
    }

    /// Replays the stems through the live pipeline offline. nil text is not an
    /// error by itself: the meeting is already saved, it just has no words yet.
    /// The two counters tell silence apart from audio that never reached the
    /// model: `failedChunks` is lost inference, `readFailed` is lost audio.
    static func transcribe(
        transcriber: any Transcriber, micURL: URL?, systemURL: URL?, strings: Strings
    ) async -> (text: String?, failedChunks: Int, readFailed: Bool) {
        var readFailed = false
        var micReader: PCMSpoolReader?
        var systemReader: PCMSpoolReader?
        do {
            micReader = try micURL.map { try PCMSpoolReader(url: $0) }
            systemReader = try systemURL.map { try PCMSpoolReader(url: $0) }
        } catch {
            readFailed = true
        }
        // A mic-only recording still has a system.wav, it is just an empty
        // header. Frames, not the file, decide whether there is a second party.
        let hasSystemStream = (systemReader?.frameCount ?? 0) > 0
        let pipeline = MeetingTranscriptionPipeline(
            transcriber: transcriber, hasSystemStream: hasSystemStream
        )
        do {
            // Alternate the stems chunk by chunk, the way the realtime taps feed
            // them: the pipeline's mixer drains each matched pair immediately,
            // so an hour-long call never materializes in RAM.
            while true {
                let a = try micReader?.readChunk(maxFrames: chunkFrames)
                let b = hasSystemStream ? try systemReader?.readChunk(maxFrames: chunkFrames) : nil
                if a == nil, b == nil { break }
                if let a { pipeline.ingestMic(a) }
                if let b { pipeline.ingestSystem(b) }
            }
        } catch {
            // Transcribe what was fed before the read failed, and say that the
            // rest of the audio never made it to the model.
            readFailed = true
        }
        let text = TranscriptSegment.render(
            await pipeline.finish(),
            meLabel: strings.meetingSpeakerMe,
            themLabel: strings.meetingSpeakerThem
        )
        return (text, pipeline.failedChunkCount, readFailed)
    }

    /// Frames in a stem: 0 for a stem that is simply not there, nil when the file
    /// exists but cannot be read at all. `repairHeader` needs write access, so a
    /// read-only stem falls through to the reader rather than counting as empty.
    private static func stemFrames(at url: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        if let repaired = PCMSpoolFile.repairHeader(url: url) { return repaired }
        return (try? PCMSpoolReader(url: url))?.frameCount
    }

    private static func creationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }
}
