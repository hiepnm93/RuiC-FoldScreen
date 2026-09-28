import AppKit
import Combine
import CoreVideo
import Foundation
import MetalKit
import ScreenCaptureKit
import SwiftUI

/// Holds the user's fold settings and writes them back as they change.
///
/// Settings live here rather than inside the effect so the live overlay, the
/// settings preview, and the UI all read one source of truth, and so the effect
/// can be torn down and rebuilt without losing what the user chose.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: FoldSettings {
        didSet {
            guard !isNormalizing else { return }
            let clamped = settings.clamped()
            if clamped != settings {
                isNormalizing = true
                settings = clamped
                isNormalizing = false
            }
            settings.save(to: defaults)
        }
    }

    private let defaults: UserDefaults
    private var isNormalizing = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = FoldSettings.load(from: defaults)
    }

    func reset() {
        settings = .default
    }
}

/// Drives the live effect: reads the lid, captures the desktop, folds it, and
/// puts it on screen.
///
/// Everything time-sensitive lives here. The class is deliberately the only
/// place that knows the order in which capture, renderer, overlay, and hot key
/// have to come up and go down.
@MainActor
final class LiveFold: ObservableObject {

    /// What the effect is doing right now, as the UI needs to describe it.
    enum State: Equatable {
        case off
        case starting
        case live
        /// Capture was refused; the user has to grant screen recording.
        case needsPermission
        case noSensor
        case noDisplay

        var isRunning: Bool { self == .live }
    }

    @Published private(set) var state: State = .off
    /// Latest lid angle, or `nil` while the sensor has nothing to report.
    @Published private(set) var lidAngle: Double?
    /// Current closure fraction, for the menu bar and diagnostics.
    @Published private(set) var closure: Double = 0
    /// What the user asked for, which survives relaunches.
    @Published private(set) var isEnabled = false
    @Published private(set) var openAtLogin = false
    /// The raw screen recording grant, mirrored for the settings UI.
    @Published private(set) var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    /// One line of human-readable status for the settings window.
    @Published private(set) var detail = "Not enabled yet. Flip the switch and closing the lid folds the screen."

    let store: SettingsStore

    private let sensor: LidAngleSource
    private let mirror: DesktopFrames
    private let frames = FrameStore()
    private let overlay = OverlaySurface()
    private let hotKey = EscapeHotKey()

    private var renderer: FoldRenderer?
    private var metalView: MTKView?
    private var ticker: Timer?
    private var lastTick = CACurrentMediaTime()
    /// Invalidates in-flight async work when the effect is stopped or restarted.
    private var generation = 0
    private var isStopping = false
    private var reconnectTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    /// Consecutive capture failures seen while the grant was present.
    private var failuresSinceGrant = 0
    private var isAsleep = false
    private var didFold = false

    private let defaults: UserDefaults

    init(store: SettingsStore, sensor: LidAngleSource? = nil, mirror: DesktopFrames? = nil,
         defaults: UserDefaults = .standard)
    {
        self.store = store
        self.defaults = defaults
        self.sensor = sensor ?? HIDLidAngleSource()
        self.mirror = mirror ?? ScreenCaptureMirror()
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.openAtLogin = LoginItem.isEnabled

        self.sensor.onAngle = { [weak self] angle in
            guard let self else { return }
            if self.lidAngle != angle { self.lidAngle = angle }
            // Losing the sensor while the effect is live means the lid just shut
            // or the machine is mid-sleep: either way the effect has to pause.
            if angle == nil, self.state == .live, self.store.settings.followLid {
                self.interrupt("Timed out waiting for the lid-angle sensor.")
            }
        }
        self.mirror.onFrame = { [weak self] buffer in
            self?.frames.put(buffer)
        }
        self.mirror.onFailure = { [weak self] error in
            Task { @MainActor in
                self?.interrupt("Screen capture interrupted: \(error.localizedDescription)")
            }
        }

        self.sensor.start()
        observeSystemEvents()
    }

    // MARK: - Intent

    func setEnabled(_ enabled: Bool) {
        if enabled {
            enable()
        } else {
            disable()
        }
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    func enable() {
        guard !isEnabled, state != .starting, !isStopping, !isAsleep else { return }
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        start()
    }

    func disable(message: String = "Paused. Desktop restored.") {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        stop(message: message)
    }

    /// Pauses because of an external event, remembering that the user still
    /// wants the effect so it can come back by itself.
    private func interrupt(_ message: String) {
        guard isEnabled else { return }
        // A missing grant is not something retrying can fix, and the capture
        // stack answers every attempt with a system notification. Retrying here
        // is what made the app nag for screen recording over and over.
        guard !isBlockedOnPermission else { return }
        stop(message: message)
        scheduleReconnect()
    }

    /// True while the effect is parked waiting for screen recording access.
    private var isBlockedOnPermission: Bool { state == .needsPermission }

    // MARK: - Lifecycle

    private func start() {
        guard let screen = Self.builtInScreen() else {
            state = .noDisplay
            detail = "No built-in display found; the effect only applies to the laptop's own screen."
            return
        }
        guard let displayID = Self.displayID(of: screen) else {
            state = .noDisplay
            detail = "Could not read the built-in display's identifier."
            return
        }
        // Following the lid is pointless without a sensor, and silently doing
        // nothing is worse than saying so. This asks whether the device exists
        // rather than whether a reading has arrived: at launch the first poll is
        // still in flight, and treating that as missing hardware made the effect
        // refuse to start on a Mac that has a perfectly good sensor.
        if store.settings.followLid && !sensor.isAvailable {
            state = .noSensor
            detail = "No lid-angle sensor found. Turn off Follow Physical Lid in Lid and use a manual angle instead."
            return
        }

        state = .starting
        detail = "Connecting to the desktop…"
        generation += 1
        let request = generation

        Task {
            do {
                try await mirror.start(displayID: displayID)
                guard request == generation else { return }

                let renderer = try existingOrNewRenderer()
                renderer.scene = { [weak self] in
                    guard let self else {
                        return FoldRenderer.Scene(uniforms: FoldUniforms(), source: nil)
                    }
                    let settings = self.store.settings
                    // The live overlay never uses the preview artwork, so a
                    // missing capture must show as black rather than a still.
                    var uniforms = FoldTuning.uniforms(
                        closure: self.closure, settings: settings, aspect: 1.6,
                        workingWidth: Self.workingWidth)
                    uniforms.aspect = 1.6
                    return FoldRenderer.Scene(
                        uniforms: uniforms, source: self.frames.current())
                }

                let view = renderer.makeView()
                view.isPaused = true
                overlay.present(contentView: view, on: screen)
                overlay.conceal()
                metalView = view

                state = .live
                hasScreenRecordingPermission = true
                failuresSinceGrant = 0
                closure = 0
                didFold = false
                sensor.setPolling(active: true)
                detail = "Connected. Try closing the lid gently."
                startTicking()

            } catch is CancellationError {
                // Superseded by a newer start or stop; nothing to report.
            } catch {
                guard request == generation else { return }
                await mirror.stop()
                // Only treat this as a permission problem when the grant really
                // is missing. Anything else is transient and worth one bounded
                // round of retries; a missing grant is not, because each attempt
                // makes the system put up another recording notice.
                hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
                if hasScreenRecordingPermission {
                    // The grant is there, so this is the case where macOS has
                    // recorded the permission but will not honour it in this
                    // process. Retrying a couple of times is worth it; past that
                    // only a relaunch helps, and saying so beats looping.
                    failuresSinceGrant += 1
                    state = .off
                    if failuresSinceGrant >= 3 {
                        detail = """
                            The system recorded the permission but capture still fails. macOS sometimes needs an app restart for it to apply; \
                            click Reopen above.
                            """
                    } else {
                        detail = "Failed to start screen capture: \(error.localizedDescription)"
                        scheduleReconnect()
                    }
                } else {
                    failuresSinceGrant = 0
                    state = .needsPermission
                    detail = """
                        Screen recording permission not granted yet. Open System Settings → Privacy & Security → \
                        Screen & System Audio Recording and check RuiC-FoldScreen; it reconnects once granted.
                        """
                    watchForPermission()
                }
            }
        }
    }

    private func stop(message: String) {
        reconnectTask?.cancel()
        reconnectTask = nil
        permissionTask?.cancel()
        permissionTask = nil
        generation += 1
        closure = 0
        sensor.setPolling(active: false)
        hotKey.unregister()
        overlay.dismiss()
        metalView?.isPaused = true
        metalView = nil
        state = .off
        detail = message

        guard !isStopping else { return }
        isStopping = true
        Task {
            await mirror.stop()
            frames.clear()
            isStopping = false
        }
    }

    private func existingOrNewRenderer() throws -> FoldRenderer {
        if let renderer { return renderer }
        let renderer = try FoldRenderer(previewImage: PreviewArtwork.make())
        self.renderer = renderer
        return renderer
    }

    /// Waits quietly for screen recording to be granted, then brings the effect up.
    ///
    /// This polls `CGPreflightScreenCaptureAccess`, which only reads the current
    /// answer and never touches the capture stack. That distinction is the whole
    /// point: asking the capture stack for content is what makes macOS put up a
    /// recording notice, so retrying `start()` in a loop is what turned a missing
    /// permission into an endless stream of prompts. A preflight query cannot do
    /// that, so the app can wait as long as it likes without nagging.
    private func watchForPermission() {
        permissionTask?.cancel()
        guard isEnabled else { return }
        permissionTask = Task { [weak self] in
            // Ten minutes at two-second intervals. Silent and cheap, so a long
            // wait costs a timer and nothing else.
            for _ in 0..<300 {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self, self.isEnabled, self.isBlockedOnPermission else { return }
                if CGPreflightScreenCaptureAccess() {
                    self.start()
                    return
                }
            }
        }
    }

    /// Re-reads the screen recording grant right now.
    ///
    /// Backs the button in settings, so the user can say "I have granted it, try
    /// again" rather than waiting for the poll or relaunching.
    func recheckPermission() {
        guard isEnabled else { return }
        refreshPermissionStatus()
        guard hasScreenRecordingPermission else {
            detail = """
                The system still reports no screen recording permission. Open System Settings → Privacy & Security → \
                Screen & System Audio Recording and check RuiC-FoldScreen.
                """
            return
        }
        permissionTask?.cancel()
        permissionTask = nil
        state = .off
        start()
    }

    /// Quits and reopens the app.
    ///
    /// Worth having as a button because macOS does not always honour a freshly
    /// granted capture permission in a running process; a relaunch is the
    /// documented workaround, and asking the user to find the app again is worse
    /// than doing it for them.
    func relaunch() {
        let url = Bundle.main.bundleURL
        disable(message: "Reopening…")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// Retries for a while after sleep, a display change, or a refused start.
    ///
    /// Wake notifications routinely arrive before the display and the HID device
    /// are back, so a single attempt would simply fail.
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        guard isEnabled, !isAsleep, !isBlockedOnPermission else { return }
        reconnectTask = Task { [weak self] in
            for _ in 0..<15 {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, self.isEnabled, !self.isAsleep else { return }
                guard !self.isStopping, self.state != .starting else { continue }
                if self.store.settings.followLid && !self.sensor.isAvailable {
                    self.sensor.reconnect()
                    continue
                }
                guard Self.builtInScreen() != nil else { continue }
                self.start()
                return
            }
            self?.detail = "Automatic reconnect failed. Please enable it manually again."
        }
    }

    // MARK: - Frame loop

    /// Runs only while the effect is live, so an idle menu bar app never wakes
    /// the CPU sixty times a second.
    private func startTicking() {
        guard ticker == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard state == .live else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        let now = CACurrentMediaTime()
        let elapsed = now - lastTick
        lastTick = now

        let settings = store.settings
        let angle = settings.followLid ? (lidAngle ?? settings.clearAngle) : settings.manualAngle
        let target = FoldKinematics.closure(angle: angle, clearAngle: settings.clearAngle)

        // Respect Reduce Motion: jump straight to the target instead of easing,
        // which also means the fold cannot induce motion sickness.
        closure =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? target
            : FoldKinematics.approach(current: closure, target: target, dt: elapsed)

        let visible = closure > 0.0005
        if visible && !overlay.isVisible {
            metalView?.isPaused = false
            overlay.show()
            hotKey.register { [weak self] in
                self?.disable(message: "Paused with Escape.")
            }
            Task { await mirror.setHighRate(true) }
        } else if !visible && overlay.isVisible {
            overlay.conceal()
            metalView?.isPaused = true
            hotKey.unregister()
            Task { await mirror.setHighRate(false) }
        }

        if closure > 0.15 { didFold = true }
        if closure == 0 && didFold {
            didFold = false
            if settings.sound { NSSound(named: "Tink")?.play() }
        }
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAsleep = true
                self.interrupt("Paused for sleep; resumes automatically on wake.")
            }
        }
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAsleep = false
                self.lidAngle = nil
                self.sensor.reconnect()
                self.scheduleReconnect()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                self.interrupt("Display configuration changed; reconnecting…")
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshLoginItem()
                self?.refreshPermissionStatus()
            }
        }
    }

    /// Called at launch: brings the effect back if it was on when the app quit.
    func restoreIfNeeded() {
        guard isEnabled else { return }
        scheduleReconnect()
    }

    /// Brings the effect up regardless of what was persisted.
    ///
    /// The `--smoke` check needs the live path running on demand, and going
    /// through `enable()` alone is not enough: a previous run may have left the
    /// effect already marked as enabled, in which case `enable()` returns
    /// immediately and nothing starts.
    func startForDiagnostics() {
        if !isEnabled {
            enable()
        } else if state == .off {
            scheduleReconnect()
            start()
        }
    }

    func refreshLoginItem() {
        openAtLogin = LoginItem.isEnabled
    }

    /// Re-reads the screen recording grant. Called when the app becomes active,
    /// which is exactly when the user has usually just come back from granting it.
    func refreshPermissionStatus() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func setOpenAtLogin(_ enabled: Bool) {
        if let problem = LoginItem.setEnabled(enabled) { detail = problem }
        refreshLoginItem()
    }

    func noteSettingsChanged() {
        // Nothing to rebuild: the renderer reads settings every frame.
    }

    // MARK: - Diagnostics

    /// A one-shot summary of the live path, for the `--smoke` check.
    ///
    /// Deliberately reports whatever state it finds rather than only the happy
    /// path, because the interesting failures here are permission and hardware,
    /// not crashes.
    func diagnosticReport() async -> String {
        var lines: [String] = []
        lines.append("state=\(state)")
        lines.append("detail=\(detail)")
        lines.append("enabled=\(isEnabled)")
        lines.append("closure=\(String(format: "%.4f", closure))")
        lines.append(
            "lidAngle=\(lidAngle.map { String(format: "%.0f", $0) } ?? "none")")
        lines.append("overlayVisible=\(overlay.isVisible)")
        lines.append("renderer=\(renderer == nil ? "none" : "ready")")
        lines.append("builtInScreen=\(Self.builtInScreen() != nil)")
        if let mirror = mirror as? ScreenCaptureMirror {
            lines.append("capturedFrames=\(mirror.frameCount)")
        }

        // Ask the capture stack directly so a permission problem is reported as
        // a permission problem rather than as a generic failure.
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            lines.append("shareableContent=ok displays=\(content.displays.count)")
        } catch {
            lines.append("shareableContent=FAILED \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    private static let enabledKey = "effect.enabled"

    /// The effect only ever targets the laptop's own panel. Driving an external
    /// display would fold a screen whose lid is not the thing being closed.
    private static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = displayID(of: screen) else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    /// Blur radius is expressed against this width, matching the renderer's cap.
    private static let workingWidth: Double = 512
}
