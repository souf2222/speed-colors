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

    /// Mouse buttons for synthetic events (HID button identifiers).
    public enum HWButton: Int, CaseIterable {
        case left = 0
        case right = 1
        case middle = 2

        var cg: CGMouseButton {
            switch self {
            case .left: return .left
            case .right: return .right
            case .middle: return .center
            }
        }
        var downType: CGEventType {
            switch self {
            case .left: return .leftMouseDown
            case .right: return .rightMouseDown
            case .middle: return .otherMouseDown
            }
        }
        var upType: CGEventType {
            switch self {
            case .left: return .leftMouseUp
            case .right: return .rightMouseUp
            case .middle: return .otherMouseUp
            }
        }
    }

    private static func make(_ type: CGEventType, at point: CGPoint,
                             button: HWButton = .left) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: point, mouseButton: button.cg) else { return nil }
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

    /// Relative move (pixels), clamped to the screen bounds.
    public static func moveBy(dx: Int, dy: Int) {
        let screen = screenSize
        let p = currentPosition()
        let target = CGPoint(
            x: min(max(p.x + CGFloat(dx), 0), screen.width - 1),
            y: min(max(p.y + CGFloat(dy), 0), screen.height - 1))
        move(to: target)
    }

    public static func down(at point: CGPoint, button: HWButton = .left) {
        guard let e = make(button.downType, at: point, button: button) else { return }
        e.post(tap: .cghidEventTap)
    }

    public static func drag(to point: CGPoint, button: HWButton = .left) {
        guard let e = make(mouseDragType(button), at: point, button: button) else { return }
        e.post(tap: .cghidEventTap)
    }

    private static func mouseDragType(_ b: HWButton) -> CGEventType {
        switch b {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }

    /// One or more clicks (1 = single, 2 = double, 3 = triple).
    public static func click(at point: CGPoint, button: HWButton = .left, count: Int = 1) {
        let n = max(1, min(count, 3))
        var moved = false
        if abs(point.x - currentPosition().x) > 1 || abs(point.y - currentPosition().y) > 1 {
            move(to: point)
            usleep(20_000)
            moved = true
        }
        for i in 1...n {
            down(at: point, button: button)
            usleep(35_000)
            up(at: point, button: button)
            if i < n { usleep(60_000) }
        }
        _ = moved
    }

    /// Ends a press: final dragged frame at the release point, then the up.
    /// `pressed` should be true when the up closes an actual down/drag
    /// sequence (vs a plain up with no prior press).
    public static func up(at point: CGPoint, pressed: Bool = false, button: HWButton = .left) {
        if pressed, button == .left {
            drag(to: point)
            usleep(12_000)
        }
        guard let e = make(button.upType, at: point, button: button) else { return }
        e.post(tap: .cghidEventTap)
    }

    /// Vertical wheel scroll (positive dy = scroll up). Posted to the
    /// foreground app; wheel events don't need to be PID-targeted to land.
    public static func scroll(dy: Int) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                              wheelCount: 1, wheel1: -Int32(dy), wheel2: 0, wheel3: 0)
        else { return }
        e.post(tap: .cghidEventTap)
    }

    /// Global screen size (for clamping drags).
    public static var screenSize: CGSize {
        let b = CGDisplayBounds(CGMainDisplayID())
        return b.size
    }
}
