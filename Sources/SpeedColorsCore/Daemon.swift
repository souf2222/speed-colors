// Daemon.swift — speedcolors daemon core.
//
// Full-ownership architecture (the Speed Editor HID device is strictly
// single-client: while we hold it, Resolve gets nothing — and the moment we
// release it, Resolve reclaims it automatically and goes back to stock):
//
//   • Cut/Edit/Media/Fairlight/Deliver pages → Resolve's own keyboard
//     shortcuts are injected, mirroring the native Speed Editor behavior.
//   • Color page → each button runs its CONFIGURED COMMAND SEQUENCE
//     (bindings from ~/.speedcolors/color.json):
//       goto → park cursor on a calibrated target
//       click → full click   · hold → mouse down until key release
//       key → inject shortcut   · wait → pause
//     The search dial drags whatever a "hold" step has pressed down.
//   • Keys are PID-targeted to Resolve, so dispatch only requires Resolve to
//     be RUNNING (frontmost is irrelevant).
//
// Quitting the daemon releases the device → Resolve instantly regains its
// native Speed Editor integration (proven: handoff outcome A).

import AppKit
import Foundation

public struct DaemonConfig: Sendable {
    /// Jog units accumulated before one arrow-key tap fires (calibrate from logs).
    public var jogUnitsPerArrow: Int
    /// Sensitivity multiplier per dial mode (last mode key pressed wins).
    public var sensitivity: [SpeedEditorKey: Int]

    public init(jogUnitsPerArrow: Int = 800,
                sensitivity: [SpeedEditorKey: Int] = [.jog: 1, .shtl: 4, .scrl: 8]) {
        self.jogUnitsPerArrow = jogUnitsPerArrow
        self.sensitivity = sensitivity
    }
}

public final class SpeedColorsDaemon {
    private let session = SpeedEditorSession()
    private let watcher = PageWatcher()
    private var config: DaemonConfig

    /// UI/observer hooks (called on the session thread — dispatch to main there).
    public var onLog: ((String) -> Void)?
    public var onDeviceStatus: ((Bool) -> Void)?
    public var onPageChange: ((String?) -> Void)?
    public var onKeysRaw: ((Set<SpeedEditorKey>) -> Void)?
    /// Search-dial runtime state, e.g. "JOG · dragging Wheel 1 · Lift".
    public var onDialState: ((String) -> Void)?
    public var onBattery: ((Bool, UInt8) -> Void)?

    private var currentPage: String?
    private var heldKeys: Set<SpeedEditorKey> = []
    private var dialModeKey: SpeedEditorKey?
    private var lastJogValue: Int32?
    private var jogBudget = 0
    private var lastBatteryLine: String?

    // Color-page drag state
    private(set) var colorConfig = ColorModeConfig.load()
    private var heldColorKey: SpeedEditorKey?
    private var heldColorPoint: CGPoint?
    private var heldTargetLabel: String?   // for the dial runtime line
    private var warnedHoldSkip = false
    private var mouseDownPoint: CGPoint?
    private var lastColorPoint: CGPoint?

    public init(config: DaemonConfig = DaemonConfig()) {
        self.config = config
        migrateBindings()
    }

    /// Saved cursor position (savepos/restorepos steps), one slot per daemon.
    private var savedColorPoint: CGPoint?
    /// Dial sensitivity multiplier in percent (100 = neutral; sens steps).
    private(set) var sensFactor: Int = 100

    /// First run against a pre-bindings config: synthesize the proven defaults.
    /// Only for a virgin Default profile — a deliberately empty user profile
    /// must stay empty.
    public func migrateBindings() {
        guard colorConfig.activeProfile == ColorModeConfig.defaultProfile,
              colorConfig.storedProfiles.isEmpty,
              colorConfig.bindings.isEmpty else { return }
        colorConfig.bindings = MacroDefaults.migrated()
        try? colorConfig.save()
        log("· synthesized default bindings (CAM1-4 = hold the primaries wheels)")
    }

    /// Re-read the config file (after the UI edited it).
    public func reloadColorConfig() {
        disarmColor()
        colorConfig = ColorModeConfig.load()
        config.jogUnitsPerArrow = colorConfig.jogUnitsPerArrow ?? 800
        log("· config reloaded (\(colorConfig.targets.count) targets, \(colorConfig.bindings.count) bindings)")
    }

    public func start() {
        session.onKey = { [weak self] keys in self?.handleKeys(keys) }
        session.onJog = { [weak self] mode, value in self?.handleJog(mode: mode, value: value) }
        session.onBattery = { [weak self] charging, level in
            let line = "battery \(level)%\(charging ? " (charging)" : "")"
            self?.onBattery?(charging, level)
            guard self?.lastBatteryLine != line else { return }
            self?.lastBatteryLine = line
            self?.log("· \(line)")
        }
        session.onLog = { [weak self] line in self?.log(line) }
        session.onStatusChange = { [weak self] connected in
            self?.onDeviceStatus?(connected)
            self?.log(connected
                      ? "✓ Speed Editor connected & authenticated"
                      : "⚠️  Speed Editor unavailable (unplugged? locked by Resolve?) — retrying…")
            fflush(stdout)
        }
        watcher.onPage = { [weak self] page in self?.handlePage(page) }
        watcher.start()
        session.start()
    }

    public func stop() {
        session.stop()
        watcher.stop()
        session.setPanelLeds([])
        session.setDialLeds([])
        disarmColor()
    }

    private func log(_ line: String) {
        print(line)
        fflush(stdout)
        onLog?(line)
    }

    // MARK: Page dispatch

    private func handlePage(_ page: String?) {
        let wasColor = currentPage == "color"
        currentPage = page
        let colorMode = page == "color"
        if colorMode { colorConfig = ColorModeConfig.load() }  // pick up fresh calibrations
        if wasColor && !colorMode { disarmColor() }
        session.setPanelLeds(colorMode ? [.snap] : [])
        let keys = colorConfig.bindings.keys.sorted().joined(separator: ", ")
        log("↻ page → \(page ?? "—")  \(colorMode ? "• COLOR MODE (\(colorConfig.bindings.count) bindings: \(keys))" : "(mirroring native shortcuts)")")
        onPageChange?(page)
    }

    /// Resolve's pid while the app is running — regardless of frontmost.
    ///
    /// Keys are PID-targeted so they always land in Resolve, and mouse events
    /// go through the cursor (a synthetic click activates the window under it,
    /// exactly like a real click). So requiring Resolve to be frontmost was
    /// both unnecessary and harmful: with the panel active, every SE press was
    /// blocked with "ignored (Resolve not frontmost)".
    private func resolvePid() -> pid_t? {
        if Thread.isMainThread { return _resolvePid() }
        var out: pid_t?
        DispatchQueue.main.sync { out = self._resolvePid() }
        return out
    }

    private func _resolvePid() -> pid_t? {
        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.blackmagic-design.DaVinciResolve").first {
            return app.processIdentifier
        }
        // Fallback in case of bundle-id drift: match by name substring.
        return NSWorkspace.shared.runningApplications.first { app in
            let b = app.bundleIdentifier?.lowercased() ?? ""
            let n = app.localizedName?.lowercased() ?? ""
            return b.contains("davinci") || n.contains("resolve")
        }?.processIdentifier
    }

    // MARK: Search-dial runtime state (for the UI line near the dial)

    private func notifyDialState() {
        let mode = (dialModeKey ?? .jog).label
        let state: String
        if heldColorPoint != nil {
            state = "\(mode) · dragging \(heldTargetLabel ?? "…")"
        } else {
            state = "\(mode) · idle"
        }
        onDialState?(state)
    }

    // MARK: Keys

    private func handleKeys(_ keys: [SpeedEditorKey]) {
        let current = Set(keys)
        let released = heldKeys.subtracting(current)
        let newlyPressed = current.subtracting(heldKeys)
        defer { heldKeys = current }
        onKeysRaw?(current)

        // Dial-mode keys select sensitivity, they are not injected.
        for k in newlyPressed where k == .shtl || k == .jog || k == .scrl {
            dialModeKey = k
            log("⏱  dial mode → \(k.label)")
            notifyDialState()
        }

        // Color page: release phase — mouse-up for a held drag plus the
        // key's configured "When released" sequence.
        if currentPage == "color" {
            for key in released {
                if key == heldColorKey { endHeldDrag() }
                let relSteps = colorConfig.released[key.id] ?? []
                guard !relSteps.isEmpty else { continue }
                if colorConfig.disabledBindings.contains(key.id) {
                    log("🎨 \(key.label) release sequence disabled — ignored")
                    continue
                }
                guard let pid = resolvePid() else { continue }
                log("🎨 ↩ \(key.label) released: \(relSteps.map(\.describe).joined(separator: " → "))")
                execute(steps: relSteps, key: key, pid: pid, releasePhase: true)
            }
        }

        // IN+OUT chord → clear both marks (Option+X).
        if current.contains(.markIn) && current.contains(.markOut),
           !(heldKeys.contains(.markIn) && heldKeys.contains(.markOut)) {
            if let pid = resolvePid() {
                inject("IN+OUT", keyCode: 0x07, flags: .maskAlternate, describe: "Option+X (clear in & out)", pid: pid)
            }
            return
        }

        for key in newlyPressed where k_notDialMode(key) {
            dispatch(key)
        }
    }

    private func k_notDialMode(_ key: SpeedEditorKey) -> Bool {
        key != .shtl && key != .jog && key != .scrl
    }

    private func dispatch(_ key: SpeedEditorKey) {
        guard let pid = resolvePid() else {
            log("· \(key.label) ignored (Resolve not running)")
            return
        }
        if currentPage == "color" {
            dispatchColor(key, pid: pid)
            return
        }
        mirrorDispatch(key, pid: pid)
    }

    /// Native Speed Editor behavior via Resolve's default shortcuts.
    private func mirrorDispatch(_ key: SpeedEditorKey, pid: pid_t) {
        guard let shortcut = Self.mirrorMap[key] else {
            log("· \(key.label) not mapped yet (mirror map v1)")
            return
        }
        inject(key.label, keyCode: shortcut.keyCode, flags: shortcut.flags, describe: shortcut.describe, pid: pid)
    }

    // MARK: Color page — macro bindings

    private func dispatchColor(_ key: SpeedEditorKey, pid: pid_t) {
        if key == .esc {
            log("🎨 ESC → release")
            disarmColor()
            return
        }
        // Disabled = binding exists but is turned off: it neither fires the
        // sequence nor falls back to the mirror map. It does nothing.
        if colorConfig.disabledBindings.contains(key.id) {
            log("🎨 \(key.label) binding disabled — ignored")
            return
        }
        let steps = colorConfig.bindings[key.id] ?? []
        guard !steps.isEmpty else {
            // Unbound on Color → native mirror behavior (e.g. STOP/PLAY →
            // Space for play/pause). Bindings override, everything else
            // stays native.
            mirrorDispatch(key, pid: pid)
            return
        }
        log("🎨 \(key.label): \(steps.map(\.describe).joined(separator: " → "))")
        // A fresh press cancels any previous hold (one mouse button, one owner).
        disarmColor()
        execute(steps: steps, key: key, pid: pid)
    }

    /// Runs a step sequence on the session thread. In the press phase a "hold"
    /// parks the mouse button down until key release (the dial then drags it);
    /// in the release phase the key is already up, so a hold would never end —
    /// there it degrades to a plain click.
    private func execute(steps: [MacroStep], key: SpeedEditorKey, pid: pid_t, releasePhase: Bool = false) {
        for step in steps {
            switch step.type {
            case "goto":
                guard let name = step.target,
                      let t = colorConfig.targets[name] else {
                    log("🎨   ✗ goto '\(step.target ?? "?")' — target not calibrated")
                    continue
                }
                MouseController.move(to: t.point)
                usleep(20_000)
                lastColorPoint = t.point
                heldTargetLabel = colorConfig.targetLabel(name)
            case "clicktarget":
                guard let name = step.target,
                      let t = colorConfig.targets[name] else {
                    log("🎨   ✗ click '\(step.target ?? "?")' — target not calibrated")
                    continue
                }
                MouseController.click(at: t.point,
                                      button: MouseController.HWButton(rawValue: step.button ?? 0) ?? .left,
                                      count: step.count ?? 1)
                usleep(20_000)
                lastColorPoint = t.point
                heldTargetLabel = colorConfig.targetLabel(name)
            case "click":
                let p = lastColorPoint ?? MouseController.currentPosition()
                MouseController.click(at: p,
                                      button: MouseController.HWButton(rawValue: step.button ?? 0) ?? .left,
                                      count: step.count ?? 1)
            case "mousedown":
                let p = lastColorPoint ?? MouseController.currentPosition()
                let btn = MouseController.HWButton(rawValue: step.button ?? 0) ?? .left
                if btn == .left && mouseDownPoint == nil {
                    MouseController.down(at: p)
                    mouseDownPoint = p
                    downPoint = p
                    dragSteps = 0
                    heldColorKey = key
                    heldColorPoint = p
                    notifyDialState()
                } else {
                    MouseController.down(at: p, button: btn)
                }
            case "mouseup":
                let p = MouseController.currentPosition()
                let btn = MouseController.HWButton(rawValue: step.button ?? 0) ?? .left
                if btn == .left && mouseDownPoint != nil {
                    disarmColor()
                } else {
                    MouseController.up(at: p, button: btn)
                }
            case "hold":
                let p = lastColorPoint ?? MouseController.currentPosition()
                if releasePhase {
                    // Key already released: a hold could never be ended by a
                    // release, so execute as down → 300 ms → up.
                    MouseController.down(at: p)
                    usleep(300_000)
                    MouseController.up(at: p)
                    log("🎨   hold (release phase) → click")
                } else if mouseDownPoint == nil {
                    MouseController.down(at: p)
                    mouseDownPoint = p
                    downPoint = p
                    dragSteps = 0
                    heldColorKey = key
                    heldColorPoint = p
                    notifyDialState()
                }
            case "moveby":
                MouseController.moveBy(dx: step.dx ?? 0, dy: step.dy ?? 0)
                usleep(20_000)
            case "dragby":
                // One-shot drag by an offset from the current position.
                var p = MouseController.currentPosition()
                MouseController.down(at: p)
                usleep(25_000)
                let screen = MouseController.screenSize
                let increments = 6
                let ddx = CGFloat(step.dx ?? 0) / CGFloat(increments)
                let ddy = CGFloat(step.dy ?? 0) / CGFloat(increments)
                for _ in 0..<increments {
                    p = MouseController.currentPosition()
                    p.x = min(max(p.x + ddx, 0), screen.width - 1)
                    p.y = min(max(p.y + ddy, 0), screen.height - 1)
                    MouseController.drag(to: p)
                    usleep(12_000)
                }
                MouseController.up(at: MouseController.currentPosition(), pressed: true)
            case "scroll":
                let n = abs(step.dy ?? 1)
                let direction = (step.dy ?? 0) > 0 ? 1 : -1  // dy > 0 = scroll up
                for _ in 0..<max(1, n) {
                    MouseController.scroll(dy: direction)
                    usleep(30_000)
                }
                log("🎨   scroll: \(step.describe)")
            case "savepos":
                savedColorPoint = MouseController.currentPosition()
            case "restorepos":
                if let p = savedColorPoint {
                    MouseController.move(to: p)
                    usleep(20_000)
                } else {
                    log("🎨   ✗ restorepos — nothing saved yet")
                }
            case "sens":
                sensFactor = step.sensPercent
                if releasePhase || step.sensPercent == 100 {
                    log("🎨   dial sensitivity ×\(sensFactor)")
                } else {
                    log("🎨   dial sensitivity ×\(sensFactor) while held (reset via sens 100 on release)")
                }
            case "cycletarget":
                let list: [String]
                if !step.cycleList.isEmpty {
                    list = step.cycleList
                } else {
                    list = colorConfig.targets.keys.filter { TargetCatalog.entry(for: $0) != nil || true }.sorted()
                }
                if list.isEmpty {
                    log("🎨   ✗ cycletarget — no targets")
                    continue
                }
                var idx = lastCycledName.flatMap { list.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                if idx >= list.count { idx = 0 }
                let name = list[idx]
                lastCycledName = name
                if let t = colorConfig.targets[name] {
                    MouseController.move(to: t.point)
                    usleep(20_000)
                    lastColorPoint = t.point
                    heldTargetLabel = colorConfig.targetLabel(name)
                    log("🎨   cycle → \(colorConfig.targetLabel(name))")
                } else {
                    log("🎨   ✗ cycletarget '\(name)' — not calibrated")
                }
            case "releaseall":
                disarmColor()
                if let p = savedColorPoint {
                    MouseController.move(to: p)
                    usleep(20_000)
                }
                sensFactor = 100
                log("🎨 released all app-held inputs")
            case "key":
                guard let codeInt = step.keyCode else {
                    log("🎨   ✗ key step not captured — click its button and press the combo")
                    continue
                }
                EventInjector.tapChord(
                    CGKeyCode(truncatingIfNeeded: codeInt),
                    flags: CGEventFlags(rawValue: UInt64(step.flags ?? 0)),
                    toPid: pid)
                log("⌨️  \(step.describe)")
            case "keydown":
                guard let codeInt = step.keyCode else {
                    log("🎨   ✗ key down not captured")
                    continue
                }
                EventInjector.chordDown(
                    CGKeyCode(truncatingIfNeeded: codeInt),
                    flags: CGEventFlags(rawValue: UInt64(step.flags ?? 0)),
                    toPid: pid)
                heldKeyChord = (CGKeyCode(truncatingIfNeeded: codeInt), step.flags ?? 0)
                log("⌨️  down \(step.describe)")
            case "keyup":
                guard let codeInt = step.keyCode else {
                    log("🎨   ✗ key up not captured")
                    continue
                }
                EventInjector.chordUp(
                    CGKeyCode(truncatingIfNeeded: codeInt),
                    flags: CGEventFlags(rawValue: UInt64(step.flags ?? 0)),
                    toPid: pid)
                if heldKeyChord?.0 == CGKeyCode(truncatingIfNeeded: codeInt) { heldKeyChord = nil }
                log("⌨️  up \(step.describe)")
            case "wait":
                usleep(UInt32(min(max(step.ms ?? 0, 0), 2_000)) * 1_000)
            default:
                break
            }
        }
    }

    /// Track the last actively held keyboard chord so emergency cleanup can
    /// release it even when the binding has no release-phase keyup step.
    private var heldKeyChord: (CGKeyCode, Int)?

    /// Last target name visited by a cycletarget step (resume point for the cycle).
    private var lastCycledName: String?

    private func endHeldDrag() {
        disarmColor()
        log("🎨 released")
    }

    private var downPoint: CGPoint?
    private var dragSteps = 0

    private func disarmColor() {
        if mouseDownPoint != nil {
            // Release at the LIVE cursor position — never at the stored down
            // point. The wheel pointer may have been moved by dial steps or by
            // the user's physical mouse while the button was down; re-posting
            // the down point yanks the pointer back to the drag origin, which
            // is exactly the "value snaps back on release" bug.
            let p = MouseController.currentPosition()
            MouseController.up(at: p, pressed: true)
            let dp = downPoint.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "?"
            log("🎨 mouse up at (\(Int(p.x)), \(Int(p.y)))  [down \(dp) · \(dragSteps) drag steps]")
        }
        // Emergency hygiene: never leave a synthetic chord held.
        if let (code, flags) = heldKeyChord {
            EventInjector.chordUp(code, flags: CGEventFlags(rawValue: UInt64(flags)),
                                  toPid: resolvePid())
            heldKeyChord = nil
        }
        sensFactor = 100
        mouseDownPoint = nil
        heldColorKey = nil
        heldColorPoint = nil
        heldTargetLabel = nil
        downPoint = nil
        dragSteps = 0
        warnedHoldSkip = false
        notifyDialState()
    }

    private func startOrContinueDrag(delta: Int, sens: Int) {
        guard heldColorPoint != nil else { return }
        let screen = MouseController.screenSize
        // Anchor at the LIVE pointer position: the user may have moved the
        // pointer physically since the down, and dial steps must continue the
        // drag from where the pointer actually is. Using the stored point
        // would teleport the wheel pointer back to the drag origin.
        var p = MouseController.currentPosition()
        if mouseDownPoint == nil {
            // Missed-release recovery: re-press while the key is still held.
            MouseController.move(to: p)
            usleep(25_000)
            MouseController.down(at: p)
            mouseDownPoint = p
            downPoint = p
            usleep(25_000)
        }
        // Clockwise (positive) = up = increase. sensFactor scales the drag
        // sensitivity temporarily (sens steps set it; disarm resets to 100).
        let dy = Double(-delta * sens) * colorConfig.pixelsPerUnit
            * (Double(sensFactor) / 100.0)
        p.y = min(max(p.y + dy, 0), screen.height)
        MouseController.drag(to: p)
        mouseDownPoint = p
        dragSteps += 1
    }

    // MARK: Test execution (UI "Test sequence" button)

    /// Runs a sequence OUTSIDE the daemon state machine: no held-key bookkeeping,
    /// no dial drag ownership — holds press for 300 ms then release. On a
    /// background queue so the UI stays responsive; `onStep` fires on the main
    /// thread with (index, nil) before each step and (index, error) on failure.
    /// Stops at the first failing step.
    public func runTest(steps: [MacroStep],
                        onStep: @escaping (Int, String?) -> Void,
                        completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var last: CGPoint?
            for (i, step) in steps.enumerated() {
                DispatchQueue.main.async { onStep(i, nil) }
                var err: String?
                switch step.type {
                case "goto":
                    guard let name = step.target, let t = colorConfig.targets[name] else {
                        err = "target '\(step.target ?? "?")' not calibrated"
                        break
                    }
                    MouseController.move(to: t.point)
                    usleep(20_000)
                    last = t.point
                case "clicktarget":
                    guard let name = step.target, let t = colorConfig.targets[name] else {
                        err = "target '\(step.target ?? "?")' not calibrated"
                        break
                    }
                    MouseController.click(at: t.point,
                                          button: MouseController.HWButton(rawValue: step.button ?? 0) ?? .left,
                                          count: step.count ?? 1)
                    last = t.point
                    usleep(20_000)
                case "click":
                    let p = last ?? MouseController.currentPosition()
                    MouseController.click(at: p,
                                          button: MouseController.HWButton(rawValue: step.button ?? 0) ?? .left,
                                          count: step.count ?? 1)
                case "mousedown":
                    let p = last ?? MouseController.currentPosition()
                    MouseController.down(at: p, button: MouseController.HWButton(rawValue: step.button ?? 0) ?? .left)
                case "mouseup":
                    MouseController.up(at: MouseController.currentPosition(),
                                       button: MouseController.HWButton(rawValue: step.button ?? 0) ?? .left)
                case "moveby":
                    MouseController.moveBy(dx: step.dx ?? 0, dy: step.dy ?? 0)
                    usleep(20_000)
                case "dragby":
                    var p = MouseController.currentPosition()
                    MouseController.down(at: p)
                    usleep(25_000)
                    let screen = MouseController.screenSize
                    let ddx = CGFloat(step.dx ?? 0) / 6
                    let ddy = CGFloat(step.dy ?? 0) / 6
                    for _ in 0..<6 {
                        p = MouseController.currentPosition()
                        p.x = min(max(p.x + ddx, 0), screen.width - 1)
                        p.y = min(max(p.y + ddy, 0), screen.height - 1)
                        MouseController.drag(to: p)
                        usleep(12_000)
                    }
                    MouseController.up(at: MouseController.currentPosition(), pressed: true)
                case "scroll":
                    for _ in 0..<max(1, abs(step.dy ?? 1)) {
                        MouseController.scroll(dy: (step.dy ?? 0) > 0 ? 1 : -1)
                        usleep(30_000)
                    }
                case "savepos":
                    savedColorPoint = MouseController.currentPosition()
                case "restorepos":
                    if let p = savedColorPoint {
                        MouseController.move(to: p)
                        usleep(20_000)
                    } else {
                        err = "nothing saved — add a save-position step first"
                    }
                case "sens":
                    sensFactor = step.sensPercent
                case "cycletarget":
                    let list = step.cycleList.isEmpty ? colorConfig.targets.keys.filter { TargetCatalog.entry(for: $0) != nil || true }.sorted() : step.cycleList
                    guard let name = list.first, let t = colorConfig.targets[name] else {
                        err = "no calibrated targets to cycle"
                        break
                    }
                    MouseController.move(to: t.point)
                    usleep(20_000)
                    last = t.point
                case "releaseall":
                    disarmColor()
                case "hold":
                    let p = last ?? MouseController.currentPosition()
                    MouseController.down(at: p)
                    usleep(300_000)
                    MouseController.up(at: p)
                case "key":
                    guard let codeInt = step.keyCode else {
                        err = "key not captured"
                        break
                    }
                    EventInjector.tapChord(
                        CGKeyCode(truncatingIfNeeded: codeInt),
                        flags: CGEventFlags(rawValue: UInt64(step.flags ?? 0)),
                        toPid: resolvePid())
                    usleep(40_000)
                case "keydown", "keyup":
                    guard let codeInt = step.keyCode else {
                        err = "key not captured"
                        break
                    }
                    if step.type == "keydown" {
                        EventInjector.chordDown(
                            CGKeyCode(truncatingIfNeeded: codeInt),
                            flags: CGEventFlags(rawValue: UInt64(step.flags ?? 0)),
                            toPid: resolvePid())
                        usleep(60_000)
                        // Test runs must never leave a key held.
                        EventInjector.chordUp(
                            CGKeyCode(truncatingIfNeeded: codeInt),
                            flags: CGEventFlags(rawValue: UInt64(step.flags ?? 0)),
                            toPid: resolvePid())
                    } else {
                        EventInjector.chordUp(
                            CGKeyCode(truncatingIfNeeded: codeInt),
                            flags: CGEventFlags(rawValue: UInt64(step.flags ?? 0)),
                            toPid: resolvePid())
                    }
                    usleep(40_000)
                case "wait":
                    usleep(UInt32(min(max(step.ms ?? 0, 0), 2_000)) * 1_000)
                default:
                    break
                }
                if let err {
                    DispatchQueue.main.async { onStep(i, err) }
                    break
                }
            }
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: Mirror map (native behavior on non-Color pages)

    private func inject(_ keyLabel: String, keyCode: CGKeyCode, flags: CGEventFlags, describe: String, pid: pid_t) {
        log("⌨️  \(keyLabel) → \(describe)")
        EventInjector.tapKey(keyCode, flags: flags, toPid: pid)
    }

    /// Native Speed Editor behavior mirrored with Resolve's default shortcuts.
    /// (Validated against the manual + feel-testing; unmapped keys log only.)
    private static let mirrorMap: [SpeedEditorKey: (keyCode: CGKeyCode, flags: CGEventFlags, describe: String)] = [
        .markIn:     (0x22, [], "I"),
        .markOut:    (0x1F, [], "O"),
        .appnd:      (0x65, [], "F9 (append at playhead)"),
        .riplOwr:    (0x6D, [], "F10 (ripple overwrite)"),
        .placeOnTop: (0x67, [], "F11 (place on top)"),
        .srcOwr:     (0x6F, [], "F12 (source overwrite)"),
        .cut:        (0x2A, .maskCommand, "Cmd+\\ (add edit)"),
        .split:      (0x2A, .maskCommand, "Cmd+\\ (blade)"),
        .dis:        (0x11, .maskCommand, "Cmd+T (cross dissolve)"),
        .snap:       (0x2D, [], "N (toggle snapping)"),
        .riplDel:    (0x33, .maskCommand, "Cmd+Delete (ripple delete)"),
        .stopPlay:   (0x31, [], "Space"),
        .esc:        (0x35, [], "Esc"),
    ]

    // MARK: Search dial

    private func handleJog(mode: SpeedEditorJogMode, value: Int32) {
        let delta: Int
        switch mode {
        case .absoluteContinuous, .absoluteDeadzero:
            guard let last = lastJogValue else {
                lastJogValue = value
                return
            }
            var d = Int(value) - Int(last)
            if d > 4096 { d -= 8192 } else if d < -4096 { d += 8192 }
            delta = d
            lastJogValue = value
        case .relative0, .relative2:
            // Velocity-style over BT (can be huge); clamp hard for v1 sanity.
            lastJogValue = nil
            delta = min(2048, max(-2048, Int(value)))
        }

        guard let pid = resolvePid() else {
            // An active hold swallows dial events silently otherwise — make
            // the first skip visible so "0 drag steps" is explainable.
            if currentPage == "color", heldColorPoint != nil, !warnedHoldSkip {
                warnedHoldSkip = true
                log("🎨 dial drag skipped — Resolve not running")
            }
            return
        }

        // Per-profile sensitivity (colorConfig) wins; daemon defaults fallback.
        let modeKey = dialModeKey ?? .jog
        let sens = colorConfig.dialSensitivity[modeKey.id] ?? config.sensitivity[modeKey] ?? 1

        // Color page: dial drags whatever a "hold" step has pressed down.
        if currentPage == "color", heldColorPoint != nil {
            startOrContinueDrag(delta: delta, sens: sens)
            return
        }

        jogBudget += delta * sens

        var taps = 0
        var direction = "→"
        while abs(jogBudget) >= config.jogUnitsPerArrow, taps < 12 {
            let right = jogBudget > 0
            direction = right ? "→" : "←"
            EventInjector.tapKey(right ? 0x7C : 0x7B, toPid: pid)  // Right / Left arrow
            jogBudget += (right ? -1 : 1) * config.jogUnitsPerArrow
            taps += 1
        }
        if taps > 0 {
            log("🎡 DIAL  Δ\(delta)  sens ×\(sens)  →  \(taps) arrow\(taps > 1 ? "s" : "") \(direction)  [\(mode)]")
        }
    }
}
