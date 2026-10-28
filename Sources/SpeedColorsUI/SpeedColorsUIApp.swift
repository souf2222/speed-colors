// SpeedColorsUIApp.swift — app entry + DaemonController.
//
// The controller is the single source of truth for UI state: daemon lifecycle,
// live hardware state, the configuration (via read-modify-write against the
// JSON file), profiles, clipboard, undo/redo, save-state indicator, and the
// test runner wiring.

import AppKit
import SwiftUI
import SpeedColorsCore

@main
struct SpeedColorsUIApp: App {
    @StateObject private var controller = DaemonController()

    var body: some Scene {
        WindowGroup("SpeedColors") {
            AppShell()
                .environmentObject(controller)
                .frame(minWidth: 1180, minHeight: 860)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    controller.startDaemon()
                }
        }
        .windowResizability(.contentMinSize)
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
    @Published var config: ColorModeConfig
    @Published var autocalBusy = false
    @Published var batteryLine: String?

    // UI navigation & selection
    @Published var section: AppSection = .controls
    @Published var selectedControl: SEControl?
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

    // Search-dial runtime state ("JOG · dragging Wheel 1 · Lift — color")
    @Published var dialState = "JOG · idle"

    // Undo / redo (binding edits only)
    private var undoStack: [BindingUndoEntry] = []
    private var redoStack: [BindingUndoEntry] = []

    private var daemon: SpeedColorsDaemon?

    init() {
        config = ColorModeConfig.load()
    }

    // MARK: Daemon lifecycle

    func startDaemon() {
        guard daemon == nil else { return }
        accessibilityOK = EventInjector.isAccessibilityGranted()
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
        freshConfigThen { c in
            if name.isEmpty {
                c.bindingNames[keyId] = nil
            } else {
                c.bindingNames[keyId] = name
            }
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

    /// Drag from the action library onto a hardware control: creates the
    /// binding if none, else appends the step.
    func appendDroppedAction(toKeyId keyId: String, _ step: MacroStep) {
        var steps = config.bindings[keyId] ?? []
        steps.append(step)
        setBinding(keyId, phase: .pressed, steps)
        appendLog("· added \(ActionCatalog.label(for: step)) → \(ColorModeConfig.label(forKeyId: keyId)) (drag)")
        selectedControl = .key(SpeedEditorKey.allCases.first { $0.id == keyId } ?? .none)
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
        freshConfigThen { $0.targets[name] = ColorTarget(x: Double(point.x), y: Double(point.y)) }
        appendLog("· target '\(name)' calibrated → (\(Int(point.x)), \(Int(point.y)))")
    }

    func targetUsage(_ name: String) -> [String] {
        config.targetUsage(name)
    }

    func renameTarget(_ old: String, to new: String) -> Bool {
        guard config.targets[old] != nil else { return false }
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

    /// Explicit "Test" — editing never executes. Highlights the active step;
    /// per-step failures show beside the affected row.
    func testSequence(_ steps: [MacroStep]) {
        guard !steps.isEmpty, let daemon else { return }
        testErrors = [:]
        testStepIndex = nil
        appendLog("· TEST: \(steps.map(\.describe).joined(separator: " → "))")
        daemon.runTest(steps: steps, onStep: { [weak self] i, err in
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

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }
}
