// SpeedColorsApp.swift — app entry + DaemonController.
//
// The controller is the single source of truth for UI state: daemon lifecycle,
// live hardware state, the configuration (via read-modify-write against the
// JSON file), profiles, clipboard, undo/redo, save-state indicator, and the
// test runner wiring.

import AppKit
import Combine
import SwiftUI
import SpeedColorsCore

@main
struct SpeedColorsApp: App {
    @StateObject private var controller = DaemonController()

    init() {
        // Menu bar app: no Dock icon (the .app bundle's LSUIElement covers the
        // packaged case; this covers `swift run` from the build tree).
        // NSApp is nil during App.init — touching NSApplication.shared first
        // materializes it.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(controller: controller)
        } label: {
            Image(systemName: "circle.lefthalf.filled")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu bar panel

/// The compact menu bar panel: live status + quick actions, and the entry
/// point to the full control window.
struct MenuBarPanel: View {
    @ObservedObject var controller: DaemonController

    private var statusColor: Color {
        controller.deviceConnected ? Graphite.green
            : (controller.isRunning ? Graphite.amber : Graphite.text3)
    }
    private var statusLabel: String {
        if !controller.isRunning { return "daemon stopped" }
        if !controller.accessibilityOK { return "needs Accessibility" }
        return controller.deviceConnected ? "Speed Editor live" : "waiting for device…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("SpeedColors")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Graphite.text)
                Spacer()
                Pill(color: statusColor, label: statusLabel)
            }

            if let line = controller.batteryLine {
                Text(line)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Graphite.text3)
            }
            Pill(color: controller.page == "color" ? Graphite.cyan : Graphite.text3,
                 label: controller.page.map { p in p == "color" ? "COLOR PAGE" : "page: \(p)" }
                        ?? "Resolve not detected")

            // Active palette(s) right beside the page pill — open palettes
            // are listed; a closed palette simply disappears from here.
            if controller.page == "color" {
                if let pill = controller.palettePill {
                    Pill(color: pill.contains("verified") ? Graphite.cyan : Graphite.amber,
                         label: pill)
                        .help("Palettes SpeedColors believes are open, with how much it trusts that (verified = seen on screen · assumed = SpeedColors just clicked)")
                } else {
                    Pill(color: Graphite.text3, label: "palette ?")
                        .help("No palette tracked — press a key with a “Set palette state” step, or use “Ensure palette”")
                }
            }

            if let ps = controller.paletteStatus {
                Text(ps)
                    .font(.system(size: 10).monospaced())
                    .foregroundColor(Graphite.text2)
                    .lineLimit(1)
                    .help("Tracked palette slots and how much SpeedColors trusts them")
            }

            // Missing privacy grants — asked at launch, re-askable here.
            if !controller.missingPermissions.isEmpty {
                Divider().overlay(Graphite.border)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(controller.missingPermissions) { kind in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Graphite.amber)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Graphite.text)
                                Text(kind.why)
                                    .font(.system(size: 10))
                                    .foregroundColor(Graphite.text3)
                            }
                            Spacer()
                            Button("Grant…") { controller.grantPermission(kind) }
                                .buttonStyle(MiniButtonStyle(accent: Graphite.blue))
                        }
                    }
                }
            }

            Divider().overlay(Graphite.border)

            HStack(spacing: 8) {
                Button(controller.isRunning ? "Stop daemon" : "Start daemon") {
                    if controller.isRunning { controller.stopDaemon() } else { controller.startDaemon() }
                    MainWindow.shared.show(controller: controller)
                }
                .buttonStyle(GraphiteButtonStyle())
                Button("Full control…") {
                    controller.startDaemon()
                    MainWindow.shared.show(controller: controller)
                }
                .buttonStyle(GraphiteButtonStyle(accent: Graphite.blue))
            }

            HStack(spacing: 8) {
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(MiniButtonStyle())
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(Graphite.bg)
        .preferredColorScheme(.dark)
        .onAppear { controller.refreshPermissions() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            // Live status while the panel is open — grants flip in System
            // Settings, not here. Input Monitoring is probed on explicit
            // actions only.
            controller.refreshPermissions()
        }
    }
}

// MARK: - Full control window

/// Hosts the full AppShell in a plain Cocoa window. There is deliberately no
/// WindowGroup scene — the app is menu-bar-first; this window summons on demand.
final class MainWindow {
    static let shared = MainWindow()
    private var window: NSWindow?

    func show(controller: DaemonController) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 860),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "SpeedColors"
            w.contentMinSize = NSSize(width: 1080, height: 780)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: AppShell().environmentObject(controller))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Control selection & clipboard types

/// What the inspector edits. Buttons AND dial controls, uniformly.
// (SEControl lives in HardwareLayout.swift)

/// Which sequence of a binding: "When pressed" or "When released".
enum BindingPhase: String {
    case pressed
    case released
}

struct BindingClipboard {
    var pressed: [MacroStep]
    var released: [MacroStep]
    var name: String?
}

enum SaveState: Equatable {
    case idle
    case saving
    case saved
    case failed(String)
}

/// One undoable binding edit.
struct BindingUndoEntry {
    let profile: String
    let keyId: String
    let phase: BindingPhase
    let oldSteps: [MacroStep]
}

// MARK: - Controller

@MainActor
final class DaemonController: ObservableObject {
    @Published var deviceConnected = false
    @Published var page: String?
    @Published var pressedKeys: Set<String> = []
    @Published var logLines: [String] = []
    @Published var isRunning = false
    @Published var accessibilityOK = EventInjector.isAccessibilityGranted()
    @Published var screenRecordingOK = AppPermissions.screenRecordingGranted
    /// Probe result for the event tap the shortcut recorder needs. Probed at
    /// launch and on explicit re-check only — creating event taps repeatedly
    /// is not something to do on a timer.
    @Published var inputMonitoringOK = AppPermissions.inputMonitoringGranted
    @Published var config: ColorModeConfig
    @Published var autocalBusy = false
    @Published var batteryLine: String?
    /// "Split · L: HDR · R: Key · assumed" — the workspace/palette status line.
    @Published var paletteStatus: String?
    /// Compact pill next to the page pill: "HDR + Key · verified" / nil.
    @Published var palettePill: String?

    // MARK: LED indicators (Settings)

    func addIndicator() {
        freshConfigThen { c in
            c.ledIndicators.append(ColorModeConfig.LEDIndicator(
                key: "cam1",
                expr: .group(.all, [.cond(MacroCond(kind: .palette, value: "HDR"))])))
        }
        appendLog("· LED indicator added")
    }

    func removeIndicator(_ id: String) {
        freshConfigThen { c in
            c.ledIndicators.removeAll { $0.id == id }
        }
        appendLog("· LED indicator removed")
    }

    func setIndicatorKey(_ keyId: String, index: Int) {
        freshConfigThen { c in
            guard c.ledIndicators.indices.contains(index) else { return }
            c.ledIndicators[index].key = keyId
        }
    }

    func setIndicatorExpr(_ expr: MacroExpr, index: Int) {
        freshConfigThen { c in
            guard c.ledIndicators.indices.contains(index) else { return }
            c.ledIndicators[index].expr = expr
        }
    }

    // UI navigation & selection
    @Published var section: AppSection = .controls
    @Published var selectedControl: SEControl? {
        didSet {
            func tag(_ c: SEControl?) -> String {
                switch c {
                case .key(let k): return "key:\(k.id)"
                case .dial: return "dial"
                case nil: return "nil"
                }
            }
            if tag(selectedControl) != tag(oldValue) {
                appendLog("◀ select \(tag(selectedControl)) (was \(tag(oldValue)))")
            }
        }
    }
    @Published var selectedTargetId: String?

    // Clipboard (bindings)
    @Published var clipboard: BindingClipboard?

    // Autosave indicator
    @Published var saveState: SaveState = .idle
    /// Bumped on every config write so inspectors re-sync external changes.
    @Published var configRevision = 0

    // Test runner state
    @Published var testStepIndex: Int?
    @Published var testErrors: [Int: String] = [:]
    /// Leaf-node ids of the currently tested sequence (testStepIndex indexes it).
    @Published var testLeafIds: [String] = []

    // Search-dial runtime state ("JOG · dragging Wheel 1 · Lift — color")
    @Published var dialState = "JOG · idle"

    // Undo / redo (binding edits only)
    private var undoStack: [BindingUndoEntry] = []
    private var redoStack: [BindingUndoEntry] = []

    private var daemon: SpeedColorsDaemon?

    init() {
        config = ColorModeConfig.load()
        // Ask for every missing privacy grant shortly after launch — the
        // system dialogs need the app to be fully up before they appear.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.promptMissingPermissions()
        }
        // Debug/DI only: `SC_OPEN_WINDOW=1` opens the editor window at launch
        // so the in-app behavior can be driven/exercised headlessly.
        if ProcessInfo.processInfo.environment["SC_OPEN_WINDOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                MainWindow.shared.show(controller: self)
            }
        }
    }

    // MARK: Permissions

    var missingPermissions: [AppPermissions.Kind] {
        var out: [AppPermissions.Kind] = []
        if !accessibilityOK { out.append(.accessibility) }
        if !screenRecordingOK { out.append(.screenRecording) }
        if !inputMonitoringOK { out.append(.inputMonitoring) }
        return out
    }

    /// Accessibility and Screen Recording preflight cheaply and safely; the
    /// Input Monitoring probe creates an event tap, so it only re-runs on
    /// explicit request.
    func refreshPermissions(reprobeInputMonitoring: Bool = false) {
        accessibilityOK = EventInjector.isAccessibilityGranted()
        screenRecordingOK = AppPermissions.screenRecordingGranted
        if reprobeInputMonitoring {
            inputMonitoringOK = AppPermissions.inputMonitoringGranted
        }
    }

    /// Asks for every missing grant once per launch, staggered so the system
    /// dialogs don't land on top of each other. Grant buttons in the UI reuse
    /// the same prompts.
    func promptMissingPermissions() {
        refreshPermissions()
        let missing = missingPermissions
        guard !missing.isEmpty else { return }
        appendLog("· permissions needed: \(missing.map(\.title).joined(separator: ", "))")
        for (i, kind) in missing.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.2) { [weak self] in
                kind.prompt()
                self?.appendLog("· asked for \(kind.title) — \(kind.why)")
            }
        }
    }

    func grantPermission(_ kind: AppPermissions.Kind) {
        kind.prompt()
        appendLog("· asked for \(kind.title) — \(kind.why)")
        // Status only flips after the user toggles the switch in System
        // Settings; re-check shortly after, with a real probe for Input
        // Monitoring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.refreshPermissions(reprobeInputMonitoring: kind == .inputMonitoring)
        }
    }

    /// Fixes the "Grant does nothing" case: a stale TCC entry (left over from
    /// an earlier build) makes macOS skip the prompt entirely. Clear the
    /// entry, then ask again — the fresh dialog now actually appears.
    func resetAndReAskPermission(_ kind: AppPermissions.Kind) {
        let ok = AppPermissions.resetEntry(kind)
        appendLog(ok ? "· reset stale \(kind.title) entry — asking again"
                     : "✗ could not reset \(kind.title) (no bundle id?) — toggle it off/on in System Settings instead")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.grantPermission(kind)
        }
    }

    // MARK: Daemon lifecycle

    func startDaemon() {
        guard daemon == nil else { return }
        refreshPermissions(reprobeInputMonitoring: true)
        if !accessibilityOK {
            appendLog("⚠️ Accessibility missing — key & mouse injection will be silent no-ops (use Grant… in the menu panel)")
        } else if !screenRecordingOK {
            appendLog("⚠️ Screen Recording missing — palette auto-detect disabled")
        }
        let d = SpeedColorsDaemon(
            config: DaemonConfig(jogUnitsPerArrow: config.jogUnitsPerArrow ?? 800))
        d.onLog = { [weak self] line in
            DispatchQueue.main.async { self?.appendLog(line) }
        }
        d.onDeviceStatus = { [weak self] connected in
            DispatchQueue.main.async { self?.deviceConnected = connected }
        }
        d.onPageChange = { [weak self] page in
            DispatchQueue.main.async { self?.page = page }
        }
        d.onKeysRaw = { [weak self] keys in
            DispatchQueue.main.async {
                self?.pressedKeys = Set(keys.map(\.id))
            }
        }
        d.onDialState = { [weak self] state in
            DispatchQueue.main.async { self?.dialState = state }
        }
        d.onBattery = { [weak self] charging, level in
            DispatchQueue.main.async {
                self?.batteryLine = "\(level)%\(charging ? " (charging)" : "")"
            }
        }
        d.onPaletteStatus = { [weak self] line in
            DispatchQueue.main.async { self?.paletteStatus = line }
        }
        d.onPalettePill = { [weak self] line in
            DispatchQueue.main.async { self?.palettePill = line }
        }
        d.start()
        daemon = d
        isRunning = true
        appendLog("· daemon started")
    }

    func stopDaemon() {
        daemon?.stop()
        daemon = nil
        isRunning = false
        deviceConnected = false
        pressedKeys = []
        appendLog("· daemon stopped (Speed Editor released to Resolve)")
    }

    // MARK: Config persistence

    func reloadFromDisk(manual: Bool = false) {
        config = ColorModeConfig.load()
        configRevision += 1
        daemon?.reloadColorConfig()
        if manual { appendLog("· config reloaded from disk") }
    }

    /// Read-modify-write against the live file: reload fresh, apply the one
    /// change, save. Prevents stale in-memory copies (migration, CLI `coords`
    /// edits) from clobbering other writers' changes.
    private func freshConfigThen(_ apply: (inout ColorModeConfig) -> Void) {
        saveState = .saving
        var fresh = ColorModeConfig.load()
        apply(&fresh)
        do {
            try fresh.save()
        } catch {
            saveState = .failed("\(error.localizedDescription)")
            appendLog("✗ config save failed: \(error)")
            return
        }
        config = fresh
        configRevision += 1
        daemon?.reloadColorConfig()
        saveState = .saved
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if case .saved = self?.saveState { self?.saveState = .idle }
        }
    }

    func saveConfig() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        try? config.save()
        daemon?.reloadColorConfig()
    }

    /// Debounce slider/stepper drags so we don't rewrite the file on every pixel.
    private var saveWorkItem: DispatchWorkItem?

    func scheduleConfigSave() {
        saveState = .saving
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only push the tuned fields; everything else stays as on disk.
            self.freshConfigThen { c in
                c.pixelsPerUnit = self.config.pixelsPerUnit
                c.dragReleaseIdle = self.config.dragReleaseIdle
                c.jogUnitsPerArrow = self.config.jogUnitsPerArrow
            }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    // MARK: Bindings

    func bindingName(for keyId: String) -> String? {
        config.bindingNames[keyId]
    }

    func setBindingName(_ keyId: String, _ name: String) {
        appendLog("✍ name \(keyId) → '\(name)'")
        freshConfigThen { c in
            if name.isEmpty {
                c.bindingNames[keyId] = nil
            } else {
                c.bindingNames[keyId] = name
            }
        }
    }

    /// Custom key-face label for the hardware replica (empty = hardware text).
    func setKeyLabel(_ keyId: String, _ name: String) {
        appendLog("✍ label \(keyId) → '\(name)'")
        freshConfigThen { c in
            if name.isEmpty {
                c.keyLabels[keyId] = nil
            } else {
                c.keyLabels[keyId] = name
            }
        }
    }

    /// Whether the key-face legend follows the binding name.
    func setKeyLabelFromBinding(_ keyId: String, _ on: Bool) {
        appendLog("✍ nameOnKey \(keyId) → \(on)")
        freshConfigThen { c in
            c.labelFromBinding[keyId] = on ? true : nil
        }
    }

    func setBindingEnabled(_ keyId: String, _ enabled: Bool) {
        freshConfigThen { c in
            if enabled {
                c.disabledBindings.removeAll { $0 == keyId }
            } else if !c.disabledBindings.contains(keyId) {
                c.disabledBindings.append(keyId)
            }
        }
        appendLog(enabled ? "· \(ColorModeConfig.label(forKeyId: keyId)) binding enabled"
                          : "· \(ColorModeConfig.label(forKeyId: keyId)) binding disabled")
    }

    /// Set a phase's step sequence. Explicit empty array = deliberately unbound
    /// (the daemon then mirrors native behavior on non-Color pages).
    func setBinding(_ keyId: String, phase: BindingPhase, _ steps: [MacroStep]) {
        appendLog("✍ steps \(keyId)/\(phase) n=\(steps.count)")
        pushUndo(keyId: keyId, phase: phase)
        freshConfigThen { c in
            switch phase {
            case .pressed:
                c.bindings[keyId] = steps.isEmpty ? [] : steps
            case .released:
                c.released[keyId] = steps.isEmpty ? [] : steps
            }
        }
    }

    private func applyBindingSteps(_ keyId: String, phase: BindingPhase, _ steps: [MacroStep], recordUndo: Bool) {
        if recordUndo { pushUndo(keyId: keyId, phase: phase) }
        freshConfigThen { c in
            switch phase {
            case .pressed: c.bindings[keyId] = steps.isEmpty ? [] : steps
            case .released: c.released[keyId] = steps.isEmpty ? [] : steps
            }
        }
    }

    func copyBinding(forKeyId keyId: String) {
        let pressed = config.bindings[keyId] ?? []
        let released = config.released[keyId] ?? []
        clipboard = BindingClipboard(pressed: pressed,
                                     released: released,
                                     name: config.bindingNames[keyId])
        appendLog("· copied \(ColorModeConfig.label(forKeyId: keyId)) binding (\(pressed.count + released.count) steps)")
    }

    func pasteBinding(toKeyId keyId: String) {
        guard let clip = clipboard else { return }
        pushUndo(keyId: keyId, phase: .pressed)
        pushUndo(keyId: keyId, phase: .released)
        freshConfigThen { c in
            c.bindings[keyId] = clip.pressed.isEmpty ? [] : clip.pressed
            c.released[keyId] = clip.released.isEmpty ? [] : clip.released
            if let n = clip.name { c.bindingNames[keyId] = n } else { c.bindingNames[keyId] = nil }
            // A freshly pasted binding is enabled.
            c.disabledBindings.removeAll { $0 == keyId }
        }
        appendLog("· pasted binding → \(ColorModeConfig.label(forKeyId: keyId))")
    }

    func clearBinding(forKeyId keyId: String) {
        pushUndo(keyId: keyId, phase: .pressed)
        pushUndo(keyId: keyId, phase: .released)
        freshConfigThen { c in
            c.bindings[keyId] = []
            c.released[keyId] = []
            c.bindingNames[keyId] = nil
            c.disabledBindings.removeAll { $0 == keyId }
        }
        appendLog("· cleared \(ColorModeConfig.label(forKeyId: keyId)) binding")
    }

    /// Swap everything that makes a binding between two keys: pressed and
    /// released sequences, name, enabled flag, and the face-legend preference.
    /// Dragging a key onto an unbound key MOVES the binding (the target's
    /// empty binding lands on the source). ⌘Z restores it in four steps,
    /// matching the paste pattern (pressed/released per key).
    func swapBindings(fromKeyId from: String, toKeyId to: String) {
        pushUndo(keyId: from, phase: .pressed)
        pushUndo(keyId: from, phase: .released)
        pushUndo(keyId: to, phase: .pressed)
        pushUndo(keyId: to, phase: .released)
        freshConfigThen { c in
            let aPressed = c.bindings[from] ?? []
            let aReleased = c.released[from] ?? []
            let aName = c.bindingNames[from]
            let aLabel = c.labelFromBinding[from]
            let aFace = c.keyLabels[from]
            let aDisabled = c.disabledBindings.contains(from)

            c.bindings[from] = c.bindings[to] ?? []
            c.released[from] = c.released[to] ?? []
            c.bindingNames[from] = c.bindingNames[to]

            c.bindings[to] = aPressed
            c.released[to] = aReleased
            c.bindingNames[to] = aName

            let bDisabled = c.disabledBindings.contains(to)
            c.disabledBindings.removeAll { $0 == from || $0 == to }
            if aDisabled { c.disabledBindings.append(to) }
            if bDisabled { c.disabledBindings.append(from) }

            let bLabel = c.labelFromBinding[to]
            c.labelFromBinding[from] = bLabel
            c.labelFromBinding[to] = aLabel

            // Custom face labels ("PRM", "HDR"…) travel WITH the binding —
            // this is what makes the move visible on the device replica.
            let bFace = c.keyLabels[to]
            c.keyLabels[from] = bFace
            c.keyLabels[to] = aFace

            let fa = ColorModeConfig.label(forKeyId: from)
            let ta = ColorModeConfig.label(forKeyId: to)
            let bPressed = c.bindings[to] ?? []
            let bReleased = c.released[to] ?? []
            if aPressed.isEmpty && aReleased.isEmpty {
                appendLog("· moved binding: \(ta) → \(fa)  (\(bPressed.count) step\(bPressed.count == 1 ? "" : "s"))")
            } else {
                appendLog("· swapped bindings: \(fa) ↔ \(ta)  (\(aPressed.count)/\(aReleased.count) ↔ \(bPressed.count)/\(bReleased.count) steps)")
            }
        }
        selectedControl = nil
    }

    /// Drag from the action library onto a hardware control: creates the
    /// binding if none, else appends the step.
    func appendDroppedAction(toKeyId keyId: String, _ step: MacroStep) {
        var steps = config.bindings[keyId] ?? []
        steps.append(step)
        setBinding(keyId, phase: .pressed, steps)
        appendLog("· added \(ActionCatalog.label(for: step)) → \(ColorModeConfig.label(forKeyId: keyId)) (drag)")
        selectedControl = .key(SpeedEditorKey.allCases.first { $0.id == keyId } ?? .none)
    }

    // MARK: Tree node operations (nested automation editor)

    /// Which phase currently contains the node with this id.
    private func phaseOfNode(id: String, keyId: String) -> BindingPhase? {
        if (config.bindings[keyId] ?? []).contains(where: { $0.contains(id: id) || $0.id == id }) { return .pressed }
        if (config.released[keyId] ?? []).contains(where: { $0.contains(id: id) || $0.id == id }) { return .released }
        return nil
    }

    private func rootList(_ keyId: String, _ phase: BindingPhase) -> [MacroStep] {
        switch phase {
        case .pressed: return config.bindings[keyId] ?? []
        case .released: return config.released[keyId] ?? []
        }
    }

    private func writeBindingTree(_ keyId: String, _ phase: BindingPhase, _ steps: [MacroStep], _ logLine: String) {
        appendLog(logLine)
        pushUndo(keyId: keyId, phase: phase)
        freshConfigThen { c in
            switch phase {
            case .pressed: c.bindings[keyId] = steps
            case .released: c.released[keyId] = steps
            }
        }
    }

    /// Insert a node (from the library, or a dragged node) at a tree address.
    /// parentID "" = the phase's root list.
    func insertNode(_ node: MacroStep, keyId: String, phase: BindingPhase,
                    parentID: String, slot: String, index: Int) {
        // Context warnings — prevent easy mistakes.
        if node.type == "hold" && phase == .released {
            appendLog("⚠ Hold to adjust in 'When released' runs as a 300 ms click (no dial adjust on release)")
        }
        var list = rootList(keyId, phase)
        if parentID.isEmpty {
            list = MacroStep.arrayInsert(node, at: index, in: list)
        } else {
            guard MacroStep.insert(node, parentID: parentID, slot: slot, index: index, into: &list) else {
                appendLog("✗ insert failed — destination vanished")
                return
            }
        }
        writeBindingTree(keyId, phase, list, "· added \(node.describe(labels: config.targetLabel)) → \(ColorModeConfig.label(forKeyId: keyId))")
    }

    /// Move an existing node (drag & drop anywhere in the tree, including
    /// across the pressed ⇄ released sections). Destination parent "" = root.
    func moveNode(id: String, keyId: String,
                  toParentID: String, toSlot: String, toIndex: Int) {
        guard let fromPhase = phaseOfNode(id: id, keyId: keyId) else { return }
        let source = rootList(keyId, fromPhase)
        let r = MacroStep.removing(id: id, from: source)
        guard let node = r.removed else { return }
        // Structural guard: never drop a container into its own subtree.
        if !toParentID.isEmpty, node.contains(id: toParentID) {
            appendLog("✗ can't move a block into itself")
            return
        }
        var list = r.list
        if toParentID.isEmpty {
            list = MacroStep.arrayInsert(node, at: toIndex, in: list)
            writeBindingTree(keyId, fromPhase, list,
                             "· moved \(node.describe(labels: config.targetLabel)) → position \(min(toIndex + 1, list.count))")
            return
        }
        guard MacroStep.insert(node, parentID: toParentID, slot: toSlot, index: toIndex, into: &list) else {
            appendLog("✗ move failed — destination vanished")
            return
        }
        writeBindingTree(keyId, fromPhase, list, "· moved \(node.describe(labels: config.targetLabel)) into \(toSlot == "else" ? "else" : toSlot == "default" ? "default" : "branch")")
    }

    /// Move a node between the pressed and released sections.
    func moveNodeAcrossPhases(id: String, keyId: String, toPhase: BindingPhase) {
        guard let fromPhase = phaseOfNode(id: id, keyId: keyId), fromPhase != toPhase else { return }
        var source = rootList(keyId, fromPhase)
        let r = MacroStep.removing(id: id, from: source)
        guard let node = r.removed else { return }
        source = r.list
        var dest = rootList(keyId, toPhase)
        dest.append(node)
        appendLog("· moved \(node.describe(labels: config.targetLabel)) → \(toPhase == .pressed ? "when pressed" : "when released")")
        pushUndo(keyId: keyId, phase: fromPhase)
        pushUndo(keyId: keyId, phase: toPhase)
        freshConfigThen { c in
            switch fromPhase {
            case .pressed: c.bindings[keyId] = source
            case .released: c.released[keyId] = source
            }
            switch toPhase {
            case .pressed: c.bindings[keyId] = dest
            case .released: c.released[keyId] = dest
            }
        }
    }

    func deleteNode(id: String, keyId: String) {
        guard let phase = phaseOfNode(id: id, keyId: keyId) else { return }
        let list = rootList(keyId, phase)
        let r = MacroStep.removing(id: id, from: list)
        guard let node = r.removed else { return }
        writeBindingTree(keyId, phase, r.list,
                         "· deleted \(node.describe(labels: config.targetLabel))  (⌘Z restores)")
    }

    func duplicateNode(id: String, keyId: String) {
        guard let phase = phaseOfNode(id: id, keyId: keyId),
              let path = MacroStep.locate(id: id, in: rootList(keyId, phase)) else { return }
        var list = rootList(keyId, phase)
        let r = MacroStep.removing(id: id, from: list)
        guard let original = r.removed else { return }
        list = r.list
        // Re-insert the fresh-id copy at the same address (the original is
        // already removed, so `path.index` lands right after its old spot).
        let copy = original.duplicated()
        if path.parentID.isEmpty {
            list = MacroStep.arrayInsert(copy, at: path.index, in: list)
        } else {
            guard MacroStep.insert(copy, parentID: path.parentID, slot: path.slot,
                                   index: path.index, into: &list) else { return }
        }
        writeBindingTree(keyId, phase, list, "· duplicated \(original.describe(labels: config.targetLabel))")
    }

    func moveNodeBy(id: String, keyId: String, offset: Int) {
        guard let phase = phaseOfNode(id: id, keyId: keyId) else { return }
        var list = rootList(keyId, phase)
        if MacroStep.move(id: id, offset: offset, in: &list) {
            writeBindingTree(keyId, phase, list, offset < 0 ? "· moved up" : "· moved down")
        }
    }

    func setNodeDisabled(_ disabled: Bool, id: String, keyId: String) {
        guard let phase = phaseOfNode(id: id, keyId: keyId) else { return }
        var list = rootList(keyId, phase)
        guard MacroStep.updating(id: id, transform: { $0.off = disabled ? true : nil }, in: &list) else { return }
        writeBindingTree(keyId, phase, list, disabled ? "· disabled an action" : "· enabled an action")
    }

    /// Replace a node wholesale (settings edits through node Bindings).
    func updateNode(_ node: MacroStep, id: String, keyId: String, phase: BindingPhase) {
        var list = rootList(keyId, phase)
        guard MacroStep.updating(id: id, transform: { $0 = node }, in: &list) else { return }
        pushUndo(keyId: keyId, phase: phase)
        freshConfigThen { c in
            switch phase {
            case .pressed: c.bindings[keyId] = list
            case .released: c.released[keyId] = list
            }
        }
    }

    /// Rename a container (Sequence name / custom action name).
    func setNodeName(_ name: String, id: String, keyId: String, phase: BindingPhase) {
        var list = rootList(keyId, phase)
        guard MacroStep.updating(id: id, transform: { $0.name = name.isEmpty ? nil : name }, in: &list) else { return }
        pushUndo(keyId: keyId, phase: phase)
        freshConfigThen { c in
            switch phase {
            case .pressed: c.bindings[keyId] = list
            case .released: c.released[keyId] = list
            }
        }
    }

    // MARK: Library insertion destination & favorites

    /// Where a sidebar "+" insert lands: the action list the user last
    /// hovered in the inspector (falls back to the selected key's root).
    struct InsertDest: Equatable {
        let keyId: String
        let phase: BindingPhase
        let parentID: String
        let slot: String
        let path: String
    }
    @Published var pendingInsert: InsertDest?

    /// Called by ActionListEditor on hover — "the list under the mouse is the
    /// destination". Cheap and intuitive; the picker header shows the path.
    func setPendingInsert(keyId: String, phase: BindingPhase, parentID: String, slot: String, path: String) {
        pendingInsert = InsertDest(keyId: keyId, phase: phase, parentID: parentID,
                                   slot: slot, path: path)
    }

    /// Sidebar "+": insert into the pending destination, else the selected
    /// key's pressed root. Logs guidance when neither exists.
    func insertFromLibrary(_ node: MacroStep) {
        if let dest = pendingInsert {
            insertNode(node, keyId: dest.keyId, phase: dest.phase,
                       parentID: dest.parentID, slot: dest.slot, index: Int.max)
            return
        }
        if case .key(let k) = selectedControl, k != .esc, k != .shtl, k != .jog, k != .scrl {
            insertNode(node, keyId: k.id, phase: .pressed,
                       parentID: "", slot: "root", index: Int.max)
            return
        }
        appendLog("✗ no insertion destination — hover a sequence in the inspector first")
    }

    func isFavoriteAction(_ id: String) -> Bool {
        config.favoriteActions.contains(id)
    }

    func toggleFavoriteAction(_ id: String) {
        if isFavoriteAction(id) {
            freshConfigThen { $0.favoriteActions.removeAll { $0 == id } }
        } else {
            freshConfigThen { $0.favoriteActions.append(id) }
        }
    }

    // MARK: Dial sensitivity

    func setDialSensitivity(_ modeId: String, _ value: Int?) {
        freshConfigThen { c in
            if let value {
                c.dialSensitivity[modeId] = value
            } else {
                c.dialSensitivity[modeId] = nil
            }
        }
    }

    // MARK: Targets

    /// Saves a calibrated position (mouse-position calibration flow).
    func saveTarget(_ name: String, _ point: CGPoint) {
        var display = name
        freshConfigThen { c in
            var t = c.targets[name] ?? ColorTarget(x: Double(point.x), y: Double(point.y))
            // Calibrations are per workspace layout: "split" coords live in
            // their own bucket and never clobber the single-layout position.
            t.setPoint(point, for: c.workspaceLayout == "split" ? "split" : nil)
            c.targets[name] = t
            // Custom ids get identity metadata too (renamable in the library).
            if TargetCatalog.entry(for: name) == nil && c.customTargets[name] == nil {
                c.addCustomTarget(id: name, label: name)
            }
            display = c.targetLabel(name)   // display name, never the raw id
        }
        appendLog("· target '\(display)' calibrated (\(config.workspaceLayout ?? "single") layout) → (\(Int(point.x)), \(Int(point.y)))")
    }

    /// Workspace arrangement: nil/"auto" (detect from palette references),
    /// "single", or "split".
    func setWorkspaceLayout(_ s: String?) {
        freshConfigThen { $0.workspaceLayout = s }
        appendLog("· workspace layout → \(s ?? "auto")")
        daemon?.reloadColorConfig()
    }

    /// Creates a user-defined target (uncalibrated unless a point is given).
    /// Returns false if the id is taken (already known or in the catalog).
    func addCustomTarget(id: String, label: String) -> Bool {
        var ok = false
        freshConfigThen { c in
            guard !id.isEmpty, !c.isKnownTarget(id), TargetCatalog.entry(for: id) == nil else { return }
            c.addCustomTarget(id: id, label: label.isEmpty ? id : label)
            ok = true
        }
        if ok {
            appendLog("· custom target '\(label.isEmpty ? id : label)' added (\(id))")
        } else {
            appendLog("✗ '\(id)' already exists — choose another id")
        }
        return ok
    }

    func targetUsage(_ name: String) -> [String] {
        config.targetUsage(name)
    }

    func renameTarget(_ old: String, to new: String) -> Bool {
        // Renaming only applies to custom targets — catalog ids are stable.
        guard TargetCatalog.entry(for: old) == nil else { return false }
        var ok = false
        freshConfigThen { c in
            ok = c.renameTarget(old, to: new)
        }
        appendLog(ok ? "· target '\(old)' renamed → '\(new)'" : "✗ rename failed (id taken?)")
        return ok
    }

    func deleteTarget(_ name: String) {
        freshConfigThen { $0.removeTarget(named: name) }
        appendLog("· target '\(name)' deleted")
    }

    func toggleTargetFavorite(_ id: String) {
        freshConfigThen { c in
            if let i = c.favoriteTargets.firstIndex(of: id) { c.favoriteTargets.remove(at: i) }
            else { c.favoriteTargets.append(id) }
        }
    }

    func isFavoriteTarget(_ id: String) -> Bool {
        config.favoriteTargets.contains(id)
    }

    func testTarget(_ name: String) {
        guard let t = config.targets[name] else { return }
        appendLog("· test target '\(name)' → move cursor")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            MouseController.move(to: t.point)
        }
    }

    // MARK: Profiles

    var activeProfileName: String { config.activeProfile }
    var profileNames: [String] { config.profileNames }
    func profileExists(_ name: String) -> Bool { config.profileExists(name) }
    func profileBindingCount(_ name: String) -> Int { config.profileBindingCount(name) }

    func switchProfile(_ name: String) {
        guard config.profileExists(name), name != config.activeProfile else { return }
        freshConfigThen { c in
            c.switchProfile(to: name)
        }
        undoStack = []
        redoStack = []
        appendLog("· profile → \(name)")
    }

    func createProfile(_ name: String) {
        var ok = false
        freshConfigThen { c in
            ok = c.createProfile(name)
        }
        appendLog(ok ? "· profile created: \(name)" : "✗ could not create profile “\(name)”")
    }

    func duplicateProfile(_ source: String, as newName: String) {
        var ok = false
        freshConfigThen { c in
            ok = c.duplicateProfile(source, as: newName)
        }
        appendLog(ok ? "· duplicated “\(source)” → “\(newName)”" : "✗ could not duplicate profile")
    }

    func renameProfile(_ old: String, to newName: String) {
        var ok = false
        freshConfigThen { c in
            ok = c.renameProfile(old, to: newName)
        }
        appendLog(ok ? "· profile renamed “\(old)” → “\(newName)”" : "✗ could not rename profile")
    }

    func deleteProfile(_ name: String) {
        freshConfigThen { c in
            _ = c.deleteProfile(name)
        }
        undoStack = []
        redoStack = []
        appendLog("· profile deleted: \(name)")
    }

    func addProfileApp(_ profile: String, _ bundleId: String) {
        freshConfigThen { c in
            var apps = c.profileApps[profile] ?? []
            if !apps.contains(bundleId) { apps.append(bundleId) }
            c.profileApps[profile] = apps
        }
    }

    func removeProfileApp(_ profile: String, _ bundleId: String) {
        freshConfigThen { c in
            var apps = c.profileApps[profile] ?? []
            apps.removeAll { $0 == bundleId }
            c.profileApps[profile] = apps.isEmpty ? nil : apps
        }
    }

    // MARK: Undo / redo

    private func pushUndo(keyId: String, phase: BindingPhase) {
        let old: [MacroStep]
        switch phase {
        case .pressed: old = config.bindings[keyId] ?? []
        case .released: old = config.released[keyId] ?? []
        }
        undoStack.append(BindingUndoEntry(profile: config.activeProfile,
                                          keyId: keyId,
                                          phase: phase,
                                          oldSteps: old))
        if undoStack.count > 60 { undoStack.removeFirst(undoStack.count - 60) }
        redoStack = []
    }

    func undoBinding() {
        guard let entry = undoStack.popLast() else { return }
        guard entry.profile == config.activeProfile else {
            undoStack = []
            redoStack = []
            return
        }
        let current: [MacroStep]
        switch entry.phase {
        case .pressed: current = config.bindings[entry.keyId] ?? []
        case .released: current = config.released[entry.keyId] ?? []
        }
        redoStack.append(BindingUndoEntry(profile: entry.profile,
                                          keyId: entry.keyId,
                                          phase: entry.phase,
                                          oldSteps: current))
        applyBindingSteps(entry.keyId, phase: entry.phase, entry.oldSteps, recordUndo: false)
        appendLog("· undo → \(ColorModeConfig.label(forKeyId: entry.keyId)) (\(entry.phase.rawValue))")
    }

    func redoBinding() {
        guard let entry = redoStack.popLast() else { return }
        guard entry.profile == config.activeProfile else {
            redoStack = []
            return
        }
        let current: [MacroStep]
        switch entry.phase {
        case .pressed: current = config.bindings[entry.keyId] ?? []
        case .released: current = config.released[entry.keyId] ?? []
        }
        undoStack.append(BindingUndoEntry(profile: entry.profile,
                                          keyId: entry.keyId,
                                          phase: entry.phase,
                                          oldSteps: current))
        applyBindingSteps(entry.keyId, phase: entry.phase, entry.oldSteps, recordUndo: false)
        appendLog("· redo → \(ColorModeConfig.label(forKeyId: entry.keyId)) (\(entry.phase.rawValue))")
    }

    // MARK: Test runner

    /// Explicit "Test" — editing never executes. Highlights the active leaf;
    /// per-step failures show beside the affected card. Nested trees are
    /// flattened to their execution order (leaves) for step highlighting.
    func testSequence(_ steps: [MacroStep]) {
        let flat = steps.flatMap { $0.leaves() }
        guard !flat.isEmpty, let daemon else { return }
        testErrors = [:]
        testStepIndex = nil
        testLeafIds = flat.compactMap(\.id)
        appendLog("· TEST: \(flat.map { $0.describe(labels: { self.config.targetLabel($0) }) }.joined(separator: " → "))")
        daemon.runTest(steps: flat, onStep: { [weak self] i, err in
            guard let self else { return }
            if let err {
                self.testErrors[i] = err
                self.testStepIndex = nil
            } else {
                self.testStepIndex = i
            }
        }, completion: { [weak self] in
            self?.testStepIndex = nil
        })
    }

    // MARK: Autocal

    func runAutocal(force: Bool) {
        guard !autocalBusy else { return }
        autocalBusy = true
        DispatchQueue.global().async { [weak self] in
            do {
                let result = try AutoCal.calibrate(force: force)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.reloadFromDisk()
                    self.appendLog("· autocal: \(result.updated.count) saved, \(result.kept.count) kept, \(result.derived.count) derived → \(result.pngURL.path)")
                    self.autocalBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self?.appendLog("✗ autocal failed: \(error)")
                    self?.autocalBusy = false
                }
            }
        }
    }

    // MARK: Log

    /// Disk-backed mirror of `logLines` so the exact write sequence survives
    /// relaunches and can be read back when hunting state bugs.
    private let logFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".speedcolors/ui.log")
    private lazy var logStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func appendLog(_ line: String) {
        let stamped = "[\(logStamp.string(from: Date()))] \(line)"
        logLines.append(stamped)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
        let data = Data("\(stamped)\n".utf8)
        if let fh = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: logFileURL)
        }
    }
}
