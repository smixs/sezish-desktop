import AppKit
import SwiftUI

/// The compact tour window (~560×480, like Settings). One per process; closing it
/// early is fine — the tour opens again at the next launch while something is missing.
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private(set) var controller: OnboardingController?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(appState: AppState) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = OnboardingController(appState: appState)
        controller.onFinish = { [weak self] in self?.close() }
        let root = OnboardingView(controller: controller).environment(appState)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = controller.strings.windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.delegate = self
        window.center()
        self.window = window
        self.controller = controller
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        PermissionGuide.shared.close()
        window = nil
        controller = nil
    }
}
