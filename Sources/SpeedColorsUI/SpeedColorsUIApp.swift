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
    @Published var config: ColorModeConfig
    @Published var autocalBusy = false
    @Published var batteryLine: String?

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

    // Search-dial runtime state ("JOG · dragging Wheel 1 · Lift — color")
    @Published var dialState = "JOG · idle"

    // Undo / redo (binding edits only)
    private var undoStack: [BindingUndoEntry] = []
    private var redoStack: [BindingUndoEntry] = []

    private var daemon: SpeedColorsDaemon?

    init() {
        config = ColorModeConfig.load()
        // Debug/DI only: `SC_OPEN_WINDOW=1` opens the editor window at launch
        // so the in-app behavior can be driven/exercised headlessly.
        if ProcessInfo.processInfo.environment["SC_OPEN_WINDOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                MainWindow.shared.show(controller: self)
            }
        }
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
        freshConfigThen { c in
            c.targets[name] = ColorTarget(x: Double(point.x), y: Double(point.y))
            // Custom ids get identity metadata too (renamable in the library).
            if TargetCatalog.entry(for: name) == nil && c.customTargets[name] == nil {
                c.addCustomTarget(id: name, label: name)
            }
        }
        appendLog("· target '\(name)' calibrated → (\(Int(point.x)), \(Int(point.y)))")
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
