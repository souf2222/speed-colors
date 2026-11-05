// ColorModeConfig.swift — user-calibrated screen positions for Color-page
// targets (wheel centers, palette buttons, …), button bindings, dial tuning,
// and PROFILES.
// Stored as JSON at ~/.speedcolors/color.json (hand-editable).
//
// Profile model:
//   • The ACTIVE profile's data lives in the flat fields (bindings, released,
//     pixelsPerUnit, …) — the daemon reads exactly those, so profile switching
//     is invisible to it.
//   • Every OTHER profile is snapshotted into `storedProfiles`.
//   • `targets`, `wheelLabelDrop`, `jogUnitsPerArrow` are global (shared).

import CoreGraphics
import Foundation

public struct ColorTarget: Codable, Sendable {
    public var x: Double
    public var y: Double
    /// Per-workspace-layout calibrations ("split" etc.). The base x/y is the
    /// SINGLE-layout calibration; the same logical target can sit elsewhere
    /// when Resolve shows two palette panels side by side.
    public var byLayout: [String: ColorTarget]?

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var point: CGPoint { CGPoint(x: x, y: y) }

    /// Resolve the calibration for a workspace layout ("single" / "split");
    /// falls back to the base (single) calibration when the layout has none.
    public func point(for layout: String?) -> CGPoint {
        guard let l = layout, !l.isEmpty, l != "single", let t = byLayout?[l] else { return point }
        return t.point
    }

    /// Store a calibration for a layout: base fields for "single"/nil,
    /// layout bucket otherwise (split calibrations never clobber single).
    public mutating func setPoint(_ p: CGPoint, for layout: String?) {
        if let l = layout, !l.isEmpty, l != "single" {
            var by = byLayout ?? [:]
            by[l] = ColorTarget(x: p.x, y: p.y)
            byLayout = by
        } else {
            x = p.x
            y = p.y
        }
    }

    public func hasCalibration(for layout: String?) -> Bool {
        guard let l = layout, !l.isEmpty, l != "single" else { return true }
        return byLayout?[l] != nil
    }
}

/// Snapshot of a non-active profile (written on profile switch).
public struct StoredProfile: Codable, Equatable {
    public var bindings: [String: [MacroStep]]
    public var released: [String: [MacroStep]]
    public var pixelsPerUnit: Double
    public var dragReleaseIdle: Double
    public var dialSensitivity: [String: Int]
    public var bindingNames: [String: String]
    public var disabledBindings: [String]

    public init(bindings: [String: [MacroStep]],
                released: [String: [MacroStep]],
                pixelsPerUnit: Double,
                dragReleaseIdle: Double,
                dialSensitivity: [String: Int],
                bindingNames: [String: String],
                disabledBindings: [String]) {
        self.bindings = bindings
        self.released = released
        self.pixelsPerUnit = pixelsPerUnit
        self.dragReleaseIdle = dragReleaseIdle
        self.dialSensitivity = dialSensitivity
        self.bindingNames = bindingNames
        self.disabledBindings = disabledBindings
    }

    public static func snapshot(from c: ColorModeConfig) -> StoredProfile {
        StoredProfile(bindings: c.bindings,
                      released: c.released,
                      pixelsPerUnit: c.pixelsPerUnit,
                      dragReleaseIdle: c.dragReleaseIdle,
                      dialSensitivity: c.dialSensitivity,
                      bindingNames: c.bindingNames,
                      disabledBindings: c.disabledBindings)
    }

    public func apply(into c: inout ColorModeConfig) {
        c.bindings = bindings
        c.released = released
        c.pixelsPerUnit = pixelsPerUnit
        c.dragReleaseIdle = dragReleaseIdle
        c.dialSensitivity = dialSensitivity
        c.bindingNames = bindingNames
        c.disabledBindings = disabledBindings
    }
}

public struct ColorModeConfig: Codable {
    /// The implicit original profile.
    public static let defaultProfile = "Default"

    // MARK: Global (shared across profiles)

    public var targets: [String: ColorTarget]
    /// OCR wheel labels sit above the wheels; drop this fraction of the window
    /// height to land on the wheel center (autocal only).
    public var wheelLabelDrop: Double
    /// Jog units per arrow tap on non-Color pages (nil = daemon default 800).
    public var jogUnitsPerArrow: Int?
    /// Target ids pinned to the top of the Targets list (global, like targets).
    public var favoriteTargets: [String]
    /// Which profile's data the flat fields currently hold.
    public var activeProfile: String
    /// Optional app association (bundle ids) per profile. No auto-switching yet.
    public var profileApps: [String: [String]]

    // MARK: ACTIVE profile storage (the daemon reads these directly)

    /// Color-page button commands: SE key id → step sequence (when pressed).
    public var bindings: [String: [MacroStep]]
    /// Optional release-phase sequences: SE key id → steps run on key release.
    public var released: [String: [MacroStep]]
    /// Drag pixels per jog unit (clockwise = up = increase).
    public var pixelsPerUnit: Double
    /// Mouse button auto-release after this many seconds of dial silence.
    public var dragReleaseIdle: Double
    /// Search-dial sensitivity per dial mode id ("jog"/"shtl"/"scrl");
    /// missing keys fall back to the daemon defaults (jog 1, shtl 4, scrl 8).
    public var dialSensitivity: [String: Int]
    /// Custom display names per binding (SE key id → name).
    public var bindingNames: [String: String]
    /// Custom face labels per SE key id — what the hardware replica prints on
    /// the key (empty/unset = original hardware legend).
    public var keyLabels: [String: String]
    /// User-created targets (id → display label). Calibrated positions live
    /// in `targets` (only when actually captured); this holds the identity so
    /// planned-but-uncalibrated custom targets still appear in the library.
    public var customTargets: [String: String]
    /// Keys whose face legend follows their binding name (inspectable toggle).
    public var labelFromBinding: [String: Bool]
    /// Bindings turned off (SE key ids) — exist but never fire.
    public var disabledBindings: [String]
    /// Screen fingerprints of the palette strip while each named palette is
    /// active (learned when a tagged binding runs). Lets the palette watcher
    /// detect mouse-driven palette changes and keep `activeTag` truthful.
    public var paletteRefs: [String: PaletteStripRef]
    /// Action ids starred in the library (global, not per-profile).
    public var favoriteActions: [String]
    /// Workspace arrangement: nil/"auto" = detect from palette references,
    /// or pinned "single" / "split". Split = two palette panels side by side
    /// (each holding its own palette + its own calibrated tab positions).
    public var workspaceLayout: String?
    /// Custom panel-light indicators: a key's LED is lit while its condition
    /// matches (any page). More general than the palette beacon.
    public var ledIndicators: [LEDIndicator]

    public struct LEDIndicator: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var key: String        // SE key id (must have a backlight)
        public var expr: MacroExpr    // lit while this matches
        public init(id: String = UUID().uuidString, key: String, expr: MacroExpr) {
            self.id = id
            self.key = key
            self.expr = expr
        }
        enum CodingKeys: String, CodingKey { case id, key, expr }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            key = try c.decode(String.self, forKey: .key)
            expr = (try? c.decode(MacroExpr.self, forKey: .expr))
                ?? .group(.all, [.cond(MacroCond(kind: .palette, value: "HDR"))])
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(key, forKey: .key)
            try c.encode(expr, forKey: .expr)
        }
    }

    /// A downscaled grayscale snapshot of the palette strip region.
    public struct PaletteStripRef: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var gray: Data   // width×height bytes, row-major
        /// The workspace layout this fingerprint was learned in — a match
        /// implies both the palette AND the layout.
        public var layout: String?
        public init(width: Int, height: Int, gray: Data, layout: String? = nil) {
            self.width = width
            self.height = height
            self.gray = gray
            self.layout = layout
        }
    }

    /// nil and "auto" behave identically; resolved layout = pinned value or
    /// the watcher's last detection (default "single").
    public var resolvedLayoutDefault: String { "single" }

    public init(targets: [String: ColorTarget] = [:],
                pixelsPerUnit: Double = 0.02,
                dragReleaseIdle: Double = 0.3,
                wheelLabelDrop: Double = 0.07,
                bindings: [String: [MacroStep]]? = nil,
                jogUnitsPerArrow: Int? = nil,
                released: [String: [MacroStep]]? = nil,
                dialSensitivity: [String: Int]? = nil,
                bindingNames: [String: String]? = nil,
                keyLabels: [String: String]? = nil,
                customTargets: [String: String]? = nil,
                labelFromBinding: [String: Bool]? = nil,
                disabledBindings: [String]? = nil,
                activeProfile: String? = nil,
                profileApps: [String: [String]]? = nil,
                favoriteTargets: [String]? = nil,
                favoriteActions: [String]? = nil,
                paletteRefs: [String: PaletteStripRef]? = nil,
                workspaceLayout: String? = nil,
                ledIndicators: [LEDIndicator]? = nil) {
        self.targets = targets
        self.pixelsPerUnit = pixelsPerUnit
        self.dragReleaseIdle = dragReleaseIdle
        self.wheelLabelDrop = wheelLabelDrop
        self.bindings = bindings ?? MacroDefaults.migrated()
        self.jogUnitsPerArrow = jogUnitsPerArrow
        self.released = released ?? [:]
        self.dialSensitivity = dialSensitivity ?? [:]
        self.bindingNames = bindingNames ?? [:]
        self.keyLabels = keyLabels ?? [:]
        self.customTargets = customTargets ?? [:]
        self.labelFromBinding = labelFromBinding ?? [:]
        self.disabledBindings = disabledBindings ?? []
        self.activeProfile = activeProfile ?? Self.defaultProfile
        self.profileApps = profileApps ?? [:]
        self.favoriteTargets = favoriteTargets ?? []
        self.favoriteActions = favoriteActions ?? []
        self.paletteRefs = paletteRefs ?? [:]
        self.workspaceLayout = workspaceLayout
        self.ledIndicators = ledIndicators ?? []
        storedProfiles = [:]
    }

    // MARK: Codable with defaults (older config files lack the new fields)

    public var storedProfiles: [String: StoredProfile]

    private enum CodingKeys: String, CodingKey {
        case targets, pixelsPerUnit, dragReleaseIdle, wheelLabelDrop, bindings, jogUnitsPerArrow
        case released, dialSensitivity, bindingNames, keyLabels, customTargets, labelFromBinding, disabledBindings
        case activeProfile, profileApps, storedProfiles, favoriteTargets, favoriteActions, paletteRefs, workspaceLayout, ledIndicators
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targets = try c.decodeIfPresent([String: ColorTarget].self, forKey: .targets) ?? [:]
        pixelsPerUnit = try c.decodeIfPresent(Double.self, forKey: .pixelsPerUnit) ?? 0.02
        dragReleaseIdle = try c.decodeIfPresent(Double.self, forKey: .dragReleaseIdle) ?? 0.3
        wheelLabelDrop = try c.decodeIfPresent(Double.self, forKey: .wheelLabelDrop) ?? 0.07
        bindings = try c.decodeIfPresent([String: [MacroStep]].self, forKey: .bindings)
            ?? MacroDefaults.migrated()
        jogUnitsPerArrow = try c.decodeIfPresent(Int.self, forKey: .jogUnitsPerArrow)
        released = try c.decodeIfPresent([String: [MacroStep]].self, forKey: .released) ?? [:]
        dialSensitivity = try c.decodeIfPresent([String: Int].self, forKey: .dialSensitivity) ?? [:]
        bindingNames = try c.decodeIfPresent([String: String].self, forKey: .bindingNames) ?? [:]
        keyLabels = try c.decodeIfPresent([String: String].self, forKey: .keyLabels) ?? [:]
        customTargets = try c.decodeIfPresent([String: String].self, forKey: .customTargets) ?? [:]
        labelFromBinding = try c.decodeIfPresent([String: Bool].self, forKey: .labelFromBinding) ?? [:]
        disabledBindings = try c.decodeIfPresent([String].self, forKey: .disabledBindings) ?? []
        // Legacy configs have calibrated custom targets with no metadata —
        // fold them in so they stay listed (and renamable).
        var mergedCustoms = customTargets
        for k in targets.keys where TargetCatalog.entry(for: k) == nil && mergedCustoms[k] == nil {
            mergedCustoms[k] = k
        }
        customTargets = mergedCustoms
        activeProfile = try c.decodeIfPresent(String.self, forKey: .activeProfile) ?? Self.defaultProfile
        profileApps = try c.decodeIfPresent([String: [String]].self, forKey: .profileApps) ?? [:]
        storedProfiles = try c.decodeIfPresent([String: StoredProfile].self, forKey: .storedProfiles) ?? [:]
        favoriteTargets = try c.decodeIfPresent([String].self, forKey: .favoriteTargets) ?? []
        favoriteActions = try c.decodeIfPresent([String].self, forKey: .favoriteActions) ?? []
        paletteRefs = try c.decodeIfPresent([String: PaletteStripRef].self, forKey: .paletteRefs) ?? [:]
        workspaceLayout = try c.decodeIfPresent(String.self, forKey: .workspaceLayout)
        ledIndicators = try c.decodeIfPresent([LEDIndicator].self, forKey: .ledIndicators) ?? []
    }

    // MARK: Profiles

    /// All profile names, active first, then sorted.
    public var profileNames: [String] {
        var names = [activeProfile]
        for k in storedProfiles.keys.sorted() where k != activeProfile {
            names.append(k)
        }
        return names
    }

    public func profileExists(_ name: String) -> Bool {
        name == activeProfile || storedProfiles[name] != nil
    }

    /// Counts for the profiles list.
    public func profileBindingCount(_ name: String) -> Int {
        if name == activeProfile { return bindings.filter { !$0.value.isEmpty }.count }
        return storedProfiles[name]?.bindings.filter { !$0.value.isEmpty }.count ?? 0
    }

    /// Switch the active profile. The current flat data is snapshotted under
    /// its own name; the target profile's snapshot (if any) becomes the flat
    /// data, otherwise the new profile starts blank.
    public mutating func switchProfile(to name: String) {
        guard name != activeProfile else { return }
        storedProfiles[activeProfile] = StoredProfile.snapshot(from: self)
        activeProfile = name
        if let sp = storedProfiles.removeValue(forKey: name) {
            sp.apply(into: &self)
        } else {
            resetActiveProfileData()
        }
    }

    /// Create a new blank profile and make it active. Fails if the name is taken.
    @discardableResult
    public mutating func createProfile(_ name: String) -> Bool {
        guard !name.isEmpty, !profileExists(name) else { return false }
        switchProfile(to: name)
        return true
    }

    /// Duplicate any existing profile under a new name (stays inactive).
    @discardableResult
    public mutating func duplicateProfile(_ source: String, as newName: String) -> Bool {
        guard !newName.isEmpty, profileExists(source), !profileExists(newName) else { return false }
        let snap = source == activeProfile
            ? StoredProfile.snapshot(from: self)
            : storedProfiles[source]!
        storedProfiles[newName] = snap
        return true
    }

    @discardableResult
    public mutating func renameProfile(_ old: String, to newName: String) -> Bool {
        guard !newName.isEmpty, profileExists(old), !profileExists(newName) else { return false }
        if let apps = profileApps[old] {
            profileApps[old] = nil
            profileApps[newName] = apps
        }
        if old == activeProfile {
            activeProfile = newName
        } else {
            storedProfiles[newName] = storedProfiles[old]
            storedProfiles[old] = nil
        }
        return true
    }

    /// Delete a profile. The Default profile cannot be deleted; deleting the
    /// ACTIVE profile clears the workspace and falls back to Default.
    @discardableResult
    public mutating func deleteProfile(_ name: String) -> Bool {
        guard profileExists(name), name != Self.defaultProfile || name != activeProfile else {
            return false
        }
        guard name != Self.defaultProfile else { return false }
        profileApps[name] = nil
        if name == activeProfile {
            activeProfile = Self.defaultProfile
            resetActiveProfileData()
        } else {
            storedProfiles[name] = nil
        }
        return true
    }

    /// Blank the active profile's data (new profile / deleted-active fallback).
    public mutating func resetActiveProfileData() {
        bindings = [:]
        released = [:]
        pixelsPerUnit = 0.02
        dragReleaseIdle = 0.3
        dialSensitivity = [:]
        bindingNames = [:]
        disabledBindings = []
    }

    // MARK: Targets

    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".speedcolors/color.json")
    }

    public static func load() -> ColorModeConfig {
        guard let data = try? Data(contentsOf: defaultPath),
              var cfg = try? JSONDecoder().decode(ColorModeConfig.self, from: data) else {
            return ColorModeConfig()
        }
        // Tree migration: legacy flat "branch" leaves become real choose
        // blocks with nested action lists (also ensures every node has an id).
        cfg.migrateToTree()
        // One-time rename: lift/gamma/gain/offset → wheel_1..4_color (catalog ids).
        if cfg.migrateLegacyWheelNames() {
            try? cfg.save()
            print("· migrated legacy wheel targets → wheel_1_color … wheel_4_color")
            fflush(stdout)
        }
        // HDR has zone-based controls (Black/Dark/Shadow/…), not four wheels;
        // drop stale calibrations for the removed lift/gamma/gain/offset ids.
        let dead = cfg.targets.keys.filter { TargetCatalog.deprecatedIds.contains($0) }
        if !dead.isEmpty {
            for id in dead { cfg.targets[id] = nil }
            try? cfg.save()
            print("· removed deprecated HDR wheel calibrations (HDR is zone-based): \(dead.joined(separator: ", "))")
            fflush(stdout)
        }
        return cfg
    }

    /// Tree migration across the live config and every stored profile:
    /// legacy "branch" leaves → choose blocks; fills in missing node ids.
    public mutating func migrateToTree() {
        func mig(_ steps: [MacroStep]) -> [MacroStep] { MacroStep.migratedTree(steps) }
        for (k, v) in bindings { bindings[k] = mig(v) }
        for (k, v) in released { released[k] = mig(v) }
        for (p, var sp) in storedProfiles {
            for (k, v) in sp.bindings { sp.bindings[k] = mig(v) }
            for (k, v) in sp.released { sp.released[k] = mig(v) }
            storedProfiles[p] = sp
        }
    }

    /// Renames the original autocal wheel names to the TargetCatalog ids, in
    /// both `targets` and any binding steps that reference them.
    public mutating func migrateLegacyWheelNames() -> Bool {
        let map = ["lift": "wheel_1_color",
                   "gamma": "wheel_2_color",
                   "gain": "wheel_3_color",
                   "offset": "wheel_4_color"]
        var changed = false
        var newTargets = targets
        for (old, new) in map where targets[old] != nil {
            if newTargets[new] == nil { newTargets[new] = targets[old] }
            newTargets[old] = nil
            changed = true
        }
        targets = newTargets
        for (old, new) in map {
            for (key, steps) in bindings {
                let retargeted = steps.map { $0.retargeted(from: old, to: new) }
                if retargeted != steps { changed = true }
                bindings[key] = retargeted
            }
        }
        return changed
    }

    public func save() throws {
        let url = ColorModeConfig.defaultPath
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url)
    }

    public mutating func removeTarget(named name: String) -> Bool {
        let hadPoint = targets[name] != nil
        let hadCustom = customTargets[name] != nil
        guard hadPoint || hadCustom else { return false }
        targets[name] = nil
        customTargets[name] = nil
        return true
    }

    /// Human-readable label for a target id (catalog name or the raw id).
    public func targetLabel(_ id: String) -> String {
        customTargets[id] ?? TargetCatalog.label(for: id) ?? id
    }

    // MARK: Custom targets

    /// Registers a user-defined target identity (starts uncalibrated unless a
    /// calibration point is stored under the same id separately).
    public mutating func addCustomTarget(id: String, label: String) {
        customTargets[id] = label
    }

    /// A target id is usable if it's in the built-in catalog or user-created.
    public func isKnownTarget(_ id: String) -> Bool {
        TargetCatalog.entry(for: id) != nil || customTargets[id] != nil
    }

    /// All custom target ids, sorted (calibrated or planned).
    public var customTargetIds: [String] {
        var ids = Set(customTargets.keys)
        ids.formUnion(targets.keys.filter { TargetCatalog.entry(for: $0) == nil })
        return ids.sorted()
    }

    /// Where a target is referenced — for the delete-confirmation UI.
    /// Human strings: "CAM1 — when pressed", "CAM2 — Night profile".
    public func targetUsage(_ name: String) -> [String] {
        func uses(_ steps: [MacroStep]) -> Bool { steps.contains { $0.allTargetIds.contains(name) } }
        var out: [String] = []
        for (k, steps) in bindings.sorted(by: { $0.key < $1.key }) where uses(steps) {
            out.append("\(Self.label(forKeyId: k)) — when pressed")
        }
        for (k, steps) in released.sorted(by: { $0.key < $1.key }) where uses(steps) {
            out.append("\(Self.label(forKeyId: k)) — when released")
        }
        for (p, sp) in storedProfiles.sorted(by: { $0.key < $1.key }) {
            for (k, steps) in sp.bindings where uses(steps) {
                out.append("\(Self.label(forKeyId: k)) — \(p) profile")
            }
            for (k, steps) in sp.released where uses(steps) {
                out.append("\(Self.label(forKeyId: k)) — \(p) profile (released)")
            }
        }
        return out
    }

    /// Hardware label for a config key id ("cam1" → "CAM1").
    public static func label(forKeyId id: String) -> String {
        SpeedEditorKey.allCases.first { $0.id == id }?.label ?? id
    }

    /// Rewrite every reference to a target id (bindings, release sequences,
    /// and every stored profile).
    @discardableResult
    public mutating func renameTarget(_ old: String, to new: String) -> Bool {
        guard !new.isEmpty, targets[new] == nil, customTargets[new] == nil,
              TargetCatalog.entry(for: new) == nil else { return false }
        guard targets[old] != nil || customTargets[old] != nil else { return false }
        // Copy the point across (if calibrated); both maps stay consistent.
        targets[new] = targets[old]
        targets[old] = nil
        customTargets[new] = customTargets[old] ?? new
        customTargets[old] = nil

        func retarget(_ steps: [MacroStep]) -> [MacroStep] {
            steps.map { $0.retargeted(from: old, to: new) }
        }
        for (k, steps) in bindings { bindings[k] = retarget(steps) }
        for (k, steps) in released { released[k] = retarget(steps) }
        for (p, var sp) in storedProfiles {
            sp.bindings = sp.bindings.mapValues(retarget)
            sp.released = sp.released.mapValues(retarget)
            storedProfiles[p] = sp
        }
        return true
    }
}
