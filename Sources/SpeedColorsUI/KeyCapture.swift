// KeyCapture.swift — system-wide shortcut recorder used by action rows.
//
// KeyCaptureTap is a CGEvent tap (listen + swallow): the combo is captured no
// matter which app is active, and never leaks into the app behind the panel.
// Falls back to local+global NSEvent monitors if the tap can't be created
// (missing Input Monitoring permission) — capture still works there, but the
// key may also reach the app behind (macOS won't let a passive monitor swallow
// foreign keys).

import AppKit
import SwiftUI
import SpeedColorsCore

final class KeyCaptureTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let onKey: (UInt16, UInt64) -> Void

    /// The C callback can't capture context; route through this static.
    private static var active: KeyCaptureTap?

    init(onKey: @escaping (UInt16, UInt64) -> Void) {
        self.onKey = onKey
    }

    func install() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        KeyCaptureTap.active = self
        guard let t = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in
                guard let me = KeyCaptureTap.active else {
                    return Unmanaged.passUnretained(event)
                }
                me.handle(event)
                return nil  // swallow: the combo never reaches the app behind
            },
            userInfo: nil) else {
            KeyCaptureTap.active = nil
            return false
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private func handle(_ event: CGEvent) {
        onKey(UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
              UInt64(event.flags.rawValue))
    }

    func remove() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        if let t = tap { CFMachPortInvalidate(t) }
        tap = nil
        source = nil
        KeyCaptureTap.active = nil
    }
}

struct KeyCaptureButton: View {
    @Binding var step: MacroStep
    @State private var capturing = false
    @State private var tap: KeyCaptureTap?
    @State private var localMonitor: Any?
    @State private var globalMonitor: Any?

    /// Modifier keys alone never complete a capture (they're half of a combo).
    private static let modifierKeyCodes: Set<UInt16> = [0x37, 0x38, 0x39, 0x3A, 0x3B, 0x68]
    private static let modMask = 1 << 17 | 1 << 18 | 1 << 19 | 1 << 20  // ⇧ ⌃ ⌥ ⌘

    private var label: String {
        guard let code = step.keyCode else { return "Record shortcut…" }
        var s = KeyEventNames.name(for: UInt16(code))
        let f = step.flags ?? 0
        if f & 1 << 20 != 0 { s = "⌘" + s }
        if f & 1 << 19 != 0 { s = "⌥" + s }
        if f & 1 << 18 != 0 { s = "⌃" + s }
        if f & 1 << 17 != 0 { s = "⇧" + s }
        return s
    }

    var body: some View {
        Button(capturing ? "press a key combo…" : label) { beginCapture() }
            .buttonStyle(GraphiteButtonStyle(accent: capturing ? Graphite.amber : (step.keyCode == nil ? Graphite.amber : nil)))
            .onDisappear { endCapture() }
    }

    /// Returns true when the event was handled (and should be swallowed).
    @discardableResult
    private func capture(_ keyCode: UInt16, _ flags: UInt64) -> Bool {
        guard capturing else { return false }
        if Self.modifierKeyCodes.contains(keyCode) {
            return true  // modifier alone: keep waiting for the full combo
        }
        if keyCode == 0x35 {  // ESC reserved for force-release on the Color page
            endCapture()
            return true
        }
        step.keyCode = Int(keyCode)
        step.flags = Int(flags) & Self.modMask
        endCapture()
        return true
    }

    private func beginCapture() {
        endCapture()
        capturing = true
        let t = KeyCaptureTap { keyCode, flags in
            _ = capture(keyCode, flags)
        }
        if t.install() {
            tap = t
            return
        }
        // Fallback: local monitor (app active) + global monitor (any other
        // app active — can't swallow there, but the capture still lands).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            _ = capture(UInt16(ev.keyCode), UInt64(ev.modifierFlags.rawValue))
            return nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { ev in
            _ = capture(UInt16(ev.keyCode), UInt64(ev.modifierFlags.rawValue))
        }
    }

    private func endCapture() {
        capturing = false
        tap?.remove()
        tap = nil
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        localMonitor = nil
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
    }
}
