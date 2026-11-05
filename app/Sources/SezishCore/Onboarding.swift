import Foundation

// The first-run tour: permissions → engine → done. Ported from hex
// (anomalyco/hex@afb11de, src/desktop/onboarding.rs, MIT © 2026 Christopher
// Langton; see THIRD_PARTY_NOTICES.md). The model with its invariants and
// witnesses is `specs/tla/Onboarding.tla`; its header maps each action here.

public enum MicrophoneAccess: Sendable, Equatable {
    case notDetermined
    case denied
    case granted
}

public enum AccessibilityAccess: Sendable, Equatable {
    case off
    case on
    /// Trusted, but the shortcut listener would not start: macOS applies the
    /// grant to this process only after a relaunch.
    case needsRestart
}

/// What the 1 s permission poll saw.
public struct OnboardingStatus: Sendable, Equatable {
    public var microphone: MicrophoneAccess
    public var accessibility: AccessibilityAccess

    public init(microphone: MicrophoneAccess, accessibility: AccessibilityAccess) {
        self.microphone = microphone
        self.accessibility = accessibility
    }

    public var permissionsReady: Bool { microphone == .granted && accessibility == .on }
}

public enum OnboardingEngine: Sendable, Equatable {
    case cloud
    case local
}

public enum OnboardingModel: Sendable, Equatable {
    case missing
    case downloading(Double)
    case ready
    case failed
}

public enum OnboardingStep: Sendable, Equatable {
    case permissions
    case engine
    case done
    case finished
}

public enum PermissionKind: Sendable, Equatable {
    case microphone
    case accessibility
}

/// One permission row on the first screen.
public enum OnboardingRowStatus: Sendable, Equatable {
    case ready
    /// Not asked yet.
    case todo
    /// Asked; macOS's prompt or System Settings is up. The button reopens it.
    case waiting
    /// Back from System Settings and still off: offer "Still grey? Fix it".
    case stale
    /// Refused once: only System Settings can turn it on.
    case denied
    /// Switched on; applies once the app restarts.
    case restart
}

public struct OnboardingRows: Sendable, Equatable {
    public var microphone: OnboardingRowStatus
    public var accessibility: OnboardingRowStatus
}

public enum OnboardingInput: Sendable, Equatable {
    case status(OnboardingStatus)
    case model(OnboardingModel)
    case grantMicrophone
    /// `trustedNow` is `AXIsProcessTrusted()` read at the click, so a grant that
    /// landed after the last poll is never reset.
    case grantAccessibility(trustedNow: Bool)
    case chooseEngine(OnboardingEngine)
    case retryDownload
    case `continue`
    case back
    /// The shortcut listener would not start although Accessibility is on.
    /// `relaunchAllowed` comes from `OnboardingRelaunchGuard`.
    case listenerFailed(relaunchAllowed: Bool)
    /// "Restart" pressed after the guard held the automatic relaunch back.
    case reopen
}

public enum OnboardingEffect: Sendable, Equatable {
    case none
    case requestMicrophone
    /// Open the privacy pane with the guide beside it.
    case showGuide(PermissionKind)
    /// `tccutil reset Accessibility <bundle>`, then the prompt and guide again.
    case resetAccessibility
    case downloadModel
    /// Every permission just turned on: move on after a beat, so the last
    /// check is seen. The host sends `.continue` then.
    case advanceSoon
    case relaunch
    /// Close the tour.
    case finish
}

public struct OnboardingFlow: Sendable {
    public private(set) var step: OnboardingStep
    public private(set) var status: OnboardingStatus
    public private(set) var engine: OnboardingEngine
    public private(set) var model: OnboardingModel
    /// The listener needs a restart the tour will not do by itself again.
    public private(set) var reopen = false

    private var askedMicrophone = false
    private var askedAccessibility = false
    private var microphoneGuide = false
    private var accessibilityStale = false
    private var advanceDue = false
    private var relaunching = false

    /// `status` is read fresh at launch, so a tour resumed after a relaunch sees
    /// grants that are now real and skips a permissions screen that passes.
    public init(status: OnboardingStatus, engine: OnboardingEngine, model: OnboardingModel) {
        self.status = status
        self.engine = engine
        self.model = model
        step = status.permissionsReady ? .engine : .permissions
    }

    /// The tour opens at launch only when dictation could not work yet.
    public static func needed(status: OnboardingStatus, engine: OnboardingEngine,
                              model: OnboardingModel) -> Bool {
        !status.permissionsReady || !engineReady(engine: engine, model: model)
    }

    public var engineReady: Bool { Self.engineReady(engine: engine, model: model) }

    private static func engineReady(engine: OnboardingEngine, model: OnboardingModel) -> Bool {
        engine == .cloud || model == .ready
    }

    public var rows: OnboardingRows {
        let microphone: OnboardingRowStatus = switch status.microphone {
        case .granted: .ready
        case .denied: microphoneGuide ? .waiting : .denied
        case .notDetermined: askedMicrophone ? .waiting : .todo
        }
        let accessibility: OnboardingRowStatus = switch status.accessibility {
        case .on: .ready
        case .needsRestart: .restart
        case .off where askedAccessibility && accessibilityStale: .stale
        case .off where askedAccessibility: .waiting
        case .off: .todo
        }
        return OnboardingRows(microphone: microphone, accessibility: accessibility)
    }

    /// Marks Accessibility stale once the host's `StalePermissionTracker` fires.
    public mutating func setAccessibilityStale(_ stale: Bool) {
        accessibilityStale = stale && askedAccessibility && status.accessibility == .off
    }

    public mutating func on(_ input: OnboardingInput) -> OnboardingEffect {
        guard step != .finished else { return .none }
        switch input {
        case .status(let status): return update(status)
        case .model(let model):
            self.model = model
            return autoDownload()
        case .grantMicrophone: return grantMicrophone()
        case .grantAccessibility(let trustedNow): return grantAccessibility(trustedNow: trustedNow)
        case .chooseEngine(let engine):
            guard step == .engine || step == .done else { return .none }
            self.engine = engine
            return engine == .local ? startDownload() : .none
        case .retryDownload:
            guard engine == .local, model == .failed else { return .none }
            return startDownload()
        case .continue: return primary()
        case .back:
            switch step {
            case .done: step = .engine
            case .engine: step = .permissions
            case .permissions, .finished: break
            }
            return .none
        case .listenerFailed(let relaunchAllowed):
            if relaunchAllowed { return relaunch() }
            reopen = true
            return .none
        case .reopen:
            return reopen ? relaunch() : .none
        }
    }

    // MARK: - Steps

    private mutating func update(_ status: OnboardingStatus) -> OnboardingEffect {
        let wasReady = self.status.permissionsReady
        self.status = status
        if status.accessibility != .off { accessibilityStale = false }
        if status.microphone == .granted { microphoneGuide = false }
        // A grant turned off mid-tour sends the person back to it.
        if step == .engine || step == .done, !status.permissionsReady { step = .permissions }
        if step == .permissions, !wasReady, status.permissionsReady { advanceDue = true }
        // The download is returned first; the advance waits for the next poll.
        let download = autoDownload()
        if download != .none { return download }
        if advanceDue, step == .permissions {
            advanceDue = false
            return .advanceSoon
        }
        advanceDue = false
        return .none
    }

    private mutating func primary() -> OnboardingEffect {
        switch step {
        case .permissions:
            guard status.permissionsReady else { return .none }
            step = .engine
        case .engine:
            step = .done
        case .done:
            guard status.permissionsReady, engineReady else { return .none }
            step = .finished
            return .finish
        case .finished:
            break
        }
        return .none
    }

    private mutating func grantMicrophone() -> OnboardingEffect {
        guard step == .permissions else { return .none }
        askedMicrophone = true
        switch status.microphone {
        case .granted: return .none
        case .notDetermined: return .requestMicrophone
        case .denied:
            microphoneGuide = true
            return .showGuide(.microphone)
        }
    }

    private mutating func grantAccessibility(trustedNow: Bool) -> OnboardingEffect {
        guard step == .permissions, status.accessibility == .off else { return .none }
        askedAccessibility = true
        guard accessibilityStale else { return .showGuide(.accessibility) }
        accessibilityStale = false
        if trustedNow {
            // The grant landed after the last poll: take it, never reset it.
            status.accessibility = .on
            return .none
        }
        return .resetAccessibility
    }

    // MARK: - Model

    /// A selected local engine without its model downloads on any screen, so
    /// it runs while the person reads.
    private mutating func autoDownload() -> OnboardingEffect {
        guard engine == .local, model == .missing else { return .none }
        return startDownload()
    }

    private mutating func startDownload() -> OnboardingEffect {
        switch model {
        case .missing, .failed:
            model = .downloading(0)
            return .downloadModel
        case .downloading, .ready:
            return .none
        }
    }

    // MARK: - Relaunch

    /// Once per tour: a grant that never reaches the app cannot loop.
    private mutating func relaunch() -> OnboardingEffect {
        guard !relaunching, status.accessibility != .off else { return .none }
        relaunching = true
        reopen = false
        return .relaunch
    }
}

// MARK: - "Still grey? Fix it"

public struct SettingsFocus: Sendable, Equatable {
    public var settingsOpen: Bool
    public var settingsFrontmost: Bool
    public var appActive: Bool

    public init(settingsOpen: Bool, settingsFrontmost: Bool, appActive: Bool) {
        self.settingsOpen = settingsOpen
        self.settingsFrontmost = settingsFrontmost
        self.appActive = appActive
    }
}

/// Tracks an asked Accessibility grant across System Settings focus changes so
/// "Still grey? Fix it" shows only after the person went to System Settings,
/// came back (or closed it), and the app is still untrusted. Time is passed in
/// (monotonic seconds), never read here.
public struct StalePermissionTracker: Sendable {
    /// How long after the return an asked permission must stay off.
    public static let returnDelay: TimeInterval = 2
    /// Fallback when System Settings stays side by side without taking focus
    /// (tiling window managers) while the app stays active and untrusted.
    public static let sideBySideDelay: TimeInterval = 6

    private var askedAt: TimeInterval?
    private var sawSettings = false
    private var returnedAt: TimeInterval?
    private var stale = false

    public init() {}

    public var isWaiting: Bool { askedAt != nil }

    public mutating func noteAsked(now: TimeInterval) {
        askedAt = now
        sawSettings = false
        returnedAt = nil
        stale = false
    }

    public mutating func clear() { self = Self() }

    public mutating func poll(now: TimeInterval, untrusted: Bool, focus: SettingsFocus) -> Bool {
        guard untrusted else {
            clear()
            return false
        }
        guard let askedAt else { return false }
        if stale { return true }
        // System Settings open and the app inactive (Touch ID or password
        // sheets, dragging from Finder): the person has not come back yet.
        if focus.settingsOpen, focus.settingsFrontmost || !focus.appActive {
            sawSettings = true
            returnedAt = nil
            return false
        }
        if sawSettings {
            let returned = returnedAt ?? now
            returnedAt = returned
            if now - returned >= Self.returnDelay { stale = true }
        } else if focus.appActive, now - askedAt >= Self.sideBySideDelay {
            stale = true
        }
        return stale
    }
}

/// Result of `/usr/bin/tccutil reset`. Exit code 64 (`-10814`, no bundle on
/// disk outside the Trash) means System Settings already hides the row.
public enum TccResetOutcome: Sendable, Equatable {
    case cleared
    case nothingToClear
    case failed

    public init(exitCode: Int32, stderr: String) {
        if exitCode == 0 {
            self = .cleared
        } else if exitCode == 64 || stderr.contains("-10814")
                    || stderr.contains("No such bundle identifier") {
            self = .nothingToClear
        } else {
            self = .failed
        }
    }
}

// MARK: - Relaunch guard

/// A relaunch the tour started less than two minutes ago blocks another one,
/// and the tour resumes once right after it. Kept in files so it survives the
/// relaunch itself; time is passed in.
public struct OnboardingRelaunchGuard: Sendable {
    public static let window: TimeInterval = 120

    private let stamp: URL
    private let consumed: URL

    public init(directory: URL) {
        stamp = directory.appendingPathComponent("onboarding-relaunch")
        consumed = directory.appendingPathComponent("onboarding-resume-consumed")
    }

    public func record(now: Date) throws {
        try FileManager.default.createDirectory(
            at: stamp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try String(now.timeIntervalSince1970).write(to: stamp, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: consumed)
    }

    public func allowed(now: Date) -> Bool {
        guard let at = read(stamp) else { return true }
        return now.timeIntervalSince1970 - at >= Self.window
    }

    /// True once after a recent relaunch: the tour reopens where it was.
    public func takeResume(now: Date) -> Bool {
        guard let at = read(stamp), now.timeIntervalSince1970 - at < Self.window,
              read(consumed) != at else { return false }
        try? String(at).write(to: consumed, atomically: true, encoding: .utf8)
        return true
    }

    private func read(_ url: URL) -> TimeInterval? {
        (try? String(contentsOf: url, encoding: .utf8))
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
