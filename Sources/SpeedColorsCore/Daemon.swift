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
        rebuildPaletteMaps()
        refreshPanelLeds()   // indicator edits apply immediately
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
        // Palette auto-detect: correct the tracked state from the screen.
        paletteWatcher.onLog = { [weak self] in self?.log($0) }
        paletteWatcher.onReference = { [weak self] tag, ref in
            guard let self else { return }
            var refs = colorConfig.paletteRefs
            refs[tag] = ref
            colorConfig.paletteRefs = refs
            try? colorConfig.save()
        }
        paletteWatcher.onDetected = { [weak self] tag, layout in
            guard let self else { return }
            // Only while on the Color page; the watcher is stopped otherwise.
            guard currentPage == "color" else { return }
            if let layout, layout != detectedLayout {
                detectedLayout = layout
                log("🎨 workspace layout detected → \(layout)")
                rebuildPaletteMaps()   // tab positions differ per layout
            }
            if let tag {
                // A screen match VERIFIES the palette (strongest evidence).
                // The strip reflects the whole visible panel state, so the
                // detection REPLACES the slot list — no stale second slots.
                if let i = paletteSlots.firstIndex(where: { $0.tag == tag }) {
                    paletteSlots[i].confidence = .verified
                    if i > 0 { paletteSlots.swapAt(0, i) }
                } else {
                    paletteSlots = [PaletteSlotState(tag: tag, confidence: .verified)]
                }
                normalizePaletteSlots()
                log("🎨 palette verified on screen → \(tag) · \(paletteStatusLine)")
            } else {
                // Unknown: keep tags as "last used" but downgrade confidence —
                // conditions report UNKNOWN, never a silent false.
                for i in paletteSlots.indices { paletteSlots[i].confidence = .unknown }
                normalizePaletteSlots()
                log("🎨 palette state unknown (screen changed) — press a tagged key or use Ensure palette to re-sync")
            }
            refreshPanelLeds()
            notifyPaletteStatus()
        }
        rebuildPaletteMaps()
        notifyPaletteStatus()
    }

    public func stop() {
        session.stop()
        watcher.stop()
        paletteWatcher.stop()
        session.setPanelLeds([])
        session.setDialLeds([])
        paletteSlots = []
        tagBeaconKey = nil
        manualLeds = []
        disarmColor()
    }

    // MARK: Palette slot state

    /// Human status line for the UI ("Split · L: HDR · R: Key · assumed").
    private var paletteStatusLine: String {
        guard !paletteSlots.isEmpty else { return "palette unknown" }
        let layout = resolvedLayout == "split" ? "Split" : "Single"
        let parts = paletteSlots.enumerated().map { i, s -> String in
            let slotName = paletteSlots.count > 1 ? (i == 0 ? "L" : "R") : "Main"
            return "\(slotName): \(s.tag) · \(s.confidence.rawValue)"
        }
        return "\(layout) · \(parts.joined(separator: " · "))"
    }

    /// Compact pill line: every OPEN (non-unknown) palette joined; closed
    /// palettes simply aren't in the list. nil = nothing tracked.
    private var palettePillLine: String? {
        let visible = paletteSlots.filter { $0.confidence != .unknown }
        guard !visible.isEmpty else { return nil }
        let names = visible.map(\.tag).joined(separator: " + ")
        let conf = visible.map(\.confidence.rawValue).first ?? "assumed"
        return "\(names) · \(conf)"
    }

    private func notifyPaletteStatus() {
        onPaletteStatus?(paletteStatusLine)
        onPalettePill?(palettePillLine)
    }

    /// Slot-count discipline: a single-panel workspace shows ONE palette at a
    /// time (HDR / RGB / Primaries are tabs of the same panel — opening one
    /// closes the others), so a second tracked slot there is fiction that
    /// lights the wrong beacons and skews conditions. Split workspaces
    /// legitimately show two panels (L + R). Call after every slot mutation.
    private func normalizePaletteSlots() {
        if resolvedLayout != "split" && paletteSlots.count > 1 {
            paletteSlots = [paletteSlots[0]]
        }
    }

    /// Display-name resolver — internal target IDs must never surface in
    /// logs, summaries, or errors.
    private func label(_ id: String) -> String { colorConfig.targetLabel(id) }

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
        if !colorMode {
            paletteSlots = []
            tagBeaconKey = nil
            paletteWatcher.stop()   // tracked palette state is Color-page-only
        }
        rebuildPaletteMaps()
        if colorMode {
            paletteWatcher.start()
            if tabPoints.isEmpty && !warnedPaletteHint {
                warnedPaletteHint = true
                log("💡 palette auto-detect idle — add a 'Set palette state' step after a palette-tab click (e.g. Click target hdr_page → Set palette state \"HDR\") so mouse-driven palette changes stay tracked and the owning key lights up")
            }
        }
        refreshPanelLeds()
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

    private var cachedResolvePid: pid_t?
    private var cachedResolveAt: Date?

    private func _resolvePid() -> pid_t? {
        // Probe only every 2 s: the fallback path touches AppKit/LaunchServices
        // (localizedName is a synchronous XPC round-trip per running app), and
        // every key/dial report used to trigger a full enumeration — that wait
        // on the main thread is what beachballed the UI with the device active.
        if let cached = cachedResolvePid, let at = cachedResolveAt,
           Date().timeIntervalSince(at) < 2.0 {
            return kill(cached, 0) == 0 ? cached : nil
        }
        cachedResolveAt = Date()
        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.blackmagic-design.DaVinciResolve").first {
            cachedResolvePid = app.processIdentifier
            return app.processIdentifier
        }
        // Fallback in case of bundle-id drift: match by bundle identifier
        // substring only. (Matching localizedName does a synchronous
        // LaunchServices XPC round-trip per app — far too hot for per-key use.)
        let fallback = NSWorkspace.shared.runningApplications.first { app in
            app.bundleIdentifier?.lowercased().contains("davinci") == true
        }?.processIdentifier
        cachedResolvePid = fallback
        return fallback
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
        defer {
            heldKeys = current
            if !released.isEmpty || !newlyPressed.isEmpty {
                refreshPanelLeds()   // "is pressed" indicators
            }
        }
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
                log("🎨 ↩ \(key.label) released: \(relSteps.map { $0.describe(labels: label) }.joined(separator: " → "))")
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
            log("· \(key.label) not mapped on this page (\(currentPage ?? "—")) — mirror map v1")
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
        log("🎨 \(key.label): \(steps.map { $0.describe(labels: label) }.joined(separator: " → "))")
        // A fresh press cancels any previous hold (one mouse button, one owner).
        disarmColor()
        execute(steps: steps, key: key, pid: pid)
    }

    /// Runs a step sequence on the session thread. In the press phase a "hold"
    /// parks the mouse button down until key release (the dial then drags it);
    /// in the release phase the key is already up, so a hold would never end —
    /// there it degrades to a plain click.
    private func execute(steps: [MacroStep], key: SpeedEditorKey, pid: pid_t, releasePhase: Bool = false,
                         depth: Int = 0) -> Bool {
        let pad = String(repeating: "  ", count: min(depth, 6))
        if depth == 0 && !releasePhase {
            // Fresh press: click/hold steps must not inherit the last run's
            // parked position. lastColorPoint used to survive across keys, so
            // a choose branch that matched nothing left the hold pressing the
            // mouse down on whatever control a PREVIOUS key had visited.
            // The release phase keeps the press run's point on purpose —
            // release actions act on the same control.
            lastColorPoint = nil
        }
        for step in steps {
            if depth > 6 {
                log("🎨   ✗ nesting too deep (max 6) — stopping")
                return false
            }
            // Disabled node: visible in the editor, inert at runtime.
            if step.off == true {
                log("🎨 \(pad)– skipped (disabled) · \(step.describeStrict(labels: label))")
                continue
            }
            // Legacy leaf-level condition: runs only while the tracked
            // palette state matches (a "palette" step sets it).
            if let req = step.when, !req.isEmpty, req != activeTag {
                log("🎨 \(pad)– skip \(step.describe(labels: label)) — wants palette '\(req)', active '\(activeTag ?? "—")'")
                continue
            }
            switch step.type {
            case "if":
                guard let expr = step.expr else {
                    log("🎨 \(pad)✗ if block has no condition")
                    continue
                }
                let ctx = condContext()
                let (match, result) = expr.evaluate(ctx)
                traceExpr(expr, result: result, pad: "\(pad)  ")
                if match {
                    log("🎨 \(pad)⇒ then")
                    if execute(steps: step.children ?? [], key: key, pid: pid,
                               releasePhase: releasePhase, depth: depth + 1) { return true }
                } else {
                    log("🎨 \(pad)⇒ else")
                    if execute(steps: step.children2 ?? [], key: key, pid: pid,
                               releasePhase: releasePhase, depth: depth + 1) { return true }
                }
            case "choose":
                guard !((step.options ?? []).isEmpty) else {
                    log("🎨 \(pad)⇒ default (choose has no options)")
                    if execute(steps: step.children ?? [], key: key, pid: pid,
                               releasePhase: releasePhase, depth: depth + 1) { return true }
                    continue
                }
                var ran = false
                let ctx = condContext()
                for (oi, opt) in (step.options ?? []).enumerated() {
                    let (match, result) = opt.expr.evaluate(ctx)
                    traceExpr(opt.expr, result: result, pad: "\(pad)  ",
                              header: "option \(oi + 1)")
                    if match {
                        log("🎨 \(pad)⇒ option \(oi + 1)")
                        if execute(steps: opt.actions, key: key, pid: pid,
                                   releasePhase: releasePhase, depth: depth + 1) { return true }
                        ran = true
                        break
                    }
                }
                if !ran {
                    log("🎨 \(pad)⇒ default (no option matched)")
                    if execute(steps: step.children ?? [], key: key, pid: pid,
                               releasePhase: releasePhase, depth: depth + 1) { return true }
                }
            case "sequence":
                log("🎨 \(pad)▸ sequence\(step.name.map { " “\($0)”" } ?? "")")
                if execute(steps: step.children ?? [], key: key, pid: pid,
                           releasePhase: releasePhase, depth: depth + 1) { return true }
            case "repeat":
                let n = min(max(step.count ?? 2, 1), 50)
                log("🎨 \(pad)▸ repeat ×\(n)")
                for _ in 0..<n {
                    if execute(steps: step.children ?? [], key: key, pid: pid,
                               releasePhase: releasePhase, depth: depth + 1) { return true }
                }
            case "lighton", "lightoff", "lighttoggle":
                // Manual panel-light control — usable inside if-branches for
                // custom tracking (e.g. light CAM8 while HDR is tracked).
                guard let keyId = step.tag,
                      let target = SpeedEditorKey.allCases.first(where: { $0.id == keyId }),
                      let led = target.led else {
                    log("🎨 \(pad)✗ \(step.describe(labels: label)) — pick a key with a backlight")
                    continue
                }
                switch step.type {
                case "lighton": manualLeds.insert(led)
                case "lightoff": manualLeds.remove(led)
                default:
                    if manualLeds.contains(led) { manualLeds.remove(led) } else { manualLeds.insert(led) }
                }
                log("🎨 \(pad)💡 \(step.describe(labels: label))")
                refreshPanelLeds()
            case "stop":
                log("🎨 \(pad)■ stop\(step.tag?.isEmpty == false ? " — \(step.tag!)" : "")")
                return true
            case "goto":
                guard let name = step.target,
                      let t = colorConfig.targets[name] else {
                    log("🎨   ✗ goto '\(label(step.target ?? ""))' — target not calibrated (\(step.target ?? "?"))")
                    continue
                }
                MouseController.move(to: t.point(for: resolvedLayout))
                usleep(20_000)
                lastColorPoint = t.point(for: resolvedLayout)
                heldTargetLabel = colorConfig.targetLabel(name)
            case "clicktarget":
                guard let name = step.target,
                      let t = colorConfig.targets[name] else {
                    log("🎨   ✗ click '\(label(step.target ?? ""))' — target not calibrated (\(step.target ?? "?"))")
                    continue
                }
                MouseController.click(at: t.point(for: resolvedLayout),
                                      button: MouseController.HWButton(rawValue: step.button ?? 0) ?? .left,
                                      count: step.count ?? 1)
                usleep(20_000)
                lastColorPoint = t.point(for: resolvedLayout)
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
                log("🎨   scroll: \(step.describe(labels: label))")
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
                    MouseController.move(to: t.point(for: resolvedLayout))
                    usleep(20_000)
                    lastColorPoint = t.point(for: resolvedLayout)
                    heldTargetLabel = colorConfig.targetLabel(name)
                    log("🎨   cycle → \(colorConfig.targetLabel(name))")
                } else {
                    log("🎨   ✗ cycletarget '\(label(name))' — not calibrated")
                }
            case "releaseall":
                disarmColor()
                if let p = savedColorPoint {
                    MouseController.move(to: p)
                    usleep(20_000)
                }
                sensFactor = 100
                log("🎨 released all app-held inputs")
            case "palette":
                // "Set palette state": records what SpeedColors just opened
                // (assumed — the screen watcher verifies it independently).
                let tag = step.tag ?? ""
                if tag.isEmpty {
                    paletteSlots = []
                    log("🎨 palette state → — (cleared)")
                } else {
                    // Main (left) slot takes the palette; a split workspace
                    // may keep one other panel's palette. Single layout: the
                    // new state replaces the tracked palette entirely.
                    var others = paletteSlots.filter { $0.tag != tag }
                    paletteSlots = [PaletteSlotState(tag: tag, confidence: .assumed)]
                        + others.prefix(1)
                    normalizePaletteSlots()
                    log("🎨 palette state → \(tag) (assumed) · beacon \(key.label)")
                }
                tagBeaconKey = activeTag == nil ? nil : key
                paletteWatcher.grace()
                if let tag = activeTag, tabPoints[tag] != nil {
                    // Learn this palette's strip appearance a beat after the
                    // click lands — the reference is what auto-detect compares.
                    let t = tag
                    let lay = resolvedLayout
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.45) { [self] in
                        paletteWatcher.captureReference(for: t, layout: lay)
                    }
                }
                refreshPanelLeds()
                notifyPaletteStatus()
            case "ensure":
                // "Ensure palette": make sure Resolve is showing this palette                // before touching palette-specific coordinates. Safe mode:
                // only skip when the screen has VERIFIED the palette; any
                // assumption re-asserts by clicking its (idempotent) tab.
                let tag = step.tag ?? ""
                guard !tag.isEmpty else {
                    log("🎨 ✗ ensure palette — no palette chosen")
                    continue
                }
                if let slot = paletteSlots.first(where: { $0.tag == tag }),
                   slot.confidence == .verified {
                    log("🎨 ⇢ ensure '\(tag)' — already verified on screen · skip")
                    continue
                }
                guard let pt = tabPoints[tag] else {
                    log("🎨 ✗ ensure '\(tag)' — no calibrated tab target (add 'Move to target' on its tab before 'Set palette state')")
                    continue
                }
                if let placement = step.target2, !placement.isEmpty, placement != "auto" {
                    log("🎨 ⇢ ensure '\(tag)' — placement '\(placement)' not calibrated yet · using automatic")
                }
                MouseController.click(at: pt)
                usleep(80_000)
                // Clicking the tab navigates: mark assumed in the main slot.
                var others = paletteSlots.filter { $0.tag != tag }
                paletteSlots = [PaletteSlotState(tag: tag, confidence: .assumed)] + others.prefix(1)
                normalizePaletteSlots()
                tagBeaconKey = beaconMap[tag]
                log("🎨 ⇢ ensure '\(tag)' → clicked tab (assumed · re-clicking an active tab must be a no-op in your Resolve — verify once)")
                paletteWatcher.grace()
                let t = tag
                let lay = resolvedLayout
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.45) { [self] in
                    paletteWatcher.captureReference(for: t, layout: lay)
                }
                refreshPanelLeds()
                notifyPaletteStatus()
            case "key":
                guard let codeInt = step.keyCode else {
                    log("🎨   ✗ key step not captured — click its button and press the combo")
                    continue
                }
                EventInjector.tapChord(
                    CGKeyCode(truncatingIfNeeded: codeInt),
                    flags: CGEventFlags(rawValue: UInt64(step.flags ?? 0)),
                    toPid: pid)
                log("⌨️  \(step.describe(labels: label))")
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
                log("⌨️  down \(step.describe(labels: label))")
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
                log("⌨️  up \(step.describe(labels: label))")
            case "wait":
                usleep(UInt32(min(max(step.ms ?? 0, 0), 2_000)) * 1_000)
            default:
                break
            }
        }
        return false
    }

    // MARK: Condition context & trace

    /// Snapshot of the app state conditions can read.
    private func condContext() -> MacroCondContext {
        MacroCondContext(
            palette: activeTag,
            paletteVisible: Set(paletteSlots.filter { $0.confidence != .unknown }.map(\.tag)),
            paletteUnknown: paletteHasUnknown,
            paletteConfidence: paletteSlots.first?.confidence.rawValue,
            layout: resolvedLayout,
            page: (currentPage == "unknown" || currentPage == "—") ? nil : currentPage,
            profile: colorConfig.activeProfile,
            dialMode: dialModeKey?.label,
            calibratedTargets: Set(colorConfig.targets.keys),
            heldKeys: Set(heldKeys.map(\.id)),
            deviceConnected: session.isConnected)
    }

    /// Recursive trace in the spirit of a test-runner report:
    ///   ANY — TRUE
    ///     ✓ tracked palette is "HDR"
    ///     ✗ tracked palette is "Primaries"
    private func traceExpr(_ expr: MacroExpr, result: MacroExpr.Result, pad: String, header: String? = nil) {
        func mark(_ r: MacroExpr.Result) -> String {
            switch r {
            case .match: return "✓"
            case .knownNo: return "✗"
            case .unknown: return "· unknown"
            }
        }
        switch expr {
        case .cond(let c):
            log("🎨\(pad)\(mark(result)) \(c.describe(labels: label))")
        case .group(let op, let children):
            let verdict = result == .match ? "TRUE" : (result == .knownNo ? "FALSE" : "UNKNOWN")
            log("🎨\(pad)\(op == .all ? "ALL" : "ANY")\(header.map { " (\($0))" } ?? "") — \(verdict)")
            let ctx = condContext()
            for c in children {
                let (_, r) = c.evaluate(ctx)
                traceExpr(c, result: r, pad: pad + "  ")
            }
        }
    }

    /// Track the last actively held keyboard chord so emergency cleanup can
    /// release it even when the binding has no release-phase keyup step.
    private var heldKeyChord: (CGKeyCode, Int)?

    /// Tracked Color-page palette state, per VISIBLE SLOT. Split workspaces
    /// show two palette panels (e.g. HDR left, Key right) — one global value
    /// can't represent that. Each slot carries the palette tag and how much
    /// we trust it: assumed (SpeedColors acted) vs verified (screen match)
    /// vs unknown (state invalidated; kept only as "last used").
    public enum PaletteConfidence: String, Sendable { case assumed, verified, unknown }
    public struct PaletteSlotState: Equatable, Sendable {
        public var tag: String
        public var confidence: PaletteConfidence
        public init(tag: String, confidence: PaletteConfidence) {
            self.tag = tag
            self.confidence = confidence
        }
    }
    private var paletteSlots: [PaletteSlotState] = []
    /// The tracked palette, honest edition: nil when nothing is tracked or
    /// confidence is unknown. Conditions report that as UNKNOWN, not false.
    private var activeTag: String? {
        paletteSlots.first(where: { $0.confidence != .unknown })?.tag
    }
    /// Whether ANY slot's confidence is unknown (drives condition "unknown ≠ false").
    private var paletteHasUnknown: Bool {
        paletteSlots.contains { $0.confidence == .unknown }
    }
    private var tagBeaconKey: SpeedEditorKey?
    /// Workspace layout: pinned ("single"/"split") or auto-detected from
    /// palette reference matches. Targets resolve coordinates per layout.
    private var detectedLayout: String = "single"
    private var resolvedLayout: String {
        if let w = colorConfig.workspaceLayout, w == "single" || w == "split" { return w }
        return detectedLayout
    }
    /// UI status hook ("Split · Left: HDR · Right: Key · assumed").
    public var onPaletteStatus: ((String) -> Void)?
    /// Compact pill summary for the launcher: "HDR + Key · verified", or nil
    /// when nothing is tracked (the pill then shows "palette ?").
    public var onPalettePill: ((String?) -> Void)?
    /// Palette auto-detection (screen comparison against learned references).
    private let paletteWatcher = PaletteWatcher()
    /// Derived from bindings: tag → key that sets it (for LED beacons) and
    /// tag → tab point (for the watcher's strip rect).
    private var beaconMap: [String: SpeedEditorKey] = [:]
    private var tabPoints: [String: CGPoint] = [:]
    private var warnedNoTabTags: Set<String> = []
    private var warnedPaletteHint = false

    /// Rebuild tag→key and tag→tab maps from the current bindings, and push
    /// them (plus stored references) into the palette watcher. Tab points
    /// resolve through the CURRENT workspace layout.
    private func rebuildPaletteMaps() {
        var beacons: [String: SpeedEditorKey] = [:]
        var tabs: [String: CGPoint] = [:]
        let layout = resolvedLayout

        func derive(_ steps: [MacroStep], key: SpeedEditorKey) {
            var lastNavTarget: String?
            for step in steps {
                switch step.type {
                case "goto", "clicktarget":
                    if let t = step.target { lastNavTarget = t }
                case "palette":
                    let tag = step.tag ?? ""
                    guard !tag.isEmpty else { continue }
                    if beacons[tag] == nil { beacons[tag] = key }
                    if tabs[tag] == nil,
                       let nav = lastNavTarget,
                       let target = colorConfig.targets[nav] {
                        tabs[tag] = target.point(for: layout)
                    }
                default:
                    break
                }
            }
        }
        for (keyId, steps) in colorConfig.bindings {
            guard let key = SpeedEditorKey.allCases.first(where: { $0.id == keyId }) else { continue }
            derive(steps, key: key)
        }
        for (keyId, steps) in colorConfig.released {
            guard let key = SpeedEditorKey.allCases.first(where: { $0.id == keyId }) else { continue }
            derive(steps, key: key)
        }
        beaconMap = beacons
        tabPoints = tabs
        // Tags set by bindings but with no navigation → watcher can't learn.
        for tag in beacons.keys where tabPoints[tag] == nil && !warnedNoTabTags.contains(tag) {
            warnedNoTabTags.insert(tag)
            log("🎨 palette '\(tag)' has no tab target — add 'Move to target' before its 'Set palette state' to enable auto-detect")
        }
        paletteWatcher.currentLayout = layout
        paletteWatcher.configure(tabPoints: tabs, refs: colorConfig.paletteRefs)
    }

    /// Manual panel lights (from "light" actions) — runtime state, cleared on
    /// daemon stop. Survives page changes.
    private var manualLeds: SpeedEditorLed = []

    /// Panel LEDs, layered: SNAP (Color page) + palette beacons (Color page)
    /// + manually set lights (any page, via "light" actions) + condition
    /// indicators (any page, from Settings).
    private func refreshPanelLeds() {
        var leds: SpeedEditorLed = currentPage == "color" ? [.snap] : []
        if currentPage == "color" {
            var mentioned = Set<String>()
            for slot in paletteSlots where slot.confidence != .unknown {
                guard let beacon = tagBeaconKeyFor(slot.tag) else {
                    if !mentioned.contains(slot.tag) {
                        mentioned.insert(slot.tag)
                        log("🎨 palette '\(slot.tag)' has no owning key — no beacon")
                    }
                    continue
                }
                if let led = beacon.led {
                    leds.insert(led)
                } else if !mentioned.contains(slot.tag) {
                    mentioned.insert(slot.tag)
                    log("🎨 '\(beacon.label)' has no backlight — palette '\(slot.tag)' can't light it")
                }
            }
        }
        // Manual lights survive page changes — they're explicitly user-set.
        leds.formUnion(manualLeds)
        // Condition-driven indicators (custom tracking).
        if !colorConfig.ledIndicators.isEmpty {
            let ctx = condContext()
            for ind in colorConfig.ledIndicators {
                guard let target = SpeedEditorKey.allCases.first(where: { $0.id == ind.key }),
                      let led = target.led else { continue }
                let (match, _) = ind.expr.evaluate(ctx)
                if match { leds.insert(led) }
            }
        }
        session.setPanelLeds(leds)
    }

    /// Beacon for a tag: the key that most recently set it, else the key
    /// whose binding owns the palette (correct after mouse-driven changes).
    private func tagBeaconKeyFor(_ tag: String) -> SpeedEditorKey? {
        if tagBeaconKey != nil, activeTag == tag { return tagBeaconKey }
        return beaconMap[tag]
    }

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
                        err = "target '\(label(step.target ?? ""))' not calibrated (\(step.target ?? "?"))"
                        break
                    }
                    MouseController.move(to: t.point)
                    usleep(20_000)
                    last = t.point
                case "clicktarget":
                    guard let name = step.target, let t = colorConfig.targets[name] else {
                        err = "target '\(label(step.target ?? ""))' not calibrated (\(step.target ?? "?"))"
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
        .appnd:      (0x6F, .maskShift, "Shift+F12 (append to end)"),
        .smartInsrt: (0x65, [], "F9 (insert at playhead)"),
        .riplOwr:    (0x6D, [], "F10 (ripple overwrite)"),
        .placeOnTop: (0x67, [], "F11 (place on top)"),
        .srcOwr:     (0x6F, [], "F12 (source overwrite)"),
        .trimIn:     (0x21, .maskShift, "Shift+[ (ripple trim in)"),
        .trimOut:    (0x1E, .maskShift, "Shift+] (ripple trim out)"),
        .roll:       (0x11, [], "T (trim edit mode)"),
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
        // Capped (12 taps ≈ the most we can inject in one report window): drop
        // the remainder. Otherwise a backlog accumulates — with SCRL ×8 one
        // report is worth ~20 arrows — and stale budget later fires arrows in
        // the OLD direction after the user reverses (observed as inverted
        // direction flips in the activity log).
        if taps == 12 && jogBudget != 0 {
            jogBudget = 0
        }
        if taps > 0 {
            let capped = taps == 12 ? "  (capped, backlog dropped)" : ""
            log("🎡 DIAL  Δ\(delta)  sens ×\(sens)  →  \(taps) arrow\(taps > 1 ? "s" : "") \(direction)  [\(mode)]\(capped)")
        }
    }
}
