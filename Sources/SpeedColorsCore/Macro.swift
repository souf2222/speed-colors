// Macro.swift — button commands for the Color page.
//
// A binding maps a Speed Editor button to a TREE of actions, executed on
// each key press while on the Color page. Actions run top to bottom; logic
// blocks (if / choose / sequence / repeat) contain their own child lists:
//
//   goto(name)  park the cursor on a calibrated target
//   click       full mouse click at the current position
//   hold        press the mouse down and KEEP it down until the SE key is
//               released (the search dial then drags the control; release
//               is guaranteed by the engine on key-up / ESC)
//   key         inject a keyboard shortcut (virtual keycode + CGEventFlags)
//   wait        pause for N ms
//   if          run `children` when the condition matches, else `children2`
//   choose      first matching option's actions win, else `children` (default)
//   sequence    named group of actions (pure organizational container)
//   repeat      run `children` `count` times
//   stop        end the whole sequence immediately
//
// Examples:  "Go to HDR wheel, click"          → [goto hdr, click]
//            "Wheel 1: click and hold to drag" → [goto gamma, hold]
//            "Palette switch"                  → [choose [HDR → …] [PRM → …]]

import Foundation

// MARK: - Conditions (recursive builder: groups of AND/OR + comparisons)

/// What a condition can look at — ONLY state speedcolors actually knows.
/// Resolve's scripting API can't report the front palette, so that one is
/// app-tracked (and honestly reported as "unknown" when unobserved).
public enum MacroCondKind: String, Codable, CaseIterable, Sendable {
    case palette              // tracked palette state ("palette" steps set it)
    case paletteVisible       // tag visible in ANY palette slot
    case paletteConfidence    // verified / assumed / unknown
    case layout               // workspace layout: single / split
    case page                 // Resolve page from the sidecar watcher
    case profile              // active speedcolors profile
    case dialMode             // current dial mode (SHTL / JOG / SCRL)
    case targetCalibrated     // is a named target calibrated
    case keyHeld              // is a hardware key currently pressed
    case deviceConnected      // Speed Editor plugged in & authenticated

    public var label: String {
        switch self {
        case .palette: return "Tracked palette"
        case .paletteVisible: return "Palette visible"
        case .paletteConfidence: return "Palette confidence"
        case .layout: return "Palette layout"
        case .page: return "Resolve page"
        case .profile: return "Active profile"
        case .dialMode: return "Dial mode"
        case .targetCalibrated: return "Target calibration"
        case .keyHeld: return "Hardware button"
        case .deviceConnected: return "Device connection"
        }
    }

    /// Operators this property supports (first = default).
    public var ops: [CondOp] {
        switch self {
        case .palette: return [.isEq, .isNot]
        case .paletteVisible: return [.isEq, .isNot]
        case .paletteConfidence: return [.isEq, .isNot]
        case .layout: return [.isEq, .isNot]
        case .page, .profile, .dialMode: return [.isEq, .isNot]
        case .targetCalibrated: return [.isCalibrated, .isNotCalibrated]
        case .keyHeld: return [.isPressed, .isNotPressed]
        case .deviceConnected: return [.isConnected, .isDisconnected]
        }
    }
}

public enum CondOp: String, Codable, CaseIterable, Sendable {
    case isEq = "is"
    case isNot = "is not"
    case isOneOf = "is one of"
    case isNotOneOf = "is not one of"
    case isCalibrated = "is calibrated"
    case isNotCalibrated = "is not calibrated"
    case isPressed = "is pressed"
    case isNotPressed = "is not pressed"
    case isConnected = "is connected"
    case isDisconnected = "is disconnected"
}

/// One comparison: property + operator + value(s). `values` backs the
/// compact "is one of [HDR ×] [Primaries ×]" editor (equivalent to ORs).
public struct MacroCond: Codable, Equatable, Sendable {
    public var kind: MacroCondKind
    public var op: CondOp
    public var value: String
    public var values: [String]?

    public init(kind: MacroCondKind, op: CondOp? = nil, value: String = "", values: [String]? = nil) {
        self.kind = kind
        self.op = op ?? kind.ops.first ?? .isEq
        self.value = value
        self.values = values
    }

    public var describe: String { describe(labels: nil) }

    public func describe(labels: ((String) -> String)?) -> String {
        switch op {
        case .isEq: return "\(kind.label.lowercased()) \(op.rawValue) “\(value)”"
        case .isNot: return "\(kind.label.lowercased()) \(op.rawValue) “\(value)”"
        case .isOneOf, .isNotOneOf:
            let list = (values ?? (value.isEmpty ? [] : [value]))
                .map { "“\($0)”" }.joined(separator: ", ")
            return "\(kind.label.lowercased()) \(op.rawValue) [\(list)]"
        case .isCalibrated, .isNotCalibrated:
            // Display name for the target; ID never surfaces.
            let name = labels?(value) ?? value
            return "target “\(name)” \(op.rawValue)"
        case .isPressed, .isNotPressed:
            return "\(value.isEmpty ? "key" : value) \(op.rawValue)"
        case .isConnected, .isDisconnected:
            return "device \(op.rawValue)"
        }
    }

    /// Value menu items for a property (non-palette kinds have fixed lists).
    public static func valueChoices(kind: MacroCondKind, tags: [String], profiles: [String]) -> [String] {
        switch kind {
        case .palette, .paletteVisible: return tags
        case .paletteConfidence: return ["verified", "assumed", "unknown"]
        case .layout: return ["single", "split"]
        case .page: return ["color", "edit", "fusion", "cut", "deliver", "media"]
        case .profile: return profiles
        case .dialMode: return ["SHTL", "JOG", "SCRL"]
        case .targetCalibrated, .keyHeld, .deviceConnected: return []
        }
    }
}

/// Group operator: ALL = every child must match (AND); ANY = at least one.
public enum CondGroupOp: String, Codable, CaseIterable, Sendable {
    case all  // AND
    case any  // OR

    public var label: String { self == .all ? "All conditions — AND" : "Any condition — OR" }
    public var joiner: String { self == .all ? "and" : "or" }
}

/// Recursive condition expression: a comparison or a group of them.
public enum MacroExpr: Codable, Equatable, Sendable {
    case cond(MacroCond)
    case group(CondGroupOp, [MacroExpr])

    // MARK: Evaluation

    public enum Result: Equatable, Sendable { case match, knownNo, unknown }

    /// Three-valued logic: unknown ≠ false. AND: any false → false, else any
    /// unknown → unknown, else true. OR: any true → true, else any unknown →
    /// unknown, else false.
    public func evaluate(_ ctx: MacroCondContext) -> (Bool, Result) {
        switch self {
        case .cond(let c):
            return MacroCond.evaluate(c, ctx: ctx)
        case .group(let op, let children):
            guard !children.isEmpty else { return (false, .unknown) }
            var sawUnknown = false
            for child in children {
                let (m, r) = child.evaluate(ctx)
                if op == .all {
                    // AND: one definite false kills it; unknown defers.
                    if r == .knownNo { return (false, .knownNo) }
                    if r == .unknown { sawUnknown = true }
                } else {
                    // OR: one definite true satisfies it; unknown defers.
                    if r == .match { return (true, .match) }
                    if r == .unknown { sawUnknown = true }
                }
            }
            if op == .all {
                return sawUnknown ? (false, .unknown) : (true, .match)
            } else {
                return sawUnknown ? (false, .unknown) : (false, .knownNo)
            }
        }
    }

    // MARK: Readable summary (for collapsed cards & logs)

    public func summary(depth: Int = 0) -> String {
        switch self {
        case .cond(let c):
            return c.describe
        case .group(let op, let children):
            let inner = children.map { $0.summary(depth: depth + 1) }
                .joined(separator: " \(op.joiner) ")
            return depth == 0 ? inner : "(\(inner))"
        }
    }

    // MARK: Validation (incomplete expressions block testing)

    public func validate() -> String? {
        switch self {
        case .cond(let c):
            switch c.kind {
            case .palette, .paletteVisible, .paletteConfidence, .layout,
                 .page, .profile, .dialMode, .keyHeld:
                if c.value.isEmpty
                    && (c.values ?? []).isEmpty
                    && (c.op == .isOneOf || c.op == .isNotOneOf || c.op == .isEq || c.op == .isNot) {
                    return "condition is missing its value"
                }
                if (c.op == .isOneOf || c.op == .isNotOneOf), (c.values ?? []).isEmpty && c.value.isEmpty {
                    return "add at least one value"
                }
                return nil
            case .targetCalibrated:
                return c.value.isEmpty ? "pick a target to check" : nil
            case .deviceConnected:
                return nil
            }
        case .group(_, let children):
            if children.isEmpty { return "empty group — add a condition" }
            for c in children {
                if let e = c.validate() { return e }
            }
            return nil
        }
    }

    /// Every palette value mentioned anywhere (feeds the value menus).
    public func collectPaletteValues(into set: inout Set<String>) {
        switch self {
        case .cond(let c):
            if c.kind == .palette {
                if !c.value.isEmpty { set.insert(c.value) }
                for v in c.values ?? [] where !v.isEmpty { set.insert(v) }
            }
        case .group(_, let children):
            for c in children { c.collectPaletteValues(into: &set) }
        }
    }

    /// Normalize a single legacy comparison into a one-item group.
    public static func grouped(_ expr: MacroExpr) -> MacroExpr {
        if case .cond = expr { return .group(.all, [expr]) }
        return expr
    }
}

/// Snapshot of everything a condition can read at execution time.
public struct MacroCondContext: Sendable {
    public var palette: String?              // nil = not tracked yet (unknown)
    public var paletteVisible: Set<String>   // tags visible in any slot (non-unknown)
    public var paletteUnknown: Bool          // any slot's confidence is unknown
    public var paletteConfidence: String?    // first slot's confidence
    public var layout: String                // "single" / "split"
    public var page: String?                 // nil/"unknown"/"—" = unknown
    public var profile: String
    public var dialMode: String?
    public var calibratedTargets: Set<String>
    public var heldKeys: Set<String>         // SE key ids currently pressed
    public var deviceConnected: Bool

    public init(palette: String?, paletteVisible: Set<String> = [], paletteUnknown: Bool = false,
                paletteConfidence: String? = nil, layout: String = "single",
                page: String?, profile: String, dialMode: String?,
                calibratedTargets: Set<String>, heldKeys: Set<String>, deviceConnected: Bool) {
        self.palette = palette
        self.paletteVisible = paletteVisible
        self.paletteUnknown = paletteUnknown
        self.paletteConfidence = paletteConfidence
        self.layout = layout
        self.page = page
        self.profile = profile
        self.dialMode = dialMode
        self.calibratedTargets = calibratedTargets
        self.heldKeys = heldKeys
        self.deviceConnected = deviceConnected
    }
}

extension MacroCond {
    /// Evaluate one comparison against the context. Unknown ≠ false.
    static func evaluate(_ c: MacroCond, ctx: MacroCondContext) -> (Bool, MacroExpr.Result) {
        typealias R = MacroExpr.Result
        func done(_ match: Bool) -> (Bool, R) { (match, match ? .match : .knownNo) }
        switch c.kind {
        case .palette:
            guard let t = ctx.palette else { return (false, .unknown) }
            switch c.op {
            case .isEq: return done(t == c.value)
            case .isNot: return done(t != c.value)
            case .isOneOf: return done((c.values ?? []).contains(t) || t == c.value)
            case .isNotOneOf: return done(!((c.values ?? []).contains(t) || t == c.value))
            default: return done(false)
            }
        case .paletteVisible:
            // Unknown ≠ invisible: an unverified slot can't claim absence.
            if ctx.paletteVisible.contains(c.value) { return done(true) }
            if ctx.paletteUnknown { return (false, .unknown) }
            return done(false)
        case .paletteConfidence:
            guard let conf = ctx.paletteConfidence else { return (false, .unknown) }
            switch c.op {
            case .isEq: return done(conf == c.value)
            case .isNot: return done(conf != c.value)
            default: return done(false)
            }
        case .layout:
            switch c.op {
            case .isEq: return done(ctx.layout == c.value)
            case .isNot: return done(ctx.layout != c.value)
            default: return done(false)
            }
        case .page:
            guard let p = ctx.page, p != "unknown", p != "—" else { return (false, .unknown) }
            switch c.op {
            case .isEq: return done(p == c.value)
            case .isNot: return done(p != c.value)
            default: return done(false)
            }
        case .profile:
            switch c.op {
            case .isEq: return done(ctx.profile == c.value)
            case .isNot: return done(ctx.profile != c.value)
            default: return done(false)
            }
        case .dialMode:
            guard let m = ctx.dialMode else { return (false, .unknown) }
            switch c.op {
            case .isEq: return done(m == c.value)
            case .isNot: return done(m != c.value)
            default: return done(false)
            }
        case .targetCalibrated:
            let has = ctx.calibratedTargets.contains(c.value)
            switch c.op {
            case .isCalibrated: return done(has)
            case .isNotCalibrated: return done(!has)
            default: return done(false)
            }
        case .keyHeld:
            let held = ctx.heldKeys.contains(c.value)
            switch c.op {
            case .isPressed: return done(held)
            case .isNotPressed: return done(!held)
            default: return done(false)
            }
        case .deviceConnected:
            switch c.op {
            case .isConnected: return done(ctx.deviceConnected)
            case .isDisconnected: return done(!ctx.deviceConnected)
            default: return done(false)
            }
        }
    }
}

// MARK: - Choose options

/// One option of a "choose" block: condition expression + its own action list.
public struct ChooseOption: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var expr: MacroExpr
    public var actions: [MacroStep]

    public init(id: String = UUID().uuidString, expr: MacroExpr, actions: [MacroStep] = []) {
        self.id = id
        self.expr = expr
        self.actions = actions
    }

    public var label: String { expr.summary() }

    enum CodingKeys: String, CodingKey { case id, expr, cond, actions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        // New format: expr; legacy: a single "cond" wrapped in a group.
        if let e = try? c.decode(MacroExpr.self, forKey: .expr) {
            expr = e
        } else if let legacy = try? c.decode(MacroCond.self, forKey: .cond) {
            expr = .group(.all, [.cond(legacy)])
        } else {
            expr = .group(.all, [.cond(MacroCond(kind: .palette, value: "HDR"))])
        }
        actions = try c.decodeIfPresent([MacroStep].self, forKey: .actions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(expr, forKey: .expr)
        try c.encode(actions, forKey: .actions)
    }
}

// MARK: - Action node

public struct MacroStep: Codable, Equatable, Sendable {
    public var type: String    // leaf: "goto"|"click"|"hold"|"key"|"wait"|…  container: "if"|"choose"|"sequence"|"repeat"|"stop"
    /// Stable identity for drag & drop, undo bookkeeping, and traces.
    public var id: String?
    public var target: String?
    public var keyCode: Int?
    public var flags: Int?
    public var ms: Int?
    /// Mouse button (click / mousedown / mouseup / clicktarget): 0=left 1=right 2=middle.
    public var button: Int?
    /// Click count (1 single, 2 double) or repeat-block iteration count.
    public var count: Int?
    /// Relative pixel offsets for moveby / dragby / scroll.
    public var dx: Int?
    public var dy: Int?
    /// Target list for "cycletarget" (falls back to all calibrated targets).
    public var list: [String]?
    /// "palette" step: names a Color-page palette state (e.g. "HDR"); empty
    /// string clears the state. "stop" step: the explanation message.
    public var tag: String?
    /// Legacy "branch" steps' else-target (pre-tree configs). Used only by
    /// the branch→choose migration; new configs never write it.
    public var target2: String?
    /// Recursive condition expression for "if" / choose options. Legacy
    /// single-comparison `cond` values decode into a one-item group.
    public var expr: MacroExpr?
    /// Children: if→THEN, choose→DEFAULT, sequence/repeat→body.
    public var children: [MacroStep]?
    /// Children: if→ELSE.
    public var children2: [MacroStep]?
    /// "choose" options, evaluated top to bottom; first match wins.
    public var options: [ChooseOption]?
    /// Custom display name (replaces the generated summary in the editor).
    public var name: String?
    /// Node-level disable: skipped at execution, muted in the editor.
    public var off: Bool?
    /// Legacy leaf-level gate (pre-tree configs): run only while the tracked
    /// palette state equals this. New editors should use "if" blocks.
    public var when: String?

    public init(type: String, target: String? = nil, keyCode: Int? = nil, flags: Int? = nil, ms: Int? = nil,
                button: Int? = nil, count: Int? = nil, dx: Int? = nil, dy: Int? = nil, list: [String]? = nil,
                tag: String? = nil, target2: String? = nil, expr: MacroExpr? = nil, children: [MacroStep]? = nil,
                children2: [MacroStep]? = nil, options: [ChooseOption]? = nil,
                name: String? = nil, off: Bool? = nil, when: String? = nil) {
        self.type = type
        self.id = Self.newID()
        self.target = target
        self.keyCode = keyCode
        self.flags = flags
        self.ms = ms
        self.button = button
        self.count = count
        self.dx = dx
        self.dy = dy
        self.list = list
        self.tag = tag
        self.target2 = target2
        self.expr = expr
        self.children = children
        self.children2 = children2
        self.options = options
        self.name = name
        self.off = off
        self.when = when
    }

    /// Coding that preserves identity + children for tree nodes while staying
    /// compatible with pre-tree config files (all new keys optional).
    enum CodingKeys: String, CodingKey {
        case type, id, target, target2, keyCode, flags, ms, button, count, dx, dy, list
        case tag, cond, expr, children, children2, options, name, off, when
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Self.newID()
        target = try c.decodeIfPresent(String.self, forKey: .target)
        keyCode = try c.decodeIfPresent(Int.self, forKey: .keyCode)
        flags = try c.decodeIfPresent(Int.self, forKey: .flags)
        ms = try c.decodeIfPresent(Int.self, forKey: .ms)
        button = try c.decodeIfPresent(Int.self, forKey: .button)
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        dx = try c.decodeIfPresent(Int.self, forKey: .dx)
        dy = try c.decodeIfPresent(Int.self, forKey: .dy)
        list = try c.decodeIfPresent([String].self, forKey: .list)
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        target2 = try c.decodeIfPresent(String.self, forKey: .target2)
        // New format: recursive expr; legacy: a single comparison wrapped
        // into a one-item group (identical behavior).
        if let e = try? c.decode(MacroExpr.self, forKey: .expr) {
            expr = e
        } else if let legacy = try? c.decode(MacroCond.self, forKey: .cond) {
            expr = .group(.all, [.cond(legacy)])
        } else {
            expr = nil
        }
        children = try c.decodeIfPresent([MacroStep].self, forKey: .children)
        children2 = try c.decodeIfPresent([MacroStep].self, forKey: .children2)
        options = try c.decodeIfPresent([ChooseOption].self, forKey: .options)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        off = try c.decodeIfPresent(Bool.self, forKey: .off)
        when = try c.decodeIfPresent(String.self, forKey: .when)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(target, forKey: .target)
        try c.encodeIfPresent(keyCode, forKey: .keyCode)
        try c.encodeIfPresent(flags, forKey: .flags)
        try c.encodeIfPresent(ms, forKey: .ms)
        try c.encodeIfPresent(button, forKey: .button)
        try c.encodeIfPresent(count, forKey: .count)
        try c.encodeIfPresent(dx, forKey: .dx)
        try c.encodeIfPresent(dy, forKey: .dy)
        try c.encodeIfPresent(list, forKey: .list)
        try c.encodeIfPresent(tag, forKey: .tag)
        try c.encodeIfPresent(target2, forKey: .target2)
        try c.encodeIfPresent(expr, forKey: .expr)
        try c.encodeIfPresent(children, forKey: .children)
        try c.encodeIfPresent(children2, forKey: .children2)
        try c.encodeIfPresent(options, forKey: .options)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(off, forKey: .off)
        try c.encodeIfPresent(when, forKey: .when)
    }

    public static func newID() -> String { UUID().uuidString }

    // MARK: Factories

    public static func goto(_ name: String) -> MacroStep { MacroStep(type: "goto", target: name) }
    public static func click() -> MacroStep { MacroStep(type: "click") }
    public static func hold() -> MacroStep { MacroStep(type: "hold") }
    public static func key(_ code: Int, _ flags: Int = 0) -> MacroStep { MacroStep(type: "key", keyCode: code, flags: flags) }
    public static func wait(_ ms: Int) -> MacroStep { MacroStep(type: "wait", ms: ms) }
    /// Set (or "" to clear) the tracked palette state, e.g. "HDR".
    public static func setTag(_ tag: String) -> MacroStep { MacroStep(type: "palette", tag: tag) }

    /// If / Else block: `then` runs when the condition expression matches,
    /// else `els`. A bare comparison is wrapped into a one-item group.
    public static func ifBlock(_ cond: MacroCond, then: [MacroStep], els: [MacroStep] = []) -> MacroStep {
        MacroStep(type: "if", expr: .group(.all, [.cond(cond)]), children: then, children2: els)
    }
    public static func ifBlock(_ expr: MacroExpr, then: [MacroStep], els: [MacroStep] = []) -> MacroStep {
        MacroStep(type: "if", expr: expr, children: then, children2: els)
    }
    /// Choose block: first option whose condition matches runs; default = children.
    public static func choose(_ options: [ChooseOption], default actions: [MacroStep] = []) -> MacroStep {
        MacroStep(type: "choose", children: actions, options: options)
    }
    public static func sequence(_ actions: [MacroStep], name: String? = nil) -> MacroStep {
        MacroStep(type: "sequence", children: actions, name: name)
    }
    public static func repeatBlock(_ times: Int, _ actions: [MacroStep]) -> MacroStep {
        MacroStep(type: "repeat", count: times, children: actions)
    }
    public static func stop(_ message: String? = nil) -> MacroStep { MacroStep(type: "stop", tag: message) }

    // MARK: Tree shape

    public var isContainer: Bool {
        switch type {
        case "if", "choose", "sequence", "repeat": return true
        default: return false
        }
    }

    /// The block's own condition expression (if blocks; choose options
    /// carry their own). nil = not configured yet.
    public var blockCond: MacroExpr? { expr }

    /// Human button name for diagnostics/labels.
    public static func buttonName(_ raw: Int?) -> String {
        switch raw ?? 0 {
        case 1: return "right"
        case 2: return "middle"
        default: return "left"
        }
    }

    // MARK: Description
    //
    // IDs are stored; NAMES are resolved at render time. Every user-facing
    // call site passes a `labels` resolver (config.targetLabel); the raw
    // parameterless `describe` is internal-only fallback.

    public typealias TargetLabeler = (String) -> String

    public func describe(labels: TargetLabeler?) -> String {
        if let n = name, !n.isEmpty { return n }
        switch type {
        case "goto": return "go to \(targetName(labels))"
        case "click":
            let n = count ?? 1
            let clicks = n == 1 ? "" : (n == 2 ? " double" : " ×\(n)")
            let btn = (button ?? 0) == 0 ? "" : " \(Self.buttonName(button))-button"
            return "click\(clicks)\(btn)"
        case "clicktarget": return "click \(targetName(labels)) (\(Self.buttonName(button)))"
        case "hold": return "hold (dial drags, auto-release)"
        case "key":
            let f = Int(flags ?? 0)
            var mods = ""
            if f & 1 << 20 != 0 { mods += "⌘" }   // kCGEventFlagMaskCommand
            if f & 1 << 19 != 0 { mods += "⌥" }   // kCGEventFlagMaskAlternate
            if f & 1 << 17 != 0 { mods += "⇧" }   // kCGEventFlagMaskShift
            if f & 1 << 18 != 0 { mods += "⌃" }   // kCGEventFlagMaskControl
            return "key \(mods)\(KeyEventNames.name(for: UInt16(keyCode ?? 0)))"
        case "wait": return "wait \(ms ?? 0) ms"
        case "savepos": return "save cursor position"
        case "restorepos": return "restore cursor position"
        case "moveby": return "move cursor by (\(dx ?? 0), \(dy ?? 0)) px"
        case "dragby": return "drag by (\(dx ?? 0), \(dy ?? 0)) px"
        case "scroll": return "scroll \(dy ?? 0) lines"
        case "mousedown": return "\(Self.buttonName(button)) mouse down"
        case "mouseup": return "\(Self.buttonName(button)) mouse up"
        case "keydown": return "key down \(KeyEventNames.name(for: UInt16(keyCode ?? 0)))"
        case "keyup": return "key up \(KeyEventNames.name(for: UInt16(keyCode ?? 0)))"
        case "sens": return "dial sensitivity \(sensPercent)%"
        case "cycletarget": return "cycle targets (\(cycleList.count))"
        case "releaseall": return "release all held inputs"
        case "palette":
            let t = tag ?? ""
            return t.isEmpty ? "palette state — clear" : "palette state → \(t)"
        case "ensure": return "ensure palette “\(tag ?? "?")”"
        case "lighton", "lightoff", "lighttoggle":
            let key = SpeedEditorKey.allCases.first { $0.id == tag }?.label ?? tag
            let verb = type == "lighton" ? "turn on" : (type == "lightoff" ? "turn off" : "toggle")
            return "\(verb) \(key) light"
        case "if":
            let c = expr?.summary() ?? "?"
            return "if \(c)  (\((children ?? []).count) ⇄ \((children2 ?? []).count))"
        case "choose":
            return "choose by condition  (\(options?.count ?? 0) options)"
        case "sequence":
            let n = name ?? ""
            return n.isEmpty ? "sequence (\((children ?? []).count))" : "\(n) (\((children ?? []).count))"
        case "repeat": return "repeat ×\(count ?? 2)  (\((children ?? []).count))"
        case "stop": return "stop\(tag?.isEmpty == false ? " — \(tag!)" : "")"
        case "branch": return "if palette '\(tag ?? "?")' → \(targetName(labels))"  // legacy
        default: return type
        }
    }

    /// Resolve a target id to its display name; IDs must never surface.
    private func targetName(_ labels: TargetLabeler?) -> String {
        guard let t = target, !t.isEmpty else { return "?" }
        return labels?(t) ?? t
    }

    /// describe plus the conditional suffix ("· only if …").
    public func describeStrict(labels: TargetLabeler?) -> String {
        if let w = when, !w.isEmpty { return "\(describe(labels: labels))  · only if \(w)" }
        return describe(labels: labels)
    }

    /// Raw fallback for internal contexts that have no labeler.
    public var describe: String { describe(labels: nil) }

    /// Sensitivity factor in percent (1–1000).
    public var sensPercent: Int { min(max(ms ?? 100, 1), 1000) }

    /// Resolved target list for cycletarget.
    public var cycleList: [String] {
        let l = (list ?? []).filter { !$0.isEmpty }
        return l
    }

    // MARK: Tree queries

    /// All LEAF steps in execution order (containers flattened).
    public func leaves() -> [MacroStep] {
        if !isContainer {
            return type == "stop" ? [self] : [self]
        }
        var out: [MacroStep] = []
        switch type {
        case "if":
            out += (children ?? []).flatMap { $0.leaves() }
            out += (children2 ?? []).flatMap { $0.leaves() }
        case "choose":
            for o in options ?? [] { out += o.actions.flatMap { $0.leaves() } }
            out += (children ?? []).flatMap { $0.leaves() }
        case "sequence", "repeat":
            out += (children ?? []).flatMap { $0.leaves() }
        default: break
        }
        return out
    }

    /// Total action count including nested ones (editor section counters).
    public var actionCount: Int { leaves().count }

    /// Every calibrated-target id referenced anywhere in this subtree.
    public func allTargets(into set: inout Set<String>) {
        if let t = target, !t.isEmpty { set.insert(t) }
        for c in children ?? [] { c.allTargets(into: &set) }
        for c in children2 ?? [] { c.allTargets(into: &set) }
        for o in options ?? [] {
            for a in o.actions { a.allTargets(into: &set) }
        }
    }

    public var allTargetIds: Set<String> {
        var s: Set<String> = []
        allTargets(into: &s)
        return s
    }

    /// Rewrite target ids anywhere in the subtree (target rename/delete).
    public func retargeted(from old: String, to new: String?) -> MacroStep {
        var n = self
        if n.target == old { n.target = new }
        if children != nil { n.children = (children ?? []).map { $0.retargeted(from: old, to: new) } }
        if children2 != nil { n.children2 = (children2 ?? []).map { $0.retargeted(from: old, to: new) } }
        if let opts = options {
            n.options = opts.map { o in
                var o = o
                o.actions = o.actions.map { $0.retargeted(from: old, to: new) }
                return o
            }
        }
        return n
    }

    /// Depth-first search for a node by stable id.
    public func find(id: String) -> MacroStep? {
        if self.id == id { return self }
        for c in children ?? [] { if let f = c.find(id: id) { return f } }
        for c in children2 ?? [] { if let f = c.find(id: id) { return f } }
        for o in options ?? [] { for a in o.actions { if let f = a.find(id: id) { return f } } }
        return nil
    }

    /// Where a node lives: parent id + child-list slot + index within it.
    /// Root lists use parentID "" and slot "root".
    public struct NodePath: Equatable, Sendable {
        public let parentID: String
        public let slot: String
        public let index: Int
    }

    /// Locate a node by id inside a top-level list.
    public static func locate(id: String, in list: [MacroStep]) -> NodePath? {
        locate(id: id, in: list, parentID: "", slot: "root")
    }

    private static func locate(id: String, in list: [MacroStep], parentID: String, slot: String) -> NodePath? {
        for (i, n) in list.enumerated() {
            if n.id == id { return NodePath(parentID: parentID, slot: slot, index: i) }
            if let kids = n.children,
               let p = locate(id: id, in: kids, parentID: n.id ?? "", slot: n.type == "choose" ? "default" : "children") {
                return p
            }
            if let kids = n.children2,
               let p = locate(id: id, in: kids, parentID: n.id ?? "", slot: "else") { return p }
            if let opts = n.options {
                for o in opts where !o.actions.isEmpty {
                    if let p = locate(id: id, in: o.actions, parentID: n.id ?? "", slot: "option:\(o.id)") { return p }
                }
            }
        }
        return nil
    }

    /// Apply a transform to the node with the given id, in place.
    @discardableResult
    public static func updating(id: String, transform: (inout MacroStep) -> Void,
                                in list: inout [MacroStep]) -> Bool {
        for i in list.indices {
            if list[i].id == id { transform(&list[i]); return true }
            var kids = list[i].children ?? []
            if updating(id: id, transform: transform, in: &kids) { list[i].children = kids; return true }
            var kids2 = list[i].children2 ?? []
            if updating(id: id, transform: transform, in: &kids2) { list[i].children2 = kids2; return true }
            if var opts = list[i].options {
                var changed = false
                for j in opts.indices {
                    var acts = opts[j].actions
                    if updating(id: id, transform: transform, in: &acts) {
                        opts[j].actions = acts
                        changed = true
                        break
                    }
                }
                if changed { list[i].options = opts; return true }
            }
        }
        return false
    }

    /// Does this subtree contain the given node id? (descendant guard)
    public func contains(id: String) -> Bool { find(id: id) != nil }

    /// Remove the node with the given id from a list (recursively). Returns
    /// the updated list and the removed node (nil when not found).
    public static func removing(id: String, from list: [MacroStep]) -> (list: [MacroStep], removed: MacroStep?) {
        var out: [MacroStep] = []
        var removed: MacroStep?
        for var n in list {
            if n.id == id { removed = n; continue }
            if let kids = n.children {
                let r = removing(id: id, from: kids)
                if r.removed != nil { removed = r.removed }
                n.children = r.list
            }
            if let kids = n.children2 {
                let r = removing(id: id, from: kids)
                if r.removed != nil { removed = r.removed }
                n.children2 = r.list
            }
            if var opts = n.options {
                for i in opts.indices {
                    let r = removing(id: id, from: opts[i].actions)
                    if r.removed != nil { removed = r.removed }
                    opts[i].actions = r.list
                }
                n.options = opts
            }
            out.append(n)
        }
        return (out, removed)
    }

    public static func arrayInsert(_ node: MacroStep, at index: Int, in list: [MacroStep]) -> [MacroStep] {
        var l = list
        l.insert(node, at: min(max(index, 0), l.count))
        return l
    }

    /// Insert a node into the child list addressed by parent id + slot, at
    /// the given index within that list. Slots: "then" | "else" |
    /// "default" | "children" | "option:<option-id>". Root lists are handled
    /// by the caller (they're plain arrays).
    @discardableResult
    public static func insert(_ node: MacroStep, parentID: String, slot: String, index: Int,
                              into list: inout [MacroStep]) -> Bool {
        for i in list.indices {
            if list[i].id == parentID {
                switch slot {
                case "then", "children":
                    list[i].children = arrayInsert(node, at: index, in: list[i].children ?? [])
                    return true
                case "else":
                    list[i].children2 = arrayInsert(node, at: index, in: list[i].children2 ?? [])
                    return true
                case "default":
                    list[i].children = arrayInsert(node, at: index, in: list[i].children ?? [])
                    return true
                default:
                    if slot.hasPrefix("option:") {
                        let oid = String(slot.dropFirst("option:".count))
                        guard var opts = list[i].options,
                              let oi = opts.firstIndex(where: { $0.id == oid }) else { return false }
                        opts[oi].actions = arrayInsert(node, at: index, in: opts[oi].actions)
                        list[i].options = opts
                        return true
                    }
                    return false
                }
            }
            var kids = list[i].children ?? []
            if insert(node, parentID: parentID, slot: slot, index: index, into: &kids) {
                list[i].children = kids
                return true
            }
            var kids2 = list[i].children2 ?? []
            if insert(node, parentID: parentID, slot: slot, index: index, into: &kids2) {
                list[i].children2 = kids2
                return true
            }
            if var opts = list[i].options {
                var changed = false
                for j in opts.indices {
                    var acts = opts[j].actions
                    if insert(node, parentID: parentID, slot: slot, index: index, into: &acts) {
                        opts[j].actions = acts
                        changed = true
                        break
                    }
                }
                if changed { list[i].options = opts; return true }
            }
        }
        return false
    }

    /// Move a node up/down within its own sibling list (−1 or +1).
    @discardableResult
    public static func move(id: String, offset: Int, in list: inout [MacroStep]) -> Bool {
        for i in list.indices {
            if list[i].id == id {
                let j = i + offset
                guard list.indices.contains(j) else { return false }
                list.swapAt(i, j)
                return true
            }
            var kids = list[i].children ?? []
            if move(id: id, offset: offset, in: &kids) { list[i].children = kids; return true }
            var kids2 = list[i].children2 ?? []
            if move(id: id, offset: offset, in: &kids2) { list[i].children2 = kids2; return true }
            if var opts = list[i].options {
                var changed = false
                for j in opts.indices {
                    var acts = opts[j].actions
                    if move(id: id, offset: offset, in: &acts) { opts[j].actions = acts; changed = true; break }
                }
                if changed { list[i].options = opts; return true }
            }
        }
        return false
    }

    /// Deep copy with FRESH ids everywhere (duplicates must be unique).
    public func duplicated() -> MacroStep {
        var n = self
        n.id = Self.newID()
        n.children = (children ?? []).map { $0.duplicated() }
        n.children2 = (children2 ?? []).map { $0.duplicated() }
        if var opts = options {
            for i in opts.indices { opts[i].id = UUID().uuidString }
            for i in opts.indices { opts[i].actions = opts[i].actions.map { $0.duplicated() } }
            n.options = opts
        }
        return n
    }

    // MARK: Legacy migration ("branch" → "choose")

    /// Pre-tree configs encoded if/else as a flat "branch" leaf pointing at
    /// two targets. Convert to a real choose block so the editor shows it
    /// as nested actions. Also normalizes: every if/option expression becomes
    /// a group (one-item groups wrap bare comparisons). Applied on every load.
    public static func migratedTree(_ list: [MacroStep]) -> [MacroStep] {
        list.map { step -> MacroStep in
            var s = step
            if s.type == "branch" {
                var opts: [ChooseOption] = []
                if let tag = s.tag, !tag.isEmpty {
                    var acts: [MacroStep] = []
                    if let t = s.target { acts.append(.goto(t)) }
                    opts = [ChooseOption(expr: .group(.all, [.cond(MacroCond(kind: .palette, value: tag))]), actions: acts)]
                }
                var def: [MacroStep] = []
                if let t2 = s.target2, !t2.isEmpty { def = [.goto(t2)] }
                s = .choose(opts, default: def)
                s.id = s.id ?? Self.newID()
            }
            // Normalize: bare comparisons → one-item groups (editor invariant).
            if let e = s.expr, case .cond = e {
                s.expr = .group(.all, [e])
            }
            if var opts = s.options {
                for i in opts.indices {
                    if case .cond = opts[i].expr {
                        opts[i].expr = .group(.all, [opts[i].expr])
                    }
                    opts[i].actions = migratedTree(opts[i].actions)
                }
                s.options = opts
            }
            if s.children != nil { s.children = migratedTree(s.children!) }
            if s.children2 != nil { s.children2 = migratedTree(s.children2!) }
            return s
        }
    }

    /// Convenience: strip the optional condition (used when copying steps).
    public func unconditioned() -> MacroStep {
        var s = self
        s.when = nil
        return s
    }
}

public enum MacroDefaults {
    /// Synthesized when a config has no bindings yet — preserves the proven
    /// CAM1-4 = hold-the-wheels behavior.
    public static func migrated() -> [String: [MacroStep]] {
        [
            "cam1": [.goto("wheel_1_color"), .hold()],
            "cam2": [.goto("wheel_2_color"), .hold()],
            "cam3": [.goto("wheel_3_color"), .hold()],
            "cam4": [.goto("wheel_4_color"), .hold()],
        ]
    }
}

/// Human-readable names for macOS virtual keycodes (subset that matters).
public enum KeyEventNames {
    public static let table: [UInt16: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0",
        0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P",
        0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\",
        0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".",
        0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete", 0x35: "Esc",
        0x69: "F13", 0x6A: "F16", 0x6B: "F14", 0x71: "F15",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x73: "Home", 0x74: "End", 0x75: "PgUp", 0x77: "PgDn",
    ]

    public static func name(for code: UInt16) -> String {
        table[code] ?? String(format: "key 0x%02x", code)
    }
}
