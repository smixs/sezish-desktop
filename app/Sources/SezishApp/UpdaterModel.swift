import AppKit
import Combine
import Sparkle
import SwiftUI

/// Owns the Sparkle updater for the process lifetime (instantiated once by
/// AppDelegate). Sparkle drives its own UI via the standard user driver; this
/// wrapper only exposes what the menu row needs and handles LSUIElement
/// activation quirks.
final class UpdaterModel: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Passthrough for the Settings "check automatically" toggle (wave 2 binds to it).
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        // LSUIElement app: without activation Sparkle's window can open behind
        // the frontmost app and there is no Dock icon to find it by.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

extension UpdaterModel: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
