import Foundation
import SezishAsr
import SezishCore

/// Meeting recording lifecycle for `AppState`. Split out like AppState+Model to
/// keep the state file on UI/hotkey wiring.
extension AppState {
    enum MeetingStartSource {
        case manual
        case auto(bundleID: String?)
    }

    /// The detector polls only while the toggle is on; its callbacks re-check the
    /// gate anyway, so a stale tick can never start a recording.
    func installMeetingDetector() {
        let detector = MeetingDetector(policy: MeetingDetectionPolicy(
            ownBundleID: Bundle.main.bundleIdentifier ?? "com.smixs.sezish",
            extraDenyPrefixes: settings.extraDenyApps
        ))
        detector.onMeetingStart = { [weak self] bundleID in
            guard let self, self.autoRecordMeetings, self.status == .idle else { return }
            self.startMeetingRecording(source: .auto(bundleID: bundleID))
        }
        detector.onMeetingEnd = { [weak self] in
            guard let self, self.meetingWasAutoStarted else { return }
            self.stopMeetingRecording()
        }
        meetingDetector = detector
        if autoRecordMeetings { detector.start() }
    }

    func setAutoRecordMeetings(_ enabled: Bool) {
        autoRecordMeetings = enabled
        settings.autoRecordMeetings = enabled
        if enabled {
            meetingDetector?.start()
        } else {
            meetingDetector?.stop()
        }
    }

    func startMeetingRecording(source: MeetingStartSource) {
        guard status == .idle else { return }
        let pipeline = makeMeetingTranscriptionPipeline()
        do {
            let outcome = try meetingRecorder.start(pipeline: pipeline)
            meetingTranscription = pipeline
            if case .auto = source {
                meetingWasAutoStarted = true
            } else {
                meetingWasAutoStarted = false
            }
            if case .micOnly = outcome {
                notifier.notify(title: "sezish", body: strings.notifSystemAudioDenied)
            }
            status = .recordingMeeting
            meetingStartDate = meetingRecorder.startDate
            if soundsEnabled { sounds.play(.meeting) }

            let auto: Bool = if case .auto = source { true } else { false }
            recordingPanel.show(
                startDate: meetingRecorder.startDate ?? Date(),
                auto: auto,
                strings: strings,
                onStop: { [weak self] in self?.stopMeetingRecording() },
                onHide: { [weak self] in self?.recordingPanel.hide() }
            )
        } catch {
            pipeline?.cancel()
            notifier.notify(title: "sezish", body: strings.notifRecordFailed)
        }
    }

    /// Meetings transcribe with the LOCAL model, PERIOD — never the cloud:
    /// an hour of audio would monopolize the shared ASR server for minutes
    /// (h1 runs at ≈4× realtime), and call audio is the most sensitive data
    /// the app touches. Chunked live during the recording, so the transcript
    /// lands seconds after the call ends. Returns nil when the model is not
    /// on disk — the meeting is then saved without a transcript and the user
    /// is pointed at the model download.
    private func makeMeetingTranscriptionPipeline() -> MeetingTranscriptionPipeline? {
        guard let transcriber = meetingSalvageTranscriber() else { return nil }
        return MeetingTranscriptionPipeline(transcriber: transcriber)
    }

    /// The one place the local meeting transcriber is resolved and cached, so
    /// the live pipeline and the crash-salvage path always share one instance.
    /// Loading is lazy: nil means the model is simply not on disk.
    func meetingSalvageTranscriber() -> (any Transcriber)? {
        if meetingLocalTranscriber == nil {
            // In local dictation mode the loaded model is shared, never loaded twice.
            if settings.effectiveTranscriptionMode == .local, let activeTranscriber {
                meetingLocalTranscriber = activeTranscriber
            } else {
                meetingLocalTranscriber = loadLocalTranscriber()
            }
        }
        return meetingLocalTranscriber
    }

    /// Stems left behind by a crash or a force-quit mid-meeting are re-run
    /// through the normal pipeline instead of deleted — an hour-long call the
    /// user can never make again must survive the app dying.
    ///
    /// Discovery is deliberately synchronous inside `init`: a meeting started
    /// later creates its own `.rec-` dir, and it must never end up in this list.
    func salvageOrphanedMeetingsAtLaunch() {
        let dir = MeetingRecorder.meetingsDirectory
        let orphans = MeetingSalvage.discoverOrphans(in: dir)
        guard !orphans.isEmpty else { return }

        let context = MeetingFinishContext(self)
        let strings = strings
        let language = language
        // Loading the local model takes seconds on the main actor, but this
        // branch runs only on the rare launch right after a crash — and doing it
        // here keeps the cached instance shared with the live pipeline.
        let transcriber = meetingSalvageTranscriber()
        // The detached task must not reach back into AppState (Swift 6), so the
        // refresh comes back through a main-actor closure instead of `self`.
        let finish: @MainActor () -> Void = { [weak self] in
            self?.pendingMeetings = MeetingSalvage.discoverStems(in: dir)
        }

        Task.detached(priority: .utility) {
            // Strictly sequential: encoding plus on-device inference for one
            // meeting at a time, so a folder full of orphans cannot swamp the
            // machine the user just booted.
            for orphan in orphans {
                let outcome = await MeetingSalvage.salvage(
                    orphan: orphan,
                    meetingsDir: dir,
                    transcriber: transcriber,
                    strings: strings,
                    language: language
                )
                if case .recovered(let md) = outcome {
                    await Self.finishRecoveredMeeting(
                        md: md, body: strings.notifMeetingRecovered, context: context
                    )
                }
            }
            // Salvage parks the stems of anything it could not fully recognise.
            await finish()
        }
    }

    /// Everything a detached meeting task needs from `AppState`, read once on the
    /// main actor: the task must never reach back for any of it (Swift 6).
    struct MeetingFinishContext: Sendable {
        let strings: Strings
        let language: AppLanguage
        let notifier: Notifier
        let hookCommand: String?
        let summaryEnabled: Bool
        let summaryEngine: SummaryEngineKind
        let notesFolder: URL?

        init(_ state: AppState) {
            strings = state.strings
            language = state.language
            notifier = state.notifier
            hookCommand = state.settings.meetingHook
            summaryEnabled = state.settings.summaryEnabled
            summaryEngine = state.settings.summaryEngine
            notesFolder = AppState.vaultURL(state.settings.notesFolder)
        }
    }

    /// Hook, banner and summary for a meeting whose transcript arrived late — a
    /// crash salvage or a retry. A late meeting is still a finished meeting, so
    /// the automation chained after it must run for these too.
    ///
    /// Summarized in the caller's loop, not detached from it: that task is
    /// already off the main actor and already sequential, and one agent at a time
    /// is the point. The banner goes out first so a ten-minute summary cannot sit
    /// on the news that the recording survived. No transcript check here — a
    /// salvaged meeting may have none, and that is exactly the case the runner's
    /// own guard covers.
    nonisolated static func finishRecoveredMeeting(
        md: URL, body: String, context: MeetingFinishContext
    ) async {
        MeetingHook.fire(command: context.hookCommand, mdURL: md)
        await MainActor.run { context.notifier.notify(title: "sezish", body: body) }

        guard context.summaryEnabled, let notesFolder = context.notesFolder else { return }
        let summary = await SummaryRunner().summarize(
            meetingMd: md, notesFolder: notesFolder,
            engine: context.summaryEngine, language: context.language
        )
        if let banner = Self.summaryNotification(summary, strings: context.strings) {
            await MainActor.run { context.notifier.notify(title: "sezish", body: banner) }
        }
    }

    /// Recognises the stems of meetings that never got a transcript, one meeting
    /// at a time. `only` is a stems directory out of `pendingMeetings` — a `.md`
    /// URL is rejected, not silently retried; nil takes the whole list.
    ///
    /// Starting a new meeting during a retry is deliberately not blocked: the
    /// model is an actor, so the live pipeline just queues behind this one.
    func retryPendingMeetings(only target: URL? = nil) {
        guard !isRetryingMeetings, status == .idle else { return }
        if let target, !target.lastPathComponent.hasPrefix(MeetingSalvage.stemsPrefix) { return }
        let targets = target.map { [$0] } ?? pendingMeetings
        guard !targets.isEmpty else { return }
        // Raised before the model is touched: loading it takes seconds, and the
        // row must spin through them instead of the menu freezing.
        isRetryingMeetings = true

        let dir = MeetingRecorder.meetingsDirectory
        let context = MeetingFinishContext(self)
        let strings = strings
        let language = language
        let notifier = notifier
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.pendingMeetings = MeetingSalvage.discoverStems(in: dir)
            self.refreshMeetings()
            self.retryingMeeting = nil
            self.isRetryingMeetings = false
        }
        // Same shape as `finish`: the detached loop reports which meeting it is
        // on without ever touching `self` (Swift 6).
        let markCurrent: @MainActor (URL?) -> Void = { [weak self] stems in
            self?.retryingMeeting = stems
        }

        Task {
            guard let transcriber = self.meetingSalvageTranscriber() else {
                self.notifier.notify(title: "sezish", body: self.strings.notifModelMissing)
                self.isRetryingMeetings = false
                return
            }
            // Off the main actor from here: an hour of inference must not sit on the UI.
            Task.detached(priority: .utility) {
                for stems in targets {
                    await markCurrent(stems)
                    let outcome = await MeetingSalvage.retranscribe(
                        stems: stems,
                        meetingsDir: dir,
                        transcriber: transcriber,
                        strings: strings,
                        language: language
                    )
                    switch outcome {
                    case .retranscribed(let md):
                        await Self.finishRecoveredMeeting(
                            md: md, body: strings.notifTranscriptReady, context: context
                        )
                    // Text landed in the .md, but the take is not finished: no hook
                    // and no summary until a later attempt fills the holes.
                    case .partial:
                        await MainActor.run {
                            notifier.notify(title: "sezish", body: strings.notifMeetingPartial)
                        }
                    case .failed:
                        await MainActor.run {
                            notifier.notify(title: "sezish", body: strings.notifMeetingNoTranscript)
                        }
                    // Silence: the stems are gone and there was never anything to say.
                    case .nothingToRecover:
                        break
                    }
                }
                await finish()
            }
        }
    }

    func stopMeetingRecording() {
        guard status == .recordingMeeting else { return }
        recordingPanel.hide()
        status = .processingMeeting
        Task { await self.finishMeeting() }
    }

    private func finishMeeting() async {
        defer {
            status = .idle
            meetingStartDate = nil
            meetingWasAutoStarted = false
            meetingTranscription = nil
        }
        do {
            let capture = try await meetingRecorder.stop()
            await runMeetingPipeline(capture)
        } catch {
            meetingTranscription?.cancel()
            notifier.notify(title: "sezish", body: strings.notifMeetingFailed)
        }
    }

    /// Audio lands on disk FIRST (the take must survive any transcription
    /// failure), then the transcript .md joins it.
    private func runMeetingPipeline(_ capture: MeetingRecorder.Capture) async {
        let dir = MeetingRecorder.meetingsDirectory
        let fm = FileManager.default
        let startedAt = meetingStartDate ?? Date().addingTimeInterval(-capture.duration)
        let base = MeetingFileNamer.uniqueBaseName(for: startedAt) {
            MeetingSalvage.nameIsTaken($0, in: dir)
        }

        var audioName = base + ".m4a"
        do {
            try await M4AWriter.write(
                samples16k: capture.mixed16k, to: dir.appendingPathComponent(audioName)
            )
        } catch {
            // Fallback: raw WAV — bigger, but the take is never lost.
            audioName = base + ".wav"
            let wavURL = dir.appendingPathComponent(audioName)
            let samples = capture.mixed16k
            try? await Task.detached(priority: .userInitiated) {
                let spool = try PCMSpoolFile(url: wavURL)
                try spool.append(samples)
                try spool.finalize()
            }.value
        }

        // Too short to be a meeting (voice search, a voice message): the audio
        // stays, everything downstream — transcript, .md, hook, summary,
        // notification — is skipped, silently.
        guard MeetingTranscriptionRule.shouldTranscribe(duration: capture.duration) else {
            meetingTranscription?.cancel()
            try? fm.removeItem(at: capture.tempDir)
            return
        }

        var transcript: String?
        var failureDetail: String?
        // No model on disk, or holes where chunks failed: this take still has
        // unrecognised text in it, so it is kept for a retry. Not `transcript ==
        // nil` — a silent meeting will never produce words and would then offer
        // itself for a retry forever.
        var needsRetry = true
        if let pipeline = meetingTranscription {
            // Chunks were transcribed live during the recording; this only
            // drains the tail, so it returns within seconds even for long calls.
            // One paragraph per ~30 s chunk, prefixed with its recording-relative
            // timestamp and — when both tracks were recorded — with who spoke;
            // a jump in timestamps means a silent stretch.
            let segments = await pipeline.finish()
            transcript = TranscriptSegment.render(
                segments,
                meLabel: strings.meetingSpeakerMe,
                themLabel: strings.meetingSpeakerThem
            )
            needsRetry = pipeline.failedChunkCount > 0
        } else {
            // No local model on disk. Meetings NEVER go to the cloud (see
            // makeMeetingTranscriptionPipeline) — keep the audio, say why.
            failureDetail = strings.notifModelMissing
        }

        let markdown = Self.meetingMarkdown(
            strings: strings,
            language: language,
            date: startedAt,
            duration: capture.duration,
            audioFile: audioName,
            transcript: transcript,
            recovered: false
        )
        let mdURL = dir.appendingPathComponent(base + ".md")
        try? markdown.write(to: mdURL, atomically: true, encoding: .utf8)

        if needsRetry {
            // The retry reads the stems, so they move next to the meeting instead
            // of being deleted. A move that fails must still clear the spool dir:
            // audio and .md are already on disk, and a stray `.rec-` dir would
            // come back as a second meeting on the next launch.
            if (try? MeetingSalvage.stash(stems: capture.tempDir, base: base, in: dir)) == nil {
                try? fm.removeItem(at: capture.tempDir)
            }
        } else {
            // Audio and transcript are both on disk now, so whatever the user chains
            // after a meeting always opens a finished one. A meeting waiting for a
            // retry fires neither hook nor summary — both run once, after the retry.
            MeetingHook.fire(command: settings.meetingHook, mdURL: mdURL)
            startSummary(meetingMd: mdURL, hasTranscript: transcript != nil)
            try? fm.removeItem(at: capture.tempDir)
        }

        let body: String
        if needsRetry, transcript != nil {
            body = strings.notifMeetingPartial
        } else if needsRetry, let failureDetail {
            // The detail is the "download the model" line, which already points
            // at the menu; a second hint about the menu would only repeat it.
            body = strings.notifMeetingNoTranscript + " " + failureDetail
        } else if needsRetry {
            body = strings.notifMeetingNoTranscript + " " + strings.notifMeetingRetryHint
        } else {
            body = transcript != nil
                ? strings.notifTranscriptReady
                : strings.notifMeetingNoTranscript
        }
        notifier.notify(title: "sezish", body: body)

        pendingMeetings = MeetingSalvage.discoverStems(in: dir)
        refreshMeetings()
    }

    /// Hands a finished meeting to the summary engine and forgets about it.
    ///
    /// Detached and never awaited on purpose: the CLI is somebody else's binary under a
    /// ten-minute ceiling, while the meeting itself is already complete on disk. The
    /// transcript notification must fire on exactly the schedule it always has,
    /// whatever the agent is doing with the vault — and a summary that fails must cost
    /// the recording nothing.
    ///
    /// `hasTranscript` is the caller's gate: there is no point starting an agent on a
    /// meeting whose text never got recognised (the runner checks too, but this saves
    /// the process launch).
    private func startSummary(meetingMd: URL, hasTranscript: Bool) {
        guard settings.summaryEnabled, hasTranscript,
            let notesFolder = Self.vaultURL(settings.notesFolder)
        else { return }

        // Read on the main actor and captured, like the strings and the notifier: the
        // detached task must not reach back into AppState for any of it.
        let engine = settings.summaryEngine
        let language = language
        let strings = strings
        let notifier = notifier

        Task.detached(priority: .utility) {
            let outcome = await SummaryRunner().summarize(
                meetingMd: meetingMd, notesFolder: notesFolder,
                engine: engine, language: language
            )
            if let body = Self.summaryNotification(outcome, strings: strings) {
                await MainActor.run { notifier.notify(title: "sezish", body: body) }
            }
        }
    }

    /// `.skipped` is silent by design: no engine, not logged in, or already summarized
    /// are all states the user did not ask about and cannot act on from a banner.
    nonisolated static func summaryNotification(
        _ outcome: SummaryOutcome, strings: Strings
    ) -> String? {
        switch outcome {
        case .done: strings.notifSummaryReady
        case .failed: strings.notifSummaryFailed
        case .skipped: nil
        }
    }

    /// The setting round-trips through `URL(string:)`, so it comes back either as a
    /// `file:` URL or — when someone set it with `defaults write` — as a bare path with
    /// no scheme. A subprocess needs a real file URL either way.
    nonisolated static func vaultURL(_ stored: URL?) -> URL? {
        guard let stored, !stored.path.isEmpty else { return nil }
        return URL(fileURLWithPath: stored.path)
    }

    /// `recovered` marks a meeting rebuilt from crash-orphaned stems. The engine
    /// line is derived, not passed: it belongs with a transcript, and meetings
    /// are ALWAYS on-device, so the sentence is static by design.
    nonisolated static func meetingMarkdown(
        strings: Strings,
        language: AppLanguage,
        date: Date,
        duration: TimeInterval,
        audioFile: String,
        transcript: String?,
        recovered: Bool = false
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .uz ? "uz" : "ru")
        formatter.dateStyle = .long
        formatter.timeStyle = .short

        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60

        var md = "# \(strings.meetingDocTitle) - \(formatter.string(from: date))\n\n"
        if recovered {
            md += "_\(strings.meetingDocRecovered)_\n\n"
        }
        md += "\(strings.meetingDocDuration): \(String(format: "%d:%02d", minutes, seconds))\n"
        if transcript != nil {
            md += "\(strings.meetingDocEngine)\n"
        }
        md += "Audio: [\(audioFile)](\(audioFile))\n\n"
        md += transcript ?? "_\(strings.notifMeetingNoTranscript)_"
        md += "\n"
        return md
    }
}
