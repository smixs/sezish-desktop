import AppKit
import ApplicationServices
import AVFoundation
import Observation
import OSLog
import ServiceManagement
import SezishCore

/// Runs `OnboardingFlow` against macOS: feeds it the 1 s permission poll and
/// carries out its effects. The flow decides; this class only does what it says.
@MainActor
@Observable
final class OnboardingController {
    private(set) var flow: OnboardingFlow
    /// "Launch at login" on the done screen, applied when the tour finishes.
    var launchAtLogin = true
    /// The model the local card downloads, picked by the system language.
    private(set) var localModel: AsrModel

    @ObservationIgnored private unowned let appState: AppState
    @ObservationIgnored private var tracker = StalePermissionTracker()
    @ObservationIgnored private var listenerReported = false
    @ObservationIgnored private let relaunchGuard: OnboardingRelaunchGuard?
    @ObservationIgnored var onFinish: (() -> Void)?
    @ObservationIgnored private let log = Logger(subsystem: "com.smixs.sezish", category: "onboarding")

    init(appState: AppState) {
        self.appState = appState
        relaunchGuard = Self.guardDirectory.map(OnboardingRelaunchGuard.init(directory:))
        // A model already on disk stays; otherwise the system language picks it.
        localModel = appState.modelPhase == .ready ? appState.localModel
            : AppLanguage.systemDefault() == .uz ? .multilingual : .ruEnPunctuated
        flow = OnboardingFlow(status: Self.status(appState), engine: Self.engine(appState),
                              model: Self.model(appState))
    }

    var strings: OnboardingStrings { .forLanguage(appState.language) }

    // MARK: - Launch

    /// The tour opens at launch when dictation could not work yet, or right
    /// after a relaunch it started itself.
    static func neededAtLaunch(_ appState: AppState) -> Bool {
        let resumed = guardDirectory.map(OnboardingRelaunchGuard.init(directory:))?
            .takeResume(now: Date()) ?? false
        return resumed || OnboardingFlow.needed(
            status: status(appState), engine: engine(appState), model: model(appState))
    }

    private static var guardDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sezish", isDirectory: true)
    }

    // MARK: - Inputs

    /// Called from the 1 s permission poll while the tour is open.
    func tick() {
        let status = Self.status(appState)
        send(.status(status))
        send(.model(Self.model(appState)))
        let untrusted = status.accessibility == .off
        if tracker.poll(now: ProcessInfo.processInfo.systemUptime, untrusted: untrusted,
                        focus: SystemSettingsWindow.focus) {
            flow.setAccessibilityStale(true)
        }
        if status.accessibility == .needsRestart, !listenerReported {
            listenerReported = true
            send(.listenerFailed(relaunchAllowed: relaunchGuard?.allowed(now: Date()) ?? false))
        }
    }

    func grantMicrophone() { send(.grantMicrophone) }
    func grantAccessibility() { send(.grantAccessibility(trustedNow: AXIsProcessTrusted())) }
    func reopen() { send(.reopen) }
    func back() { send(.back) }
    func next() { send(.continue) }
    func retryDownload() { send(.retryDownload) }

    func chooseCloud() {
        appState.setTranscriptionMode(.cloud)
        send(.chooseEngine(.cloud))
    }

    func chooseLocal(_ model: AsrModel) {
        localModel = model
        appState.setLocalModel(model)
        appState.setTranscriptionMode(.local)
        send(.model(Self.model(appState)))
        send(.chooseEngine(.local))
    }

    func send(_ input: OnboardingInput) {
        perform(flow.on(input))
    }

    // MARK: - Effects

    private func perform(_ effect: OnboardingEffect) {
        switch effect {
        case .none:
            break
        case .requestMicrophone:
            appState.requestMicrophone()
        case .showGuide(let kind):
            if kind == .accessibility { tracker.noteAsked(now: ProcessInfo.processInfo.systemUptime) }
            PermissionGuide.shared.show(kind, text: kind == .accessibility
                ? strings.guideDrag : strings.guideSwitchOn)
        case .resetAccessibility:
            resetAccessibility()
        case .downloadModel:
            appState.downloadModel()
        case .advanceSoon:
            // A beat so the last check is seen before the screen moves on.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.flow.step == .permissions else { return }
                self.send(.continue)
            }
        case .relaunch:
            try? relaunchGuard?.record(now: Date())
            PermissionGuide.shared.close()
            appState.relaunch()
        case .finish:
            PermissionGuide.shared.close()
            applyLaunchAtLogin()
            onFinish?()
        }
    }

    /// `tccutil reset Accessibility <bundle>` off the main thread, then a fresh
    /// check: a grant that landed meanwhile is kept, otherwise prompt and guide again.
    private func resetAccessibility() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.smixs.sezish"
        let log = log
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "Accessibility", bundleID]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = Pipe()
            var outcome = TccResetOutcome.failed
            if (try? process.run()) != nil {
                process.waitUntilExit()
                let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
                outcome = TccResetOutcome(exitCode: process.terminationStatus, stderr: stderr)
            }
            log.info("tccutil reset Accessibility: \(String(describing: outcome), privacy: .public)")
            await MainActor.run { [weak self] in self?.finishReset() }
        }
    }

    private func finishReset() {
        tracker.noteAsked(now: ProcessInfo.processInfo.systemUptime)
        guard !AXIsProcessTrusted() else { return }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        PermissionGuide.shared.show(.accessibility, text: strings.guideDrag)
    }

    private func applyLaunchAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        guard launchAtLogin != enabled else { return }
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Reading the app

    private static func status(_ appState: AppState) -> OnboardingStatus {
        let microphone: MicrophoneAccess = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        let accessibility: AccessibilityAccess = !AXIsProcessTrusted() ? .off
            : appState.needsRestart ? .needsRestart : .on
        return OnboardingStatus(microphone: microphone, accessibility: accessibility)
    }

    private static func engine(_ appState: AppState) -> OnboardingEngine {
        appState.effectiveTranscriptionMode == .local ? .local : .cloud
    }

    private static func model(_ appState: AppState) -> OnboardingModel {
        switch appState.modelPhase {
        case .missing: .missing
        case .downloading(let fraction): .downloading(fraction)
        case .ready: .ready
        case .failed: .failed
        }
    }
}
