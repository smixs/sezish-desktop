import AppKit
import ApplicationServices
import AVFoundation
import CoreImage
import QuartzCore
import SezishCore

// Ported from hex (anomalyco/hex@afb11de, native/permission_guide.m, MIT © 2026
// Christopher Langton; see THIRD_PARTY_NOTICES.md): a panel docked to System
// Settings with the app's tile to drag into the privacy list, and a copy of the
// tile that flies from the click to the panel so the eye follows it there.

/// Where System Settings is relative to the person, for `StalePermissionTracker`.
@MainActor
enum SystemSettingsWindow {
    static let bundleID = "com.apple.systempreferences"

    static var focus: SettingsFocus {
        SettingsFocus(
            settingsOpen: hasWindow,
            settingsFrontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID,
            appActive: NSApp.isActive
        )
    }

    static var hasWindow: Bool {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.processIdentifier else { return false }
        return windows().contains {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
    }

    /// The largest on-screen System Settings window, in Quartz coordinates.
    static var frame: CGRect? {
        var best: CGRect?
        for window in windows() {
            let owner = window[kCGWindowOwnerName as String] as? String
            guard owner == "System Settings" || owner == "System Preferences",
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 300, rect.height >= 200 else { continue }
            if best.map({ rect.width * rect.height > $0.width * $0.height }) ?? true { best = rect }
        }
        return best
    }

    private static func windows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
    }

    private static var request = 0

    /// Opens a privacy pane. A System Settings that isn't running yet drops the pane
    /// while it restores the last one, so after a cold launch the URL goes again
    /// once its window is up and settled.
    static func open(pane: String) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") else { return }
        let cold = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        request += 1
        let mine = request
        NSWorkspace.shared.open(url)
        guard cold else { return }
        Task { @MainActor in
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(100))
                guard mine == request else { return }
                guard hasWindow else { continue }
                for delay in [0.35, 0.85] { // 0.35 s, then 1.2 s after the window
                    try? await Task.sleep(for: .seconds(delay))
                    guard mine == request else { return }
                    NSWorkspace.shared.open(url)
                }
                return
            }
        }
    }
}

@MainActor
final class PermissionGuide {
    static let shared = PermissionGuide()

    private var panel: NSPanel?
    private var tile: NSView?
    private var timer: Timer?
    private var sawSettings = false
    private var kind: PermissionKind = .accessibility

    private var flightPanel: NSPanel?
    private var flightLayer: CALayer?
    private var flightTimer: Timer?
    private var flightOrigin: NSPoint = .zero
    private var flightShownAt: CFTimeInterval = 0
    private var flightStartedAt: CFTimeInterval = 0
    private static let flightPadding: CGFloat = 40
    private static let flightLift: CFTimeInterval = 0.18
    private static let flightDuration: CFTimeInterval = 0.62
    /// A System Settings that has not opened by then gets no flight.
    private static let flightPatience: CFTimeInterval = 4

    /// Opens the pane for `kind` with the guide docked to it. `text` is the line
    /// above the tile, already localized.
    func show(_ kind: PermissionKind, text: String) {
        let click = NSEvent.mouseLocation
        let fly = clickInAppWindow(click) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        close()
        self.kind = kind
        SystemSettingsWindow.open(pane: kind == .accessibility ? "Privacy_Accessibility" : "Privacy_Microphone")

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        // A loose development binary has no bundle to list: the pane alone.
        guard bundleURL.pathExtension.lowercased() == "app" else { return }
        // The Microphone list only holds apps that asked, so it is switched on, not dragged in.
        let draggable = kind == .accessibility

        let size = NSSize(width: 480, height: draggable ? 116 : 60)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        content.layer?.cornerRadius = 20
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(white: 0, alpha: 0.10).cgColor

        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
            ?? NSImage())
        arrow.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        arrow.contentTintColor = NSColor(Brand.accent)
        arrow.frame = NSRect(x: 18, y: draggable ? 75 : 20, width: 16, height: 20)
        content.addSubview(arrow)

        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 42, y: draggable ? 73 : 18, width: size.width - 60, height: 24)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        content.addSubview(label)

        if draggable {
            let drag = AppTileDragView(frame: NSRect(x: 18, y: 17, width: size.width - 36, height: 44),
                                       bundleURL: bundleURL)
            content.addSubview(drag)
            tile = drag
        }
        panel.contentView = content
        self.panel = panel
        if draggable, fly, let tile {
            tile.isHidden = true
            panel.alphaValue = 0
            beginFlight(from: click, bundleURL: bundleURL, tileSize: tile.frame.size)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePosition() }
        }
        updatePosition()
    }

    func close() {
        endFlight()
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        tile = nil
        sawSettings = false
    }

    // MARK: - Docking

    private var granted: Bool {
        switch kind {
        case .accessibility: AXIsProcessTrusted()
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    private func updatePosition() {
        guard let panel else { return }
        if granted { close(); return }
        guard let quartz = SystemSettingsWindow.frame else {
            if sawSettings { close() }
            return
        }
        sawSettings = true
        let settings = Self.appKitFrame(quartz)
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(settings) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? settings
        var x = settings.maxX - size.width - 16
        var y = settings.minY + 16
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        if flightPanel != nil, flightStartedAt == 0 { flightStartedAt = CACurrentMediaTime() }
        panel.orderFrontRegardless()
    }

    private static func appKitFrame(_ frame: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return frame }
        return NSRect(x: frame.minX, y: primary.frame.height - frame.minY - frame.height,
                      width: frame.width, height: frame.height)
    }

    private func clickInAppWindow(_ point: NSPoint) -> Bool {
        NSApp.windows.contains {
            $0.isVisible && $0 !== panel && $0 !== flightPanel && $0.frame.contains(point)
        }
    }

    // MARK: - Flight

    private func beginFlight(from origin: NSPoint, bundleURL: URL, tileSize: NSSize) {
        flightOrigin = origin
        flightShownAt = CACurrentMediaTime()
        flightStartedAt = 0
        let icon = AppTileDragView.icon(for: bundleURL)
        let name = AppTileDragView.name(for: bundleURL)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let image = NSImage(size: tileSize, flipped: false) { rect in
            AppTileDragView.drawTile(in: rect, icon: icon, name: name, dark: dark)
            return true
        }

        let pad = Self.flightPadding
        let size = NSSize(width: tileSize.width + 2 * pad, height: tileSize.height + 2 * pad)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.layer = CALayer()
        host.wantsLayer = true
        host.layerUsesCoreImageFilters = true
        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: tileSize)
        layer.position = CGPoint(x: size.width / 2, y: size.height / 2)
        layer.contents = image
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        // A tile lifted off the page casts a real shadow: offset and soft blur.
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: -6)
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "blur"
            blur.setValue(0, forKey: kCIInputRadiusKey)
            layer.filters = [blur]
        }
        host.layer?.addSublayer(layer)
        panel.contentView = host
        flightPanel = panel
        flightLayer = layer

        place(at: origin, scale: 0.7, blur: 4, opacity: 0)
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepFlight() }
        }
        RunLoop.main.add(timer, forMode: .common)
        flightTimer = timer
    }

    private func place(at center: NSPoint, scale: CGFloat, blur: CGFloat, opacity: CGFloat) {
        guard let flightPanel, let flightLayer else { return }
        let size = flightPanel.frame.size
        flightPanel.setFrameOrigin(NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flightLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        flightLayer.opacity = Float(opacity)
        flightLayer.setValue(blur, forKeyPath: "filters.blur.inputRadius")
        CATransaction.commit()
    }

    private func stepFlight() {
        let now = CACurrentMediaTime()
        if flightStartedAt == 0 {
            // Lifted out of the row, waiting for System Settings to open.
            if now - flightShownAt > Self.flightPatience { endFlight(); return }
            let t = Self.easeOutCubic(Self.clamp01((now - flightShownAt) / Self.flightLift))
            place(at: NSPoint(x: flightOrigin.x, y: flightOrigin.y + 12 * t),
                  scale: 0.7 + 0.1 * t, blur: 4 * (1 - t), opacity: t)
            return
        }
        guard let panel, let tile else { endFlight(); return }
        let t = Self.clamp01((now - flightStartedAt) / Self.flightDuration)
        let e = Self.easeInOutCubic(t)
        let start = NSPoint(x: flightOrigin.x, y: flightOrigin.y + 12)
        let slot = panel.convertToScreen(tile.convert(tile.bounds, to: nil))
        let end = NSPoint(x: slot.midX, y: slot.midY)
        let distance = hypot(end.x - start.x, end.y - start.y)
        let control = NSPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + min(160, distance * 0.25))
        let u = 1 - e
        let point = NSPoint(x: u * u * start.x + 2 * u * e * control.x + e * e * end.x,
                            y: u * u * start.y + 2 * u * e * control.y + e * e * end.y)
        place(at: point, scale: 0.8 + 0.2 * e, blur: 6 * sin(.pi * e), opacity: 1)
        panel.alphaValue = Self.easeOutCubic(Self.clamp01((t - 0.45) / 0.55))
        if t >= 1 { endFlight() }
    }

    private func endFlight() {
        flightTimer?.invalidate()
        flightTimer = nil
        flightPanel?.orderOut(nil)
        flightPanel = nil
        flightLayer = nil
        tile?.isHidden = false
        panel?.alphaValue = 1
    }

    private static func clamp01(_ v: Double) -> CGFloat { CGFloat(min(max(v, 0), 1)) }
    private static func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
    private static func easeOutCubic(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }
}

/// The app's tile as System Settings will list it; dragging it drops the bundle
/// into the privacy list.
private final class AppTileDragView: NSView, NSDraggingSource {
    private let bundleURL: URL
    private let appIcon: NSImage
    private let appName: String
    private var mouseDownEvent: NSEvent?

    init(frame: NSRect, bundleURL: URL) {
        self.bundleURL = bundleURL
        appIcon = Self.icon(for: bundleURL)
        appName = Self.name(for: bundleURL)
        super.init(frame: frame)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func icon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }

    /// The name System Settings lists the app under.
    static func name(for url: URL) -> String {
        var name = FileManager.default.displayName(atPath: url.path)
        if (name as NSString).pathExtension.lowercased() == "app" {
            name = (name as NSString).deletingPathExtension
        }
        return name.isEmpty ? "sezish" : name
    }

    static func drawTile(in bounds: NSRect, icon: NSImage, name: String, dark: Bool) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor(white: dark ? 0.18 : 0.89, alpha: 1).setFill()
        background.fill()
        NSColor(white: dark ? 1 : 0, alpha: 0.10).setStroke()
        background.lineWidth = 1
        background.stroke()
        icon.draw(in: NSRect(x: 10, y: 6, width: 32, height: 32))
        (name as NSString).draw(at: NSPoint(x: 52, y: 14), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(white: dark ? 0.94 : 0.12, alpha: 1),
        ])
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        Self.drawTile(in: bounds, icon: appIcon, name: appName, dark: dark)
    }

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) >= 3 else { return }
        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            let snapshot = NSImage(size: bounds.size)
            snapshot.addRepresentation(rep)
            item.setDraggingFrame(bounds, contents: snapshot)
        }
        let session = beginDraggingSession(with: [item], event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        mouseDownEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
