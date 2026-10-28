// AutoCal.swift — Color-page auto-calibration.
//
// Captures the Resolve window, OCRs it with the Vision framework, and locates
// known control labels (LIFT / GAMMA / GAIN / Curves / Blur / Key / …).
// Matched label centers become targets in ~/.speedcolors/color.json, and an
// annotated PNG (red = used, yellow = everything OCR saw) is written so you
// can verify the boxes landed on the right controls.
//
// Requires Screen Recording permission for the terminal running the command.

import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

public enum AutoCalError: Error, CustomStringConvertible {
    case noWindow
    case noImage

    public var description: String {
        switch self {
        case .noWindow: return "Resolve window not found (is Resolve open on the Color page?)"
        case .noImage: return "could not capture the Resolve window"
        }
    }
}

public struct AutoCalMatch {
    public let name: String
    public let text: String
    public let bb: CGRect  // normalized, origin bottom-left

    public init(name: String, text: String, bb: CGRect) {
        self.name = name
        self.text = text
        self.bb = bb
    }
}

public enum AutoCal {
    /// Color-page text labels we can locate by OCR. First match wins.
    /// Names are TargetCatalog ids.
    public static let wanted: [(name: String, patterns: [String])] = [
        ("wheel_1_color",     ["lift"]),
        ("wheel_2_color",     ["gamma"]),
        ("wheel_3_color",     ["gain"]),
        ("wheel_4_color",     ["offset"]),
        ("color_warper_page", ["warper"]),
        ("curves_page",       ["curves"]),
        ("blur_radius",       ["blur radius", "radius"]),
        ("key_page",          ["key"]),
        ("window_page",       ["window"]),
        ("sizing_page",       ["sizing"]),
        ("scopes",            ["scopes"]),
    ]

    // MARK: Window discovery

    public static func findResolveWindow() -> (rect: CGRect, id: CGWindowID)? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        var best: (rect: CGRect, id: CGWindowID)?
        for w in list {
            let owner = (w["kCGWindowOwnerName"] as? String ?? "").lowercased()
            let bundle = (w["kCGWindowBundleIdentifier"] as? String ?? "").lowercased()
            guard owner.contains("resolve") || bundle.contains("davinci") else { continue }
            guard let nsDict = w["kCGWindowBounds"] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: nsDict as CFDictionary) else { continue }
            guard r.width > 800, r.height > 500 else { continue }  // skip helper windows
            let area = r.width * r.height
            if best == nil || area > best!.rect.width * best!.rect.height {
                let id = (w["kCGWindowNumber"] as? NSNumber)?.uint32Value ?? 0
                best = (r, id)
            }
        }
        return best
    }

    // MARK: Capture + OCR

    public static func capture(windowID: CGWindowID) throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            print("✗ Screen Recording permission required:")
            print("   System Settings → Privacy & Security → Screen Recording")
            print("   → add & enable this terminal, then QUIT and relaunch the terminal.")
            Foundation.exit(1)
        }
        // Layer 1: the system `screencapture` tool (Apple's own, battle-tested).
        if let img = captureViaScreencaptureTool(windowID: windowID), !img.isEffectivelyBlack() {
            return img
        }
        // Layer 2: ScreenCaptureKit (modern API, macOS 14+).
        if #available(macOS 14.0, *) {
            if let img = try captureViaScreenCaptureKit(), !img.isEffectivelyBlack() {
                return img
            }
        }
        // Layer 3: legacy window capture (deprecated, often black on modern macOS).
        if let img = CGWindowListCreateImage(.null, .optionOnScreenOnly, windowID, [.bestResolution]),
           !img.isEffectivelyBlack() {
            return img
        }
        print("✗ Screen capture came back black on all three methods.")
        print("   → Check Screen Recording permission for this terminal (System Settings → Privacy & Security).")
        print("   → If it's already enabled: QUIT and relaunch the terminal, then retry.")
        Foundation.exit(1)
    }

    private static func captureViaScreencaptureTool(windowID: CGWindowID) -> CGImage? {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("speedcolors-capture-\(windowID).png")
        try? FileManager.default.removeItem(at: out)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-o", "-x", "-l\(windowID)", out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let data = try? Data(contentsOf: out),
              let nsimg = NSImage(data: data),
              let cg = nsimg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        try? FileManager.default.removeItem(at: out)
        return cg
    }

    @available(macOS 14.0, *)
    private static func captureViaScreenCaptureKit() throws -> CGImage? {
        var image: CGImage?
        var captureError: Error?
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                let win = content.windows.filter { w in
                    let bundle = w.owningApplication?.bundleIdentifier.lowercased() ?? ""
                    let name = w.owningApplication?.applicationName.lowercased() ?? ""
                    return bundle.contains("davinci") || name.contains("resolve")
                }.max {
                    $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                }
                guard let win else {
                    throw AutoCalError.noWindow
                }
                let filter = SCContentFilter(desktopIndependentWindow: win)
                let config = SCStreamConfiguration()
                config.width = Int(win.frame.width)
                config.height = Int(win.frame.height)
                config.showsCursor = false
                image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)
            } catch {
                captureError = error
            }
            sem.signal()
        }
        sem.wait()
        if let captureError {
            print("· ScreenCaptureKit fallback failed: \(captureError)")
        }
        return image
    }

    public static func recognize(_ image: CGImage) throws -> [(text: String, bb: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        var out: [(text: String, bb: CGRect)] = []
        for obs in request.results ?? [] {
            guard let top = obs.topCandidates(1).first else { continue }
            out.append((top.string, obs.boundingBox))
        }
        return out
    }

    /// Render the image at `factor`× resolution (helps Vision read tiny UI text).
    private static func upscaled(_ image: CGImage, factor: CGFloat = 2) -> CGImage {
        let w = Int(CGFloat(image.width) * factor)
        let h = Int(CGFloat(image.height) * factor)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    public static func match(_ observations: [(text: String, bb: CGRect)]) -> [AutoCalMatch] {
        var matches: [AutoCalMatch] = []
        for (name, patterns) in wanted {
            for (text, bb) in observations {
                let low = text.lowercased()
                if patterns.contains(where: { low.contains($0) }) {
                    matches.append(AutoCalMatch(name: name, text: text, bb: bb))
                    break
                }
            }
        }
        return matches
    }

    // MARK: One-shot flow

    public struct AutoCalResult {
        public let matched: [AutoCalMatch]  // includes derived targets
        public let pngURL: URL
        public let regions: Int
        public let updated: [String]
        public let kept: [String]
        public let derived: [String]
        public let observations: [(text: String, bb: CGRect)]
    }

    public static func calibrate(force: Bool = false, debug: Bool = false) throws -> AutoCalResult {
        guard let win = findResolveWindow() else { throw AutoCalError.noWindow }
        let image = try capture(windowID: win.id)
        // OCR at 1×, 2× and 3× — small UI labels read far better upscaled.
        // Bounding boxes are normalized, so scales mix freely.
        let observations = (try recognize(image))
            + (try recognize(upscaled(image)))
            + (try recognize(upscaled(image, factor: 3)))
        if debug {
            for (text, bb) in observations {
                print("  DEBUG '\(text)' @ (\(Int(bb.midX * 100))%, \(Int((1 - bb.midY) * 100))%)")
            }
        }
        let matched = match(observations)

        var cfg = ColorModeConfig.load()

        // Global label centers (top-left origin screen coords).
        var points: [String: CGPoint] = [:]
        for m in matched {
            points[m.name] = CGPoint(
                x: win.rect.origin.x + Double(m.bb.midX) * win.rect.width,
                y: win.rect.origin.y + (1 - Double(m.bb.midY)) * win.rect.height)
        }

        // Wheel labels sit ABOVE the wheels — drop onto the wheel center.
        let drop = cfg.wheelLabelDrop * win.rect.height
        for wheel in ["wheel_1_color", "wheel_2_color", "wheel_3_color", "wheel_4_color"]
        where points[wheel] != nil {
            points[wheel]!.y += drop
        }

        // The primaries wheels form a horizontal row Lift·Gamma·Gain·Offset.
        // When OCR misses a label (Lift/Gain are hard), derive from spacing:
        // Gain is the midpoint of Gamma↔Offset, Lift is one step left of Gamma.
        var derived: [String] = []
        if let g = points["wheel_2_color"], let o = points["wheel_4_color"] {
            let step = (o.x - g.x) / 2
            if points["wheel_3_color"] == nil {
                points["wheel_3_color"] = CGPoint(x: g.x + step, y: g.y)
                derived.append("wheel_3_color")
            }
            if points["wheel_1_color"] == nil {
                points["wheel_1_color"] = CGPoint(x: g.x - step, y: g.y)
                derived.append("wheel_1_color")
            }
        }

        // Synthetic boxes so derived targets appear on the annotated PNG.
        var annotatedMatches = matched
        for name in derived {
            let p = points[name]!
            let nx = (p.x - win.rect.origin.x) / win.rect.width
            let ny = 1 - (p.y - win.rect.origin.y) / win.rect.height
            annotatedMatches.append(AutoCalMatch(
                name: name, text: "(derived)",
                bb: CGRect(x: nx - 0.025, y: ny - 0.012, width: 0.05, height: 0.024)))
        }

        var updated: [String] = []
        var kept: [String] = []
        var savedTargets: [String: CGPoint] = [:]
        for (name, p) in points.sorted(by: { $0.key < $1.key }) {
            if cfg.targets[name] != nil && !force {
                kept.append(name)
                savedTargets[name] = cfg.targets[name]!.point
                continue
            }
            cfg.targets[name] = ColorTarget(x: Double(p.x), y: Double(p.y))
            updated.append(name)
            savedTargets[name] = p
        }
        try cfg.save()

        let pngURL = ColorModeConfig.defaultPath
            .deletingLastPathComponent()
            .appendingPathComponent("autocal.png")
        annotate(image: image, targets: savedTargets, win: win.rect,
                 observations: observations, saveTo: pngURL)
        return AutoCalResult(
            matched: annotatedMatches, pngURL: pngURL, regions: observations.count,
            updated: updated, kept: kept, derived: derived, observations: observations)
    }

    // MARK: Annotation

    /// Draws every SAVED target as a red dot + name (the real click positions),
    /// plus thin yellow boxes around everything OCR recognized.
    public static func annotate(image: CGImage, targets: [String: CGPoint],
                                win: CGRect, observations: [(text: String, bb: CGRect)],
                                saveTo: URL) {
        let size = NSSize(width: image.width, height: image.height)
        let img = NSImage(cgImage: image, size: size)
        img.lockFocus()

        // Everything OCR saw: thin yellow boxes.
        NSColor.systemYellow.withAlphaComponent(0.6).setStroke()
        for (_, bb) in observations {
            let r = CGRect(x: bb.origin.x * size.width, y: bb.origin.y * size.height,
                           width: bb.width * size.width, height: bb.height * size.height)
            let p = NSBezierPath(rect: r)
            p.lineWidth = 2
            p.stroke()
        }

        // Saved targets: red dot + name (AppKit coords = bottom-left origin).
        for (name, p) in targets.sorted(by: { $0.key < $1.key }) {
            let nx = (p.x - win.origin.x) / win.width
            let ny = 1 - (p.y - win.origin.y) / win.height
            let cx = nx * size.width
            let cy = ny * size.height
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: CGRect(x: cx - 9, y: cy - 9, width: 18, height: 18)).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 34),
                .foregroundColor: NSColor.systemRed,
            ]
            NSAttributedString(string: name, attributes: attrs)
                .draw(at: NSPoint(x: cx + 16, y: cy + 16))
        }

        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: saveTo)
    }
}

extension CGImage {
    /// True when the image carries (almost) no visual information — the classic
    /// symptom of a screen-capture permission/API failure on modern macOS.
    func isEffectivelyBlack() -> Bool {
        let w = 24, h = 24
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .low
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        let total = data.reduce(0) { $0 + Int($1) }
        return total < w * h * 4 * 3  // average channel below ~3/255
    }
}
