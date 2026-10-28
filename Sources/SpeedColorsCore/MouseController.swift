// MouseController.swift — synthetic mouse move/click/drag for the Color page.
// Coordinates are global display coordinates (top-left origin), matching
// CGEvent(source: nil)?.location. Requires the same Accessibility permission
// as keyboard injection.
//
// Fidelity notes (Qt apps like Resolve are picky):
//   • Events use the combined-session source: absolute positions are honored
//     at every tap. (HID-system-state events at the HID tap IGNORE absolute
//     locations for moved/dragged events — the cursor didn't move at all.)
//   • clickState = 1 on every event of a press sequence (down/drag/up);
//     mismatched or zero click states can make the app mis-pair the release.
//   • Delta fields are filled from the live cursor position, so apps that
//     track NSEvent deltas see proper motion too.
//   • The release path posts a final dragged frame right before the up so the
//     app sees a proper drag→up sequence, not a stalled tap.

import CoreGraphics
import Foundation

public enum MouseController {

    private static func make(_ type: CGEventType, at point: CGPoint) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: point, mouseButton: .left) else { return nil }
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        // Hardware-like motion deltas (relative to where the cursor is now).
        let cur = CGEvent(source: nil)?.location ?? point
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(point.x - cur.x))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(point.y - cur.y))
        return e
    }

    /// Current cursor position in global display coordinates.
    public static func currentPosition() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    public static func move(to point: CGPoint) {
        guard let e = make(.mouseMoved, at: point) else { return }
        e.post(tap: .cghidEventTap)
    }

    public static func down(at point: CGPoint) {
        guard let e = make(.leftMouseDown, at: point) else { return }
        e.post(tap: .cghidEventTap)
    }

    public static func drag(to point: CGPoint) {
        guard let e = make(.leftMouseDragged, at: point) else { return }
        e.post(tap: .cghidEventTap)
    }

    /// Ends a press: final dragged frame at the release point, then the up.
    /// `pressed` should be true when the up closes an actual down/drag
    /// sequence (vs a plain up with no prior press).
    public static func up(at point: CGPoint, pressed: Bool = false) {
        if pressed {
            drag(to: point)
            usleep(12_000)
        }
        guard let e = make(.leftMouseUp, at: point) else { return }
        e.post(tap: .cghidEventTap)
    }

    /// Global screen size (for clamping drags).
    public static var screenSize: CGSize {
        let b = CGDisplayBounds(CGMainDisplayID())
        return b.size
    }
}
