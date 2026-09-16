import AppKit
import AudioToolbox
import Foundation
import SezishAsr
import SezishCore
import os

/// One line per meeting start about the system stem — what it holds, and when the
/// only thing left to hold is the whole Mac. Same subsystem as every other log.
private let systemTapLog = Logger(subsystem: "com.smixs.sezish", category: "system-tap")

/// Meeting recording lifecycle for `AppState`. Split out like AppState+Model to
/// keep the state file on UI/hotkey wiring.
extension AppState {
    /// The detector's starts are the only ones the silence net applies to, and
    /// the only ones the detector may stop. `MeetingStartSource` itself lives in
    /// `SezishCore` now, together with the call app the tap is scoped to.

    /// The detector polls only while the toggle is on; its callbacks re-check the
    /// gate anyway, so a stale tick can never start a recording.
    func installMeetingDetector() {
        let detector = MeetingDetector(policy: meetingPolicy)
        detector.onMeetingStart = { [weak self] bundleID in
            guard let self, self.autoRecordMeetings, self.status == .idle else { return }
            self.startMeetingRecording(source: .auto(bundleID: bundleID))
        }
        detector.onMeetingEnd = { [weak self] quietWindow in
            guard let self, self.meetingWasAutoStarted else { return }
            // The detector waited the debounce's stop window out before calling
            // this, so it hands that window over: it is not meeting time either.
            self.stopMeetingRecording(reason: .callEnded(quietWindow))
        }
        detector.onStatus = { [weak self] facts in
            self?.meetingDetectorFacts = facts
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
        // Once, before a single sample is recorded: from here on the system stem
        // holds the call app's audio and not whatever else is playing. The mic
        // device (A4) and the file name (A7) read the same field later.
        let snapshot = readProcessSnapshot()
        let callApp = resolveMeetingCallApp(source: source, snapshot: snapshot)
        meetingCallApp = callApp
        let mic = resolveMeetingMicDevice(for: callApp, snapshot: snapshot)
        let pipeline = makeMeetingTranscriptionPipeline()
        do {
            let outcome = try meetingRecorder.start(
                coverage: tapCoverage(for: callApp, snapshot: snapshot),
                device: mic?.id,
                pipeline: pipeline
            )
            meetingTranscription = pipeline
            meetingWasAutoStarted = source.isAuto
            // First sample to last: the two safety nets live from here and can end
            // the recording on their own if the call goes quiet or runs five hours.
            startMeetingAutoStop(auto: source.isAuto)
            presentMeetingStart(outcome: outcome, auto: source.isAuto)
        } catch {
            // The one place a failed start is not swallowed: the cause (an OSStatus from
            // pinning the call app's device, a denied tap, a disk error) is what tells
            // the user why the meeting is missing.
            micRouteLog.error(
                "meeting start failed: \(error.localizedDescription, privacy: .public)"
            )
            meetingStartFailed(pipeline)
        }
    }

    /// A meeting that never started leaves no trace: no call app, no pipeline and
    /// no recording — and the user is told why.
    private func meetingStartFailed(_ pipeline: MeetingTranscriptionPipeline?) {
        meetingCallApp = nil
        pipeline?.cancel()
        notifier.notify(title: "sezish", body: strings.notifRecordFailed)
    }

    /// Everything that happens once the recorder is running: the state the detector
    /// and the menu read, the warning when only the mic could be recorded, the chime,
    /// and the panel with its stop/hide hooks.
    private func presentMeetingStart(outcome: MeetingRecorder.StartOutcome, auto: Bool) {
        meetingWasAutoStarted = auto
        if case .micOnly = outcome {
            notifier.notify(title: "sezish", body: strings.notifSystemAudioDenied)
        }
        let startDate = meetingRecorder.startDate
        status = .recordingMeeting
        meetingStartDate = startDate
        if soundsEnabled { sounds.play(.meeting) }
        recordingPanel.show(
            startDate: startDate ?? Date(),
            auto: auto,
            strings: strings,
            onStop: { [weak self] in self?.stopMeetingRecording(reason: .manual) },
            onHide: { [weak self] in self?.recordingPanel.hide() }
        )
    }

    /// Arms the nets for this recording and starts the 1 Hz poll that feeds them.
    /// The thresholds are hidden settings (`meetingSilenceStopMinutes`,
    /// `meetingMaxDurationMinutes`); the poll dies with the recording.
    private func startMeetingAutoStop(auto: Bool) {
        meetingAutoStop = MeetingAutoStop(
            startedAt: meetingRecorder.startDate ?? Date(),
            isAuto: auto,
            silenceAfter: settings.meetingSilenceStopAfter,
            maxDuration: settings.meetingMaxDurationAfter
        )
        meetingStopPoll?.invalidate()
        meetingStopPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMeetingAutoStop() }
        }
    }

    /// One tick of the nets: the tracks' loudness in, a stop reason out.
    private func pollMeetingAutoStop() {
        let now = Date()
        let loudness = meetingRecorder.loudness(at: now)
        guard
            let reason = meetingAutoStop?.tick(
                micLoud: loudness.mic, systemLoud: loudness.system, at: now
            )
        else { return }
        stopMeetingRecording(reason: reason)
    }

    /// The app ended this recording on its own, so it owes the user a reason — but
    /// only once the take is on disk: a silence stop with no meeting in it is
    /// thrown away whole (`MeetingTranscriptionRule.discardsAudio`), and announcing
    /// a recording nobody will ever hear would be a lie. Which units the banner
    /// speaks is `SezishCore`'s call (`MeetingStopReason.banner`).
    private func notifyMeetingStopped(_ reason: MeetingStopReason) {
        guard let banner = reason.banner else { return }
        notifier.notify(title: "sezish", body: stopBannerBody(banner))
    }

    /// The banner for a stop the user did not ask for. A manual stop and the
    /// detector's own need no announcement, and `banner` excludes them already.
    private func stopBannerBody(_ banner: MeetingStopBanner) -> String {
        switch banner {
        case .silence(let minutes):
            return String(format: strings.notifStoppedBySilence, minutes)
        case .ceiling(let hours, let minutes):
            return String(format: strings.notifStoppedByCeiling, ceilingParts(hours, minutes))
        }
    }

    /// "5 ч", "1 ч 30 мин", "30 мин": the ceiling as words, with the parts Core kept.
    private func ceilingParts(_ hours: Int?, _ minutes: Int?) -> String {
        [hours.map { String(format: strings.notifCeilingHours, $0) },
         minutes.map { String(format: strings.notifCeilingMinutes, $0) }]
            .compactMap { $0 }
            .joined(separator: " ")
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

    /// The one policy both the detector and a manual start judge mic holders by.
    private var meetingPolicy: MeetingDetectionPolicy {
        MeetingDetectionPolicy(
            ownBundleID: Bundle.main.bundleIdentifier ?? "com.smixs.sezish",
            extraDenyPrefixes: settings.extraDenyApps
        )
    }

    /// One read of the process list for a whole start: the call app and the tap
    /// coverage come from the same snapshot, because a second read a moment later
    /// can name a process the first never saw. A read that fails leaves the meeting
    /// recording the mic and every process — the degradation, with its cause logged.
    private func readProcessSnapshot() -> AudioProcessSnapshot {
        do {
            return try AudioProcessSnapshot.read()
        } catch {
            systemTapLog.error(
                "process list unreadable: \(error.localizedDescription, privacy: .public)"
            )
            return .empty
        }
    }

    /// The pure decision lives in `SezishCore`; the snapshot supplies the mic
    /// holders and the detector supplies the app it saw. The display name is
    /// snapshotted here, once, while the process is known alive — a pid read
    /// after the recording may be dead or handed to another app by then.
    private func resolveMeetingCallApp(
        source: MeetingStartSource, snapshot: AudioProcessSnapshot
    ) -> MeetingCallApp? {
        MeetingCallAppResolver.resolve(
            source: source, holders: snapshot.inputHolders, policy: meetingPolicy
        ) { pid in
            pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        }
    }

    /// What the system stem holds for this start, and one line when that is the
    /// whole Mac because the call app's family has nothing live to tap — the single
    /// degradation this path allows (`.all` *is* that answer, so it gets no line).
    private func tapCoverage(
        for callApp: MeetingCallApp?, snapshot: AudioProcessSnapshot
    ) -> TapCoverage {
        let coverage = MeetingAudioScope.forCallApp(callApp).coverage(live: snapshot.tapCandidates)
        guard coverage == .global, let callApp else { return coverage }
        systemTapLog.notice(
            "no live process in \(callApp.family, privacy: .public): recording all system audio"
        )
        return coverage
    }

    /// The microphone the meeting records: the real device the call app listens to, or
    /// nothing — and nothing means the engine opens its own input, exactly as it always
    /// has for dictation. Pinning a device nobody asked for only adds a way to fail.
    /// Decided once, before the engine opens: an app that moves to another device
    /// mid-call is deliberately not followed. The family's processes come from the same
    /// snapshot the tap used.
    private func resolveMeetingMicDevice(
        for callApp: MeetingCallApp?, snapshot: AudioProcessSnapshot
    ) -> MicDevice? {
        let callAppInputs = callApp?.inputDevices(in: snapshot) ?? []
        let chosen = MeetingMicRoute.device(callAppInputs: callAppInputs)
        logMeetingMic(chosen)
        return chosen
    }

    /// Which device the mic follows, or that the engine picks its own — the two cases
    /// look identical in the audio, and only the log tells them apart.
    private func logMeetingMic(_ device: MicDevice?) {
        guard let device else {
            micRouteLog.notice("meeting mic: engine default (call app holds no real input)")
            return
        }
        micRouteLog.notice("meeting mic: \(device.name, privacy: .public) (call app)")
    }

    func stopMeetingRecording() {

    /// Ends the recording in flight with the reason it ended — a parameter, not a
    /// field: a stop that arrives while the take is being mixed down can no longer
    /// rewrite what ended the one before it, and the compiler makes every stopper
    /// say why.
    func stopMeetingRecording(reason: MeetingStopReason) {
        guard status == .recordingMeeting else { return }
        // A silence stop leaves the call app holding the mic, so the detector's
        // debounce stays `.active` and the next call in that app would never start a
        // recording. Re-arming it is safe because a silence-stopped take with no
        // meeting in it is deleted whole, so the loop "record, go quiet, stop"
        // cannot leave orphans behind.
        if reason.isSilenceStop { meetingDetector?.rearm() }
        // The nets die with the recording — a stop is a stop, whoever asked for it,
        // and the poll must not fire again while the take is being mixed down.
        meetingAutoStop = nil
        meetingStopPoll?.invalidate()
        meetingStopPoll = nil
        recordingPanel.hide()
        status = .processingMeeting
        Task { await self.finishMeeting(reason: reason) }
    }

    private func finishMeeting(reason: MeetingStopReason) async {
        defer {
            status = .idle
            meetingStartDate = nil
            meetingWasAutoStarted = false
            meetingCallApp = nil
            meetingTranscription = nil
        }
        do {
            let capture = try await meetingRecorder.stop()
            guard keepTake(capture, stopReason: reason) else { return }
            await runMeetingPipeline(capture, stopReason: reason)
        } catch {
            meetingTranscription?.cancel()
            notifier.notify(title: "sezish", body: strings.notifMeetingFailed)
        }
    }

    /// Audio lands on disk FIRST (the take must survive any transcription
    /// failure), then the transcript .md joins it.
    private func runMeetingPipeline(
        _ capture: MeetingRecorder.Capture, stopReason: MeetingStopReason
    ) async {
        let dir = MeetingRecorder.meetingsDirectory
        let fm = FileManager.default
        let startedAt = meetingStartDate ?? Date().addingTimeInterval(-capture.duration)
        // The file name reads where the call was: the same call app the system
        // stem was scoped to at the start (A1), slugged by the namer.
        let base = MeetingFileNamer.uniqueBaseName(
            for: startedAt, app: meetingCallApp?.displayName
        ) {
            MeetingSalvage.nameIsTaken($0, in: dir)
        }
        let audioName = await writeMeetingAudio(capture, to: dir, base: base)

        // Too short to be a meeting (voice search, a voice message): the audio
        // stays, everything downstream — transcript, .md, hook, summary,
        // notification — is skipped, silently. The window an automatic stop waited
        // out is not meeting time, so it comes off the duration first.
        guard
            MeetingTranscriptionRule.shouldTranscribe(
                duration: capture.duration, stopReason: stopReason
            )
        else {
            meetingTranscription?.cancel()
            try? fm.removeItem(at: capture.tempDir)
            return
        }

        let transcript = await meetingTranscript()
        let markdown = Self.meetingMarkdown(
            strings: strings,
            language: language,
            date: startedAt,
            duration: capture.duration,
            audioFile: audioName,
            transcript: transcript.text,
            callApp: meetingCallApp?.displayName,
            recovered: false
        )
        let mdURL = dir.appendingPathComponent(base + ".md")
        try? markdown.write(to: mdURL, atomically: true, encoding: .utf8)

        if transcript.needsRetry {
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
            startSummary(meetingMd: mdURL, hasTranscript: transcript.text != nil)
            try? fm.removeItem(at: capture.tempDir)
        }

        notifier.notify(title: "sezish", body: meetingNotificationBody(transcript))
        pendingMeetings = MeetingSalvage.discoverStems(in: dir)
        refreshMeetings()
    }

    /// A take the silence net ended with no meeting in it leaves nothing at all: no
    /// audio, no .md, no banner — that is the only case where the app throws recorded
    /// audio away (`MeetingTranscriptionRule.discardsAudio`). Checked before a single
    /// byte is written. Answers whether there is anything left to work on.
    private func keepTake(
        _ capture: MeetingRecorder.Capture, stopReason: MeetingStopReason
    ) -> Bool {
        guard MeetingTranscriptionRule.discardsAudio(
            duration: capture.duration, stopReason: stopReason
        ) else {
            // The take is a take: the user is told why the app stopped it, in the
            // units `SezishCore` chose for that reason.
            notifyMeetingStopped(stopReason)
            return true
        }
        meetingTranscription?.cancel()
        try? FileManager.default.removeItem(at: capture.tempDir)
        return false
    }

    /// What the take produced: the rendered transcript, the line explaining a
    /// missing one, and whether anything in it is still unrecognised.
    private struct MeetingTranscript {
        let text: String?
        let failureDetail: String?
        let needsRetry: Bool
    }

    /// Chunks were transcribed live during the recording, so this only drains the
    /// tail and returns within seconds even for long calls. One paragraph per ~30 s
    /// chunk, prefixed with its recording-relative timestamp and — when both tracks
    /// were recorded — with who spoke; a jump in timestamps means a silent stretch.
    ///
    /// Unrecognised text in the take keeps it retryable, and that is deliberately
    /// not `text == nil`: a silent meeting will never produce words and would then
    /// offer itself for a retry forever. A missing local model is the other hole,
    /// and meetings NEVER go to the cloud to fill it (see
    /// makeMeetingTranscriptionPipeline).
    private func meetingTranscript() async -> MeetingTranscript {
        guard let pipeline = meetingTranscription else {
            return MeetingTranscript(
                text: nil, failureDetail: strings.notifModelMissing, needsRetry: true
            )
        }
        let segments = await pipeline.finish()
        return MeetingTranscript(
            text: TranscriptSegment.render(
                segments,
                meLabel: strings.meetingSpeakerMe,
                themLabel: strings.meetingSpeakerThem
            ),
            failureDetail: nil,
            needsRetry: pipeline.failedChunkCount > 0
        )
    }

    /// The banner for the take that just ended: holes and a missing transcript all
    /// point at the retry, a finished one says so.
    private func meetingNotificationBody(_ transcript: MeetingTranscript) -> String {
        guard transcript.needsRetry else {
            return transcript.text != nil
                ? strings.notifTranscriptReady
                : strings.notifMeetingNoTranscript
        }
        return retryNotification(
            hasText: transcript.text != nil, failureDetail: transcript.failureDetail
        )
    }

    /// A take that still has unrecognised text in it: the failure detail when there
    /// is one (the "download the model" line already points at the menu, so a second
    /// hint would only repeat it), otherwise the retry hint.
    private func retryNotification(hasText: Bool, failureDetail: String?) -> String {
        if hasText { return strings.notifMeetingPartial }
        guard let failureDetail else {
            return strings.notifMeetingNoTranscript + " " + strings.notifMeetingRetryHint
        }
        return strings.notifMeetingNoTranscript + " " + failureDetail
    }

    /// Audio first, always: a take that is on disk survives any transcription
    /// failure. The M4A is the normal path; a write that fails falls back to a raw
    /// WAV — bigger, but the take is never lost. Returns the file name used.
    private func writeMeetingAudio(
        _ capture: MeetingRecorder.Capture, to dir: URL, base: String
    ) async -> String {
        let audioName = base + ".m4a"
        do {
            try await M4AWriter.write(
                samples16k: capture.mixed16k, to: dir.appendingPathComponent(audioName)
            )
            return audioName
        } catch {
            let wavName = base + ".wav"
            let wavURL = dir.appendingPathComponent(wavName)
            let samples = capture.mixed16k
            try? await Task.detached(priority: .userInitiated) {
                let spool = try PCMSpoolFile(url: wavURL)
                try spool.append(samples)
                try spool.finalize()
            }.value
            return wavName
        }
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

    /// First line of the meeting document: with a known call app it names it
    /// ("Звонок в Telegram, …"), otherwise the plain title, as before.
    nonisolated static func meetingTitle(
        strings: Strings, language: AppLanguage, date: Date, callApp: String?
    ) -> String {
        let stamp = meetingDateStamp(language: language, date: date)
        if let callApp {
            return "# \(String(format: strings.meetingDocTitleApp, callApp)) - \(stamp)\n\n"
        }
        return "# \(strings.meetingDocTitle) - \(stamp)\n\n"
    }

    nonisolated static func meetingDateStamp(language: AppLanguage, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .uz ? "uz" : "ru")
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
        callApp: String? = nil,
        recovered: Bool = false
    ) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60

        var md = meetingTitle(strings: strings, language: language, date: date, callApp: callApp)
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
