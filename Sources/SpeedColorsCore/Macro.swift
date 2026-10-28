// Macro.swift — button commands for the Color page.
//
// A binding maps a Speed Editor button to a SEQUENCE of steps, executed on
// each key press while on the Color page. Steps run top to bottom:
//
//   goto(name)  park the cursor on a calibrated target
//   click       full mouse click at the current position
//   hold        press the mouse down and KEEP it down until the SE key is
//               released (the search dial then drags the control)
//   key         inject a keyboard shortcut (virtual keycode + CGEventFlags)
//   wait        pause for N ms
//
// Examples:  "Go to HDR wheel, click"          → [goto hdr, click]
//            "Wheel 1: click and hold to drag" → [goto gamma, hold]

import Foundation

public struct MacroStep: Codable, Equatable {
    public var type: String    // "goto" | "click" | "hold" | "key" | "wait"
    public var target: String?
    public var keyCode: Int?
    public var flags: Int?
    public var ms: Int?

    public init(type: String, target: String? = nil, keyCode: Int? = nil, flags: Int? = nil, ms: Int? = nil) {
        self.type = type
        self.target = target
        self.keyCode = keyCode
        self.flags = flags
        self.ms = ms
    }

    public static func goto(_ name: String) -> MacroStep { MacroStep(type: "goto", target: name) }
    public static func click() -> MacroStep { MacroStep(type: "click") }
    public static func hold() -> MacroStep { MacroStep(type: "hold") }
    public static func key(_ code: Int, _ flags: Int = 0) -> MacroStep { MacroStep(type: "key", keyCode: code, flags: flags) }
    public static func wait(_ ms: Int) -> MacroStep { MacroStep(type: "wait", ms: ms) }

    public var describe: String {
        switch type {
        case "goto": return "go to \(target ?? "?")"
        case "click": return "click"
        case "hold": return "hold (dial drags)"
        case "key":
            let f = Int(flags ?? 0)
            var mods = ""
            if f & 1 << 20 != 0 { mods += "⌘" }   // kCGEventFlagMaskCommand
            if f & 1 << 19 != 0 { mods += "⌥" }   // kCGEventFlagMaskAlternate
            if f & 1 << 17 != 0 { mods += "⇧" }   // kCGEventFlagMaskShift
            if f & 1 << 18 != 0 { mods += "⌃" }   // kCGEventFlagMaskControl
            return "key \(mods)\(KeyEventNames.name(for: UInt16(keyCode ?? 0)))"
        case "wait": return "wait \(ms ?? 0) ms"
        default: return type
        }
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
