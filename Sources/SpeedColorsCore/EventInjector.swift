// EventInjector.swift — synthetic mouse/keyboard events for Resolve (CGEvent).
// Requires Accessibility permission (AXIsProcessTrusted) for the running binary.

import ApplicationServices
import CoreGraphics
import Darwin

public enum EventInjector {
    /// Virtual keycodes of the modifier keys, for chorded injection.
    private static let modifierKeyCodes: [(flag: UInt64, code: CGKeyCode)] = [
        (1 << 20, 0x37),  // ⌘ command
        (1 << 19, 0x3A),  // ⌥ option
        (1 << 18, 0x3B),  // ⌃ control
        (1 << 17, 0x38),  // ⇧ shift
    ]

    private static func post(_ e: CGEvent, toPid pid: pid_t?) {
        if let pid { e.postToPid(pid) } else { e.post(tap: .cghidEventTap) }
    }

    /// Post a full key down/up pair with optional modifiers. `toPid` targets a
    /// specific process so the combo can never land in whatever app happens to
    /// be frontmost.
    public static func tapKey(_ keyCode: CGKeyCode, flags: CGEventFlags = [], toPid pid: pid_t? = nil) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        if !flags.isEmpty { down.flags = flags }
        post(down, toPid: pid)
        usleep(18_000)
        guard let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        if !flags.isEmpty { up.flags = flags }
        post(up, toPid: pid)
    }

    /// Chorded tap: REAL modifier keyDown events first, then the key, then
    /// modifiers released. Apps that track modifier STATE from actual modifier
    /// key events (Qt apps like Resolve) ignore flags painted onto a synthetic
    /// letter event — a bare "T with ⌘ flag" reads as a plain T there. The
    /// chord reproduces the real hardware sequence.
    public static func tapChord(_ keyCode: CGKeyCode, flags: CGEventFlags = [], toPid pid: pid_t? = nil) {
        let mods = modifierKeyCodes.filter { flags.contains(CGEventFlags(rawValue: $0.flag)) }
        for m in mods {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: m.code, keyDown: true) else { continue }
            e.flags = flags
            post(e, toPid: pid)
        }
        if !mods.isEmpty { usleep(24_000) }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        down.flags = flags
        post(down, toPid: pid)
        usleep(18_000)
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            post(up, toPid: pid)
        }
        if !mods.isEmpty {
            usleep(24_000)
            for m in mods.reversed() {
                guard let e = CGEvent(keyboardEventSource: nil, virtualKey: m.code, keyDown: false) else { continue }
                e.flags = []
                post(e, toPid: pid)
            }
        }
    }

    public static func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Chorded key DOWN only (modifiers pressed first, held). Pair with
    /// `chordUp` — for "hold shortcut while pressed" bindings.
    public static func chordDown(_ keyCode: CGKeyCode, flags: CGEventFlags = [], toPid pid: pid_t? = nil) {
        let mods = modifierKeyCodes.filter { flags.contains(CGEventFlags(rawValue: $0.flag)) }
        for m in mods {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: m.code, keyDown: true) else { continue }
            e.flags = flags
            post(e, toPid: pid)
        }
        if !mods.isEmpty { usleep(24_000) }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        down.flags = flags
        post(down, toPid: pid)
    }

    /// Chorded key UP (complement of `chordDown`).
    public static func chordUp(_ keyCode: CGKeyCode, flags: CGEventFlags = [], toPid pid: pid_t? = nil) {
        guard let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        up.flags = flags
        post(up, toPid: pid)
        let mods = modifierKeyCodes.filter { flags.contains(CGEventFlags(rawValue: $0.flag)) }
        usleep(24_000)
        for m in mods.reversed() {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: m.code, keyDown: false) else { continue }
            e.flags = []
            post(e, toPid: pid)
        }
    }

    public static let accessibilityInstructions = """
    ⚠️  Accessibility permission required.
        System Settings → Privacy & Security → Accessibility
        → add & enable the app that runs SpeedColors (the bundle or the raw binary).
        Then restart the daemon.
    """
}
