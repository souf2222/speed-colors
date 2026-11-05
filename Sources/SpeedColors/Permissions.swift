// Permissions.swift — the privacy grants SpeedColors needs, checked and
// asked for at launch.
//
//   • Accessibility     — injecting keys & mouse events into Resolve
//   • Screen Recording  — palette auto-detect (reading the Color page strip)
//   • Input Monitoring  — the shortcut-recorder event tap ("key" step capture)
//
// The first two have system prompt APIs; Input Monitoring has none, so its
// status comes from a short-lived listen-only event tap probe (the same
// attempt macOS itself asks about) and its button opens the Settings pane.

import AppKit
import ApplicationServices
import CoreGraphics

enum AppPermissions {

    // MARK: Status

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Probe: a listen-only HID tap can only be created by a process the
    /// system trusts with keyboard events. Side-effect free — the tap is
    /// never added to a run loop, so it can never see a callback.
    static var inputMonitoringGranted: Bool {
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil) else { return false }
        CFMachPortInvalidate(tap)
        return true
    }

    // MARK: Asking

    /// System dialog: "… would like to control this computer". On modern
    /// macOS the dialog is SKIPPED when the app is already listed in the pane
    /// (e.g. a stale entry from a previous build) — so after the prompt
    /// attempt we open the pane directly and bring Settings to the front.
    /// The visible cue is then the switch itself, not a dialog.
    static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) { return }
        openSettingsPane("Privacy_Accessibility")
    }

    /// Same deal as Accessibility: `CGRequestScreenCaptureAccess` no-ops when
    /// a stale entry exists — make the pane appear regardless.
    static func promptScreenRecording() {
        if CGPreflightScreenCaptureAccess() { return }
        _ = CGRequestScreenCaptureAccess()
        openSettingsPane("Privacy_ScreenCapture")
    }

    /// No prompt API exists — open the Input Monitoring pane directly.
    static func promptInputMonitoring() {
        openSettingsPane("Privacy_ListenEvent")
    }

    static func openSettingsPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Resetting stale entries

    /// Clears the TCC entry for this app (`tccutil reset <service> <bundle>`).
    /// This is the fix for the silent no-prompt state: a rebuilt ad-hoc
    /// binary keeps the OLD (disabled/stale) listing, macOS never re-prompts
    /// for a listed app — after a reset the next prompt attempt shows the
    /// real dialog again. Requires a bundle id (raw binaries can't be
    /// targeted; resetting the whole service would nuke every app).
    @discardableResult
    static func resetEntry(_ kind: Kind) -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", kind.tccService, bundleId]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: Catalog

    enum Kind: String, CaseIterable, Identifiable {
        case accessibility
        case screenRecording
        case inputMonitoring

        var id: String { rawValue }

        var title: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .screenRecording: return "Screen Recording"
            case .inputMonitoring: return "Input Monitoring"
            }
        }

        var why: String {
            switch self {
            case .accessibility: return "injects keys & mouse into Resolve"
            case .screenRecording: return "palette auto-detect reads the screen"
            case .inputMonitoring: return "shortcut recorder captures keys"
            }
        }

        /// TCC service name as `tccutil reset` expects it.
        var tccService: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .screenRecording: return "ScreenCapture"
            case .inputMonitoring: return "ListenEvent"
            }
        }

        var granted: Bool {
            switch self {
            case .accessibility: return accessibilityGranted
            case .screenRecording: return screenRecordingGranted
            case .inputMonitoring: return inputMonitoringGranted
            }
        }

        func prompt() {
            switch self {
            case .accessibility: promptAccessibility()
            case .screenRecording: promptScreenRecording()
            case .inputMonitoring: promptInputMonitoring()
            }
        }
    }
}
