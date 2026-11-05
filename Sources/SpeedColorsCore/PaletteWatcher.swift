// PaletteWatcher.swift — screen-based palette auto-detection.
//
// Resolve's scripting API cannot report which Color-page palette is
// frontmost, so speedcolors learns it from the SCREEN instead:
//
//   1. When a tagged binding runs ("go to hdr_page → click → palette HDR"),
//      the daemon captures what the palette strip looks like WHILE that
//      palette is active and stores it as that tag's reference.
//   2. A light timer then compares the live strip against all references.
//      A match keeps the tracked state honest; a change to a DIFFERENT
//      known reference updates the state (mouse-driven switching!); a
//      change to nothing known clears the state instead of going stale.
//
// The strip rectangle is derived from the bindings themselves: the target a
// tagged binding navigates to before setting its palette state IS the tab
// position, so no extra calibration is needed.

import AppKit
import CoreGraphics
import Foundation

final class PaletteWatcher {
    /// Called on the watcher queue when the detected palette changes.
    /// (nil, _) = the strip changed but matches no known palette.
    /// (tag, layout) = palette tag plus the workspace layout its reference
    /// was learned in — a match implies both.
    var onDetected: ((String?, String?) -> Void)?
    /// Called when a reference was captured and stored (persist hook).
    var onReference: ((String, ColorModeConfig.PaletteStripRef) -> Void)?
    var onLog: ((String) -> Void)?

    private var refs: [String: ColorModeConfig.PaletteStripRef] = [:]
    /// Tag → the calibrated point of its tab (global screen coords).
    private var tabPoints: [String: CGPoint] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "speedcolors.palette-watch", qos: .utility)
    /// Last detection we reported (dedupe / only report changes).
    private var lastReported: String?
    /// The workspace layout implied by the last matched reference.
    private(set) var detectedLayout: String?
    /// Consecutive non-matches (2 in a row before declaring unknown).
    private var unknownStreak = 0
    /// Don't fight a binding that just set the state.
    private var graceUntil = Date.distantPast
    private var disabledReason: String?
    /// The layout the daemon says is current (references learn under it).
    var currentLayout: String = "single" {
        didSet { if currentLayout != oldValue { lastReported = nil } }
    }
    /// Tolerance for "same palette" (mean abs gray diff 0…1).
    private let tolerance = 0.085
    /// Reference render size (downscaled grayscale).
    private let refW = 160
    private let refH = 40

    func configure(tabPoints: [String: CGPoint], refs: [String: ColorModeConfig.PaletteStripRef]) {
        queue.async { [weak self] in
            self?.tabPoints = tabPoints
            self?.refs = refs
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            guard CGPreflightScreenCaptureAccess() else {
                self.disabledReason = "no Screen Recording permission"
                self.onLog?("⚠️ palette auto-detect disabled — grant Screen Recording permission")
                return
            }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1.0, repeating: 2.0)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.lastReported = nil
            self?.unknownStreak = 0
        }
    }

    /// Called right after a binding sets the palette state — suppresses
    /// detection overrides briefly while the UI settles.
    func grace() {
        queue.async { [weak self] in
            self?.graceUntil = Date().addingTimeInterval(1.5)
            self?.unknownStreak = 0
        }
    }

    /// Learn the strip's current appearance as `tag`'s reference. Called
    /// slightly AFTER a tagged binding ran (the palette UI needs a beat).
    func captureReference(for tag: String, layout: String) {
        queue.async { [weak self] in self?.currentLayout = layout }
        _captureReference(tag)
    }

    private func _captureReference(_ tag: String) {
        guard !tag.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            guard let rect = self.stripRectGlobal() else {
                self.onLog?("🎨 palette watch: no tab positions derived — add 'Move to target' before 'Set palette state' to learn auto-detect")
                return
            }
            guard let gray = self.captureGray(rect: rect) else {
                self.onLog?("⚠️ palette watch: capture failed — auto-detect unavailable")
                return
            }
            let ref = ColorModeConfig.PaletteStripRef(width: self.refW, height: self.refH, gray: gray)
            self.refs[tag] = ref
            self.lastReported = tag
            self.unknownStreak = 0
            self.onReference?(tag, ref)
            self.onLog?("🎨 palette watch: learned '\(tag)' (\(self.refs.count) reference\(self.refs.count == 1 ? "" : "s"))")
        }
    }

    // MARK: Detection tick

    private func tick() {
        guard disabledReason == nil else { return }
        guard !tabPoints.isEmpty else { return }
        guard let rect = stripRectGlobal() else { return }
        // Window may have moved since configure() — recheck it exists at all.
        guard let window = AutoCal.findResolveWindow(), window.rect.width > 0 else { return }
        guard let gray = captureGray(rect: rect) else { return }
        let now = Date()

        // Nearest reference.
        var bestTag: String?
        var bestDiff = Double.greatestFiniteMagnitude
        for (tag, ref) in refs {
            let d = Self.diff(gray, ref)
            if d < bestDiff {
                bestDiff = d
                bestTag = tag
            }
        }

        if let tag = bestTag, bestDiff <= tolerance, let ref = refs[tag] {
            unknownStreak = 0
            detectedLayout = ref.layout ?? "single"
            if tag != lastReported, now >= graceUntil {
                lastReported = tag
                onLog?("🎨 palette detected on screen → \(tag)\(detectedLayout == "split" ? "  (split workspace)" : "")")
                onDetected?(tag, ref.layout)
            }
        } else {
            // Screen changed to something unknown. Two consecutive misses
            // before clearing (guards transient UI flashes).
            unknownStreak += 1
            if unknownStreak >= 2, now >= graceUntil, lastReported != "__unknown__" {
                lastReported = "__unknown__"
                unknownStreak = 0
                onLog?("🎨 palette changed on screen — unrecognized (press a tagged key to re-sync)")
                onDetected?(nil, nil)
            }
        }
    }

    /// Mean absolute grayscale difference (0…1) between a live capture and a
    /// stored reference. Guarded against size drift.
    static func diff(_ gray: Data, _ ref: ColorModeConfig.PaletteStripRef) -> Double {
        let live = [UInt8](gray)
        let other = [UInt8](ref.gray)
        guard live.count == other.count, !live.isEmpty else { return 1.0 }
        var sum = 0
        for i in 0..<live.count {
            sum += abs(Int(live[i]) - Int(other[i]))
        }
        return Double(sum) / Double(live.count) / 255.0
    }

    // MARK: Geometry

    /// The strip rect in GLOBAL screen coordinates: bounding box of all
    /// derived tab points with padding that covers the tab chrome.
    private func stripRectGlobal() -> CGRect? {
        guard let first = tabPoints.values.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in tabPoints.values {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        // Generous chrome: each tab is wider than its label center point.
        let padX: CGFloat = 55
        let padY: CGFloat = 16
        return CGRect(x: minX - padX, y: minY - padY,
                      width: (maxX - minX) + 2 * padX,
                      height: (maxY - minY) + 2 * padY)
    }

    // MARK: Capture

    /// Captures the global rect, downscales to refW×refH grayscale.
    private func captureGray(rect: CGRect) -> Data? {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("speedcolors-palette-watch.png")
        try? FileManager.default.removeItem(at: out)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-o", "-x",
                       "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))",
                       out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: out) }
        guard p.terminationStatus == 0,
              let data = try? Data(contentsOf: out),
              let nsimg = NSImage(data: data),
              let cg = nsimg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return downscaleGray(cg)
    }

    private func downscaleGray(_ image: CGImage) -> Data {
        let w = refW, h = refH
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return Data()
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Data(pixels)
    }
}
