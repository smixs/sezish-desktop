import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import Observation
import SezishAsr
import SezishCore

/// Single source of truth for the menu bar UI. MainActor-isolated by the target default.
/// Owns the model lifecycle, the push-to-talk pipeline, and the recording overlay.
@Observable
final class AppState {
    enum Status: Equatable {
        case idle
        case recordingMeeting
        case processingMeeting
    }

    /// Lifecycle of the on-disk ASR model.
    enum ModelPhase: Equatable {
        case missing
        case downloading(Double) // fraction 0...1
        case ready
        case failed(String)
    }

    var status: Status = .idle
    /// Set while a meeting recording runs; drives the panel timer.
    var meetingStartDate: Date?
    // Setter is used from the AppStateHistory.swift extension (same module).
    var dictations: [DictationRecord] = []
    /// The dictation being recognised again, if any: one retry at a time, and the
    /// menu draws a spinner in place of its ↻.
    var retryingDictation: UUID?
    /// Meetings whose stems are parked for a retry; drives the menu row.
    var pendingMeetings: [URL] = []
    var isRetryingMeetings = false
    /// The stems folder being recognised right now: a batch retry walks the list
    /// one meeting at a time, and only that row may spin.
    var retryingMeeting: URL?
    /// The meetings folder as the History tab lists it. Filled on demand (the tab
    /// reads it when it appears) and after anything that writes a meeting.
    var meetings: [MeetingEntry] = []
    // Setter is used from the AppState+Model.swift extension (same module).
    var modelPhase: ModelPhase = .missing
    let settings: AppSettings

    /// Mirror of `settings.transcriptionMode` (AppSettings is not `@Observable`),
    /// so the popup and settings redraw when the mode changes.
    var transcriptionMode: TranscriptionMode = .cloud

    /// Mirror of `settings.effectiveTranscriptionMode`: a chosen mode whose credential
    /// is missing runs as another one, and the UI must follow what dictation really does.
    /// Kept as a mirror (not a computed read of `settings`) for the same observability reason.
    private(set) var effectiveTranscriptionMode: TranscriptionMode = .cloud

    /// Mirror of `settings.localModel` (same observability reason).
    var localModel: AsrModel = .default

    /// Models whose files are fully on disk — drives the "delete the unused one" row.
    var installedModels: Set<AsrModel> = []

    /// Mirror of `settings.autoRecordMeetings` (same observability reason).
    var autoRecordMeetings = false

    /// Mirror of `settings.playSounds` (same observability reason).
    var soundsEnabled = true

    /// UI language; mirrored from settings for the same observability reason.
    var language: AppLanguage = .ru
    var strings: Strings { .forLanguage(language) }

    /// Whether dictation currently depends on the local model — the popup shows the
    /// download section only then. Reads the observed mirror so views track it.
    var usesLocalTranscription: Bool { effectiveTranscriptionMode == .local }

    /// The active push-to-talk shortcut. A stored, observed property (not a computed view over
    /// `AppSettings`, which isn't `@Observable`) so the settings UI redraws when it changes.
    var currentShortcut: Shortcut = .defaultShortcut

    /// Mirror of `settings.hotkeyMode` (same observability reason): hold vs toggle.
    var hotkeyMode: HotkeyMode = .hold

    /// Permission state, mirrored into stored observed properties so the settings UI redraws
    /// live. The 1 s permission poll keeps them fresh even while the app was never focused.
    var accessibilityTrusted = false
    var microphoneAuthorized = false

    /// Set when Accessibility is granted but the event tap still refuses to install — the only
    /// known cure is a relaunch (the OS hasn't propagated the new TCC grant to this process).
    var needsRestart = false

    // `internal` (not `private`) so the model extension in a sibling file can reach them;
    // the app is a single-module executable, so this stays module-private in practice.
    /// Store of the selected `localModel`; rebuilt by `setLocalModel` (sibling file).
    @ObservationIgnored var modelStore: ModelStore
    @ObservationIgnored let downloader = ModelDownloader()
    @ObservationIgnored let history: DictationHistory?
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored var coordinator: DictationCoordinator?
    /// The transcriber the coordinator uses; shared with the meeting pipeline so a
    /// local model is never loaded twice.
    @ObservationIgnored var activeTranscriber: Transcriber?
    @ObservationIgnored var downloadTask: Task<Void, Never>?

    @ObservationIgnored private let overlay = RecordingOverlay()
    @ObservationIgnored let meetingRecorder = MeetingRecorder()
    /// Live meeting transcription (local model, chunked); nil while no meeting runs.
    @ObservationIgnored var meetingTranscription: MeetingTranscriptionPipeline?
    /// Cached local transcriber for meetings — loaded once even when dictation
    /// runs in cloud mode, so meetings never depend on the network.
    @ObservationIgnored var meetingLocalTranscriber: Transcriber?
    @ObservationIgnored let recordingPanel = RecordingPanel()
    @ObservationIgnored let sounds = SoundPlayer()
    @ObservationIgnored var meetingDetector: MeetingDetector?
    /// Auto-stop applies only to auto-started recordings; manual ones end manually.
    @ObservationIgnored var meetingWasAutoStarted = false
    /// Fed by the mic tap during dictation; drives the overlay's wave.
    @ObservationIgnored let levelMeter = AudioLevelMeter()
    @ObservationIgnored private var shortcutMonitor: ShortcutMonitor?
    /// Turns the monitor's raw press/release edges into start/stop per the current mode.
    @ObservationIgnored private var hotkeyInterpreter: HotkeyModeInterpreter?
    @ObservationIgnored private var permissionPoll: Timer?

    init() {
        settings = AppSettings(defaults: .standard, bakedCloud: Self.bakedCloudCredentials())
        transcriptionMode = settings.transcriptionMode
        effectiveTranscriptionMode = settings.effectiveTranscriptionMode
        localModel = settings.localModel
        modelStore = ModelStore(model: settings.localModel)
        // Two languages on the Mac (the phone speaks five): a system set to anything
        // but Uzbek is read in Russian, exactly as before `AppLanguage` grew.
        language = settings.appLanguage ?? (AppLanguage.systemDefault() == .uz ? .uz : .ru)
        currentShortcut = settings.shortcut ?? .defaultShortcut
        hotkeyMode = settings.hotkeyMode
        accessibilityTrusted = AXIsProcessTrusted()
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        history = Self.historyDirectory.flatMap { try? DictationHistory(directory: $0) }
        dictations = history?.records ?? []

        autoRecordMeetings = settings.autoRecordMeetings
        soundsEnabled = settings.playSounds
        notifier.prepare()
        salvageOrphanedMeetingsAtLaunch()
        // Stems parked by an earlier session; the salvage task refreshes this
        // again when it finishes, in case it parked more.
        pendingMeetings = MeetingSalvage.discoverStems(in: MeetingRecorder.meetingsDirectory)
        installMeetingDetector()
        // modelPhase tracks only the LOCAL model; cloud readiness is coordinator != nil.
        if modelStore.isComplete {
            modelPhase = .ready
        }
        refreshInstalledModels()
        rebuildCoordinator()
        hotkeyInterpreter = HotkeyModeInterpreter(
            mode: hotkeyMode,
            isRecording: { [weak self] in self?.coordinator?.state == .recording }
        )
        installShortcutMonitor()
        startPermissionPoll()
    }

    func setSoundsEnabled(_ enabled: Bool) {
        soundsEnabled = enabled
        settings.playSounds = enabled
    }

    /// Persists the language choice; views re-render off the observed mirror.
    func setLanguage(_ new: AppLanguage) {
        guard new != language else { return }
        language = new
        settings.appLanguage = new
    }

    /// Persists the mode choice and swaps the dictation pipeline.
    func setTranscriptionMode(_ mode: TranscriptionMode) {
        guard mode != transcriptionMode else { return }
        settings.transcriptionMode = mode
        refreshModeMirrors()
        rebuildCoordinator()
    }

    /// Both mirrors come from the same read: the chosen mode and the one it degrades to
    /// must never describe two different moments.
    func refreshModeMirrors() {
        transcriptionMode = settings.transcriptionMode
        effectiveTranscriptionMode = settings.effectiveTranscriptionMode
    }

    /// Cloud credentials baked into Info.plist by `make bundle` (absent in plain
    /// `swift build`, where the defaults override is the only way in).
    private static func bakedCloudCredentials() -> CloudCredentials? {
        guard let info = Bundle.main.infoDictionary,
              let raw = info["SezishCloudEndpoint"] as? String,
              let endpoint = URL(string: raw),
              let apiKey = info["SezishCloudKey"] as? String, !apiKey.isEmpty
        else { return nil }
        return CloudCredentials(endpoint: endpoint, apiKey: apiKey)
    }

    // MARK: - Gemini

    /// The user's own Google key. Written on every keystroke of the settings field, so the
    /// rebuild deliberately skips the warmup: a socket per typed character would hit Google
    /// with dozens of half-keys. The first take opens the session itself (`begin()`).
    func setGeminiApiKey(_ key: String) {
        settings.geminiApiKey = key
        refreshModeMirrors()
        rebuildCoordinator(warmup: false)
    }

    func setGeminiSmartMode(_ on: Bool) {
        settings.geminiSmartMode = on
        rebuildCoordinator()
    }

    // MARK: - Meeting recording

    var isRecordingMeeting: Bool { status == .recordingMeeting }

    func toggleMeetingRecording() {
        switch status {
        case .recordingMeeting: stopMeetingRecording()
        case .idle: startMeetingRecording(source: .manual)
        case .processingMeeting: break
        }
    }

    // MARK: - Hotkey

    /// Persists the new push-to-talk shortcut and live-swaps it on the running tap. The tap's
    /// event mask is identical for every shortcut, so `updateShortcut` re-targets it in place
    /// rather than tearing down a working tap (matches the ported VoiceInk model).
    func setShortcut(_ new: Shortcut) {
        guard new != currentShortcut else { return }
        currentShortcut = new
        settings.shortcut = new
        shortcutMonitor?.updateShortcut(new)
    }

    /// Persists the hold/toggle choice. A latched toggle take is ended cleanly first, so the
    /// user is never stranded with a recording that the new mode's gestures can't stop.
    func setHotkeyMode(_ mode: HotkeyMode) {
        guard mode != hotkeyMode else { return }
        if coordinator?.state == .recording { stopDictation() }
        hotkeyMode = mode
        settings.hotkeyMode = mode
        hotkeyInterpreter?.mode = mode
        hotkeyInterpreter?.reset()
    }

    /// Registers the app in the Accessibility list (prompt) and opens the pane.
    func openAccessibilitySettings() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Prompts for Microphone access, or opens the privacy pane if already denied
    /// (`requestAccess` only shows a prompt while status is `.notDetermined`).
    func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in self?.microphoneAuthorized = granted }
            }
        default:
            if let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Relaunches the app: spawns a fresh instance via `open -n`, then quits this one. Used to
    /// recover when the event tap won't install despite an Accessibility grant.
    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// (Re)installs the event tap for `currentShortcut`. No-op without Accessibility; when
    /// trusted but the tap still won't create, flags `needsRestart` so the UI can offer a
    /// relaunch. Idempotent: any existing tap is torn down first.
    private func installShortcutMonitor() {
        shortcutMonitor?.stopMonitoring()
        shortcutMonitor = nil
        guard AXIsProcessTrusted() else { return }
        let monitor = ShortcutMonitor(shortcut: currentShortcut)
        monitor.onPressed = { [weak self] in self?.handleHotkeyPressed() }
        monitor.onReleased = { [weak self] in self?.handleHotkeyReleased() }
        monitor.onEscapeCancel = { [weak self] in self?.cancelDictation() }
        do {
            try monitor.startMonitoring()
            shortcutMonitor = monitor
            needsRestart = false
        } catch {
            shortcutMonitor = nil
            needsRestart = true
        }
    }

    /// Polls permission state every second (two cheap status calls) so the observed flags stay
    /// live even when unfocused. On the false→true Accessibility edge it re-creates the tap at
    /// once (the Handy pattern), so the hotkey works the instant the grant lands — no restart.
    private func startPermissionPoll() {
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPermissions() }
        }
    }

    private func pollPermissions() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            if trusted { installShortcutMonitor() } // grant just landed → bring the tap up now
        } else if trusted, shortcutMonitor == nil, !needsRestart {
            installShortcutMonitor() // trusted, tap missing, not yet given up → retry once
        }

        let micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if micAuthorized != microphoneAuthorized { microphoneAuthorized = micAuthorized }
    }

    // MARK: - Dictation pipeline

    private func handleHotkeyPressed() {
        switch hotkeyInterpreter?.keyPressed() {
        case .start: startDictation()
        case .stop: stopDictation()
        default: break
        }
    }

    private func handleHotkeyReleased() {
        switch hotkeyInterpreter?.keyReleased() {
        case .start: startDictation()
        case .stop: stopDictation()
        default: break
        }
    }

    private func startDictation() {
        // Only reachable in local mode without a downloaded model: cloud mode builds
        // its coordinator unconditionally when credentials exist.
        guard let coordinator else {
            notifier.notify(title: "sezish", body: strings.notifModelMissing)
            return
        }
        coordinator.begin()
        if coordinator.state == .recording {
            shortcutMonitor?.isEscapeArmed = true
            overlay.show(meter: levelMeter)
            if soundsEnabled { sounds.play(.dictation) }
        } else {
            notifier.notify(title: "sezish", body: strings.notifRecordFailed)
        }
    }

    private func stopDictation() {
        shortcutMonitor?.isEscapeArmed = false
        levelMeter.reset()
        guard let coordinator, coordinator.state == .recording else {
            overlay.hide()
            return
        }
        // The HUD stays up as a spinner until the transcript lands (or fails).
        overlay.beginTranscribing()
        Task {
            let outcome = await coordinator.end()
            self.overlay.hide()
            self.refreshDictations()
            switch outcome {
            case .insertFailed(let message):
                notifier.notify(title: "sezish", body: message)
            case .noText:
                notifier.notify(title: "sezish", body: strings.notifNoText)
            case .failed:
                notifier.notify(title: "sezish", body: strings.notifDictationFailed)
            case .ignored, .inserted:
                break
            }
        }
    }

    /// Esc during recording. Fires synchronously inside the tap callback, so it only does the
    /// cheap parts here and pushes the mic teardown into a task. No notification, no history
    /// refresh — the take never existed.
    private func cancelDictation() {
        shortcutMonitor?.isEscapeArmed = false
        overlay.hide()
        levelMeter.reset()
        guard let coordinator, coordinator.state == .recording else { return }
        Task { await coordinator.cancel() }
    }

    // Model download + activation lives in AppState+Model.swift.
    static var historyDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sezish/DictationHistory", isDirectory: true)
    }
}
