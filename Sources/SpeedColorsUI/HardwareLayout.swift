// HardwareLayout.swift — the Speed Editor replica: one fixed-proportion
// canvas (1408 × 896 design units, matching the device face) containing the
// enclosure, five recessed key wells, and the search dial. The whole replica
// is scaled uniformly to fit the available area; the app stays responsive
// around it, the hardware never stretches.
//
// Geometry is measured against the product photo (estimates — overlay-check
// before calling it pixel-accurate). Group recess bounds:
//
//   top-left edit   72,115  336×225     top-center edit 480,115 446×225
//   source/timeline 998,115 335×114     shtl/jog/scrl    998,267 335×116
//   lower-left trim 72,377  336×446     camera/playback  480,377 446×446
//   dial bounds     990,471 354×354
//
// Interaction: click SELECTS (never executes), live presses depress the key,
// dial-mode keys show an illuminated indicator when that mode is live,
// right-click copies/pastes/clears bindings, action-library drags assign.

import SwiftUI
import UniformTypeIdentifiers
import SpeedColorsCore

// MARK: - Control identity

/// What the inspector is editing. Dial-mode keys (SHTL/JOG/SCRL) are controls
/// too — same selection and editing patterns as buttons.
enum SEControl: Hashable {
    case key(SpeedEditorKey)
    case dial
}

// MARK: - Face variants

enum HWFace {
    case gray        // standard editing keys, SOURCE/TIMELINE, STOP/PLAY
    case black       // CAM 1–9
    case blackAux    // LIVE O/WR, VIDEO ONLY, AUDIO ONLY
    case ivory       // IN, OUT, SHTL, JOG, SCRL
    case red         // FULL VIEW

    var face: Color {
        switch self {
        case .gray: return HWColor.grayKey
        case .black: return HWColor.camKey
        case .blackAux: return HWColor.camAuxKey
        case .ivory: return HWColor.ivoryKey
        case .red: return HWColor.redKey
        }
    }
    var bevel: Color {
        switch self {
        case .gray: return HWColor.grayBevel
        case .black: return HWColor.camBevel
        case .blackAux: return HWColor.camAuxBevel
        case .ivory: return HWColor.ivoryBevel
        case .red: return HWColor.redBevel
        }
    }
    var label: Color {
        switch self {
        case .ivory: return HWColor.ivoryText
        default: return HWColor.darkKeyText
        }
    }
    var subLabel: Color {
        switch self {
        case .ivory: return HWColor.ivoryText.opacity(0.65)
        default: return HWColor.darkKeyText.opacity(0.5)
        }
    }
}

// MARK: - Palette

enum HWColor {
    static let enclosure      = Color(hex: 0x777676)
    static let enclosureDark  = Color(hex: 0x6E6D6D)
    static let enclosureEdge  = Color(hex: 0x454545)
    static let well           = Color(hex: 0x111212)
    static let grayKey        = Color(hex: 0x626465)
    static let grayBevel      = Color(hex: 0x4B4D4E)
    static let camKey         = Color(hex: 0x343638)
    static let camBevel       = Color(hex: 0x242628)
    static let camAuxKey      = Color(hex: 0x474A4D)
    static let camAuxBevel    = Color(hex: 0x313436)
    static let ivoryKey       = Color(hex: 0xD8D6D3)
    static let ivoryBevel     = Color(hex: 0xB3B1AE)
    static let redKey         = Color(hex: 0x783C42)
    static let redBevel       = Color(hex: 0x502A2E)
    static let ivoryText      = Color(hex: 0x555657)
    static let darkKeyText    = Color(hex: 0xE5E5E3)
    static let dialDisk       = Color(hex: 0x303133)
    static let dialRim        = Color(hex: 0x17191A)
    static let activeRed      = Color(hex: 0xE15A64)
    static let selection      = Color(hex: 0x3D8BFF)
    static let brandText      = Color(hex: 0x4B4C4E)
    static let brandTextLight = Color(hex: 0x6D6E70)
    static let brandOrange    = Color(hex: 0xE8A33D)
}

// MARK: - Canvas definition

struct HWKeyDef: Identifiable {
    let key: SpeedEditorKey
    let lines: [String]
    let sub: String?
    let face: HWFace
    let rect: CGRect
    var id: String { key.id }
    var modeKey: Bool { key == .shtl || key == .jog || key == .scrl }
}

enum HWCanvas {
    static let width: CGFloat = 1408
    static let height: CGFloat = 896

    static let topLeftGroup    = CGRect(x: 72, y: 115, width: 336, height: 225)
    static let topCenterGroup  = CGRect(x: 480, y: 115, width: 446, height: 225)
    static let sourceGroup     = CGRect(x: 998, y: 115, width: 335, height: 114)
    static let modeGroup       = CGRect(x: 998, y: 267, width: 335, height: 116)
    static let lowerLeftGroup  = CGRect(x: 72, y: 377, width: 336, height: 446)
    static let cameraGroup     = CGRect(x: 480, y: 377, width: 446, height: 446)
    static let dialBounds      = CGRect(x: 990, y: 471, width: 354, height: 354)

    static let groups: [(CGRect)] = [
        topLeftGroup, topCenterGroup, sourceGroup, modeGroup, lowerLeftGroup, cameraGroup,
    ]

    /// Inner padding of each recessed well; gutter between keys.
    static let wellPad: CGFloat = 14
    static let gutter: CGFloat = 12

    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    // Well-local slot math
    private static var p: CGFloat { wellPad }
    private static var g: CGFloat { gutter }

    static let keys: [HWKeyDef] = {
        var out: [HWKeyDef] = []
        func add(_ key: SpeedEditorKey, _ lines: [String], sub: String? = nil,
                 _ face: HWFace, _ r: CGRect) {
            out.append(HWKeyDef(key: key, lines: lines, sub: sub, face: face, rect: r))
        }

        // Top-left: 3 cols × 2 rows
        do {
            let g0 = topLeftGroup
            let kw = (g0.width - 2 * p - 2 * g) / 3            // 94.67
            let kh = (g0.height - 2 * p - g) / 2               // 92.5
            let xs = (0..<3).map { g0.minX + p + CGFloat($0) * (kw + g) }
            let ys = [g0.minY + p, g0.minY + p + kh + g]
            add(.smartInsrt,  ["SMART", "INSRT"], sub: "CLIP",  .gray, rect(xs[0], ys[0], kw, kh))
            add(.appnd,       ["APPND"],          sub: "CLIP",  .gray, rect(xs[1], ys[0], kw, kh))
            add(.riplOwr,     ["RIPL", "O/WR"],   sub: nil,     .gray, rect(xs[2], ys[0], kw, kh))
            add(.closeUp,     ["CLOSE", "UP"],    sub: "YPOS",  .gray, rect(xs[0], ys[1], kw, kh))
            add(.placeOnTop,  ["PLACE", "ON TOP"], sub: nil,    .gray, rect(xs[1], ys[1], kw, kh))
            add(.srcOwr,      ["SRC", "O/WR"],    sub: nil,     .gray, rect(xs[2], ys[1], kw, kh))
        }

        // Top-center: 4 cols × 2 rows
        do {
            let g0 = topCenterGroup
            let kw = (g0.width - 2 * p - 3 * g) / 4            // 95.5
            let kh = (g0.height - 2 * p - g) / 2               // 92.5
            let xs = (0..<4).map { g0.minX + p + CGFloat($0) * (kw + g) }
            let ys = [g0.minY + p, g0.minY + p + kh + g]
            add(.esc,        ["ESC"],         sub: "UNDO",  .gray, rect(xs[0], ys[0], kw, kh))
            add(.syncBin,    ["SYNC", "BIN"], sub: nil,     .gray, rect(xs[1], ys[0], kw, kh))
            add(.audioLevel, ["AUDIO", "LEVEL"], sub: "MARK", .gray, rect(xs[2], ys[0], kw, kh))
            add(.fullView,   ["FULL", "VIEW"], sub: "RVV",  .red,  rect(xs[3], ys[0], kw, kh))
            add(.trans,      ["TRANS"],       sub: "TITLE", .gray, rect(xs[0], ys[1], kw, kh))
            add(.split,      ["SPLIT"],       sub: "MOVE",  .gray, rect(xs[1], ys[1], kw, kh))
            add(.snap,       ["SNAP"],        sub: nil,     .gray, rect(xs[2], ys[1], kw, kh))
            add(.riplDel,    ["RIPL", "DEL"], sub: nil,     .gray, rect(xs[3], ys[1], kw, kh))
        }

        // SOURCE / TIMELINE
        do {
            let g0 = sourceGroup
            let kw = (g0.width - 2 * p - g) / 2                // 147.5
            let kh = g0.height - 2 * p                         // 86
            add(.source,   ["SOURCE"],   sub: nil, .gray, rect(g0.minX + p, g0.minY + p, kw, kh))
            add(.timeline, ["TIMELINE"], sub: nil, .gray, rect(g0.minX + p + kw + g, g0.minY + p, kw, kh))
        }

        // SHTL / JOG / SCRL (ivory mode keys with indicator slots)
        do {
            let g0 = modeGroup
            let kw = (g0.width - 2 * p - 2 * g) / 3            // 94.33
            let kh = g0.height - 2 * p                         // 88
            let xs = (0..<3).map { g0.minX + p + CGFloat($0) * (kw + g) }
            add(.shtl, ["SHTL"], sub: nil, .ivory, rect(xs[0], g0.minY + p, kw, kh))
            add(.jog,  ["JOG"],  sub: nil, .ivory, rect(xs[1], g0.minY + p, kw, kh))
            add(.scrl, ["SCRL"], sub: nil, .ivory, rect(xs[2], g0.minY + p, kw, kh))
        }

        // Lower-left: 6 internal columns — IN/OUT span 3, small keys span 2.
        // Rows: IN/OUT, TRIM/ROLL, SLIP/TRANS DUR, CUT/DIS/SMTH CUT.
        do {
            let g0 = lowerLeftGroup
            let w6 = (g0.width - 2 * p - 5 * g) / 6            // 41.33
            let kh = (g0.height - 2 * p - 3 * g) / 4           // 95.5
            let x6 = { (col: Int) in g0.minX + p + CGFloat(col) * (w6 + g) }  // left of col
            let ys = (0..<4).map { g0.minY + p + CGFloat($0) * (kh + g) }
            add(.markIn,  ["IN"],  sub: "CLR", .ivory, rect(x6(0), ys[0], w6 * 3 + 2 * g, kh))
            add(.markOut, ["OUT"], sub: "CLR", .ivory, rect(x6(3), ys[0], w6 * 3 + 2 * g, kh))
            add(.trimIn,  ["TRIM", "IN"],   sub: nil, .gray, rect(x6(0), ys[1], w6 * 2 + g, kh))
            add(.trimOut, ["TRIM", "OUT"],  sub: nil, .gray, rect(x6(2), ys[1], w6 * 2 + g, kh))
            add(.roll,    ["ROLL"],         sub: "SLIDE", .gray, rect(x6(4), ys[1], w6 * 2 + g, kh))
            add(.slipSrc, ["SLIP", "SRC"],  sub: nil, .gray, rect(x6(0), ys[2], w6 * 2 + g, kh))
            add(.slipDest, ["SLIP", "DEST"], sub: nil, .gray, rect(x6(2), ys[2], w6 * 2 + g, kh))
            add(.transDur, ["TRANS", "DUR"], sub: "SET", .gray, rect(x6(4), ys[2], w6 * 2 + g, kh))
            add(.cut,     ["CUT"],  sub: nil, .gray, rect(x6(0), ys[3], w6 * 2 + g, kh))
            add(.dis,     ["DIS"],  sub: nil, .gray, rect(x6(2), ys[3], w6 * 2 + g, kh))
            add(.smthCut, ["SMTH", "CUT"], sub: nil, .gray, rect(x6(4), ys[3], w6 * 2 + g, kh))
        }

        // Camera / playback: 4 cols × 3 rows + STOP/PLAY spanning the well.
        do {
            let g0 = cameraGroup
            let kw = (g0.width - 2 * p - 3 * g) / 4            // 95.5
            let stopH: CGFloat = 70
            let kh = (g0.height - 2 * p - g - stopH - 2 * g) / 3   // ≈ 104
            let xs = (0..<4).map { g0.minX + p + CGFloat($0) * (kw + g) }
            let ys = (0..<3).map { g0.minY + p + CGFloat($0) * (kh + g) }
            add(.cam7,      ["CAM", "7"],  sub: nil, .black, rect(xs[0], ys[0], kw, kh))
            add(.cam8,      ["CAM", "8"],  sub: nil, .black, rect(xs[1], ys[0], kw, kh))
            add(.cam9,      ["CAM", "9"],  sub: nil, .black, rect(xs[2], ys[0], kw, kh))
            add(.liveOwr,   ["LIVE", "O/WR"], sub: "RND", .blackAux, rect(xs[3], ys[0], kw, kh))
            add(.cam4,      ["CAM", "4"],  sub: nil, .black, rect(xs[0], ys[1], kw, kh))
            add(.cam5,      ["CAM", "5"],  sub: nil, .black, rect(xs[1], ys[1], kw, kh))
            add(.cam6,      ["CAM", "6"],  sub: nil, .black, rect(xs[2], ys[1], kw, kh))
            add(.videoOnly, ["VIDEO", "ONLY"], sub: nil, .blackAux, rect(xs[3], ys[1], kw, kh))
            add(.cam1,      ["CAM", "1"],  sub: nil, .black, rect(xs[0], ys[2], kw, kh))
            add(.cam2,      ["CAM", "2"],  sub: nil, .black, rect(xs[1], ys[2], kw, kh))
            add(.cam3,      ["CAM", "3"],  sub: nil, .black, rect(xs[2], ys[2], kw, kh))
            add(.audioOnly, ["AUDIO", "ONLY"], sub: nil, .blackAux, rect(xs[3], ys[2], kw, kh))
            add(.stopPlay, ["STOP/PLAY"], sub: nil, .gray,
                rect(g0.minX + p, ys[2] + kh + g, g0.width - 2 * p, stopH))
        }

        return out
    }()
}

// MARK: - Device canvas (uniformly scaled)

struct DeviceCanvasView: View {
    @EnvironmentObject var controller: DaemonController
    let scale: CGFloat

    /// Key currently under an in-flight drop (for the target ring).
    @State private var hoverKey: String?

    var body: some View {
        body0
            .frame(width: HWCanvas.width, height: HWCanvas.height)
            .scaleEffect(scale, anchor: .center)
            .frame(width: HWCanvas.width * scale, height: HWCanvas.height * scale)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: 0x0c0d0e))
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            )
            // Canvas-level drop router. The per-key onDrop inside the
            // .scaleEffect transform doesn't get AppKit drag-session hit
            // testing reliably, so drops are resolved HERE in unscaled
            // outer-frame coordinates and mapped back to hardware space.
            .onDrop(of: [UTType.plainText],
                    delegate: CanvasDropDelegate(
                        scaledW: HWCanvas.width * scale,
                        scaledH: HWCanvas.height * scale,
                        scale: scale,
                        hoverKey: $hoverKey) { keyId, provider in
                            guard !keyIsDialMode(keyId) else { return false }
                            let defaultTarget = controller.config.targets.keys.sorted().first
                            return ActionDrop.step(from: provider,
                                                   defaultTarget: defaultTarget) { step in
                                guard let step else { return }
                                controller.appendDroppedAction(toKeyId: keyId, step)
                            }
                        })
    }

    private func keyIsDialMode(_ keyId: String) -> Bool {
        HWCanvas.keys.first { $0.key.id == keyId }?.modeKey ?? false
    }

    private var body0: some View {
        ZStack {
            // Enclosure
            RoundedRectangle(cornerRadius: 48)
                .fill(LinearGradient(colors: [HWColor.enclosure, HWColor.enclosureDark],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 48)
                    .stroke(HWColor.enclosureEdge, lineWidth: 3))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                .frame(width: HWCanvas.width - 24, height: HWCanvas.height - 24)
                .position(x: HWCanvas.width / 2, y: HWCanvas.height / 2)

            branding

            // Recessed wells
            ForEach(Array(HWCanvas.groups.enumerated()), id: \.offset) { _, r in
                RoundedRectangle(cornerRadius: 14)
                    .fill(HWColor.well)
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.black.opacity(0.65), lineWidth: 2))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }

            // Keys
            ForEach(HWCanvas.keys) { def in
                DeviceKeyView(def: def, scale: scale,
                              dropHighlight: hoverKey == def.key.id)
                    .position(x: def.rect.midX, y: def.rect.midY)
            }

            SearchDialView(bounds: HWCanvas.dialBounds)
                .position(x: HWCanvas.dialBounds.midX, y: HWCanvas.dialBounds.midY)
        }
    }

    private var branding: some View {
        ZStack {
            HStack(spacing: 6) {
                Text("DAVINCI RESOLVE")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(HWColor.brandText)
                Text("SPEED EDITOR")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(HWColor.brandTextLight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 30)

            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(HWColor.brandOrange, lineWidth: 2)
                        .frame(width: 10, height: 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 30)
        }
        .position(x: HWCanvas.width / 2, y: 62)
    }
}

// MARK: - Canvas drop router

/// Resolves drops on the unscaled outer canvas frame: maps the drop point back
/// into hardware coordinates and finds the key underneath. Works regardless of
/// the .scaleEffect transform, since AppKit's drag hit-testing doesn't follow
/// SwiftUI visual transforms.
private struct CanvasDropDelegate: DropDelegate {
    let scaledW: CGFloat
    let scaledH: CGFloat
    let scale: CGFloat
    @Binding var hoverKey: String?
    let onDropAt: (_ keyId: String, _ provider: NSItemProvider) -> Bool

    func dropUpdated(info: DropInfo) -> DropProposal? {
        hoverKey = key(at: info.location)
        return DropProposal(operation: .copy)
    }

    func dropEntered(info: DropInfo) {
        hoverKey = key(at: info.location)
    }

    func dropExited(info: DropInfo) {
        hoverKey = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { hoverKey = nil }
        guard let keyId = key(at: info.location),
              let provider = info.itemProviders(for: [UTType.plainText]).first
        else { return false }
        return onDropAt(keyId, provider)
    }

    /// Hardware-space content point for a drop location (in the scaled frame),
    /// mapped back through the centered uniform scale.
    private func contentPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: (p.x - scaledW / 2) / scale + HWCanvas.width / 2,
            y: (p.y - scaledH / 2) / scale + HWCanvas.height / 2)
    }

    private func key(at p: CGPoint) -> String? {
        let hw = contentPoint(p)
        // Small tolerance so dropping between adjacent keys lands on the
        // nearer one.
        let tol: CGFloat = 3
        for def in HWCanvas.keys where !def.modeKey {
            let r = def.rect.insetBy(dx: -tol, dy: -tol)
            if r.contains(hw) { return def.key.id }
        }
        return nil
    }
}

// MARK: - Key rendering

private extension String {
    /// Loosely compares a main label with the hardware identity (case/space
    /// insensitive) so redundant corner tags are suppressed.
    func equalsIgnoringHW(_ other: String) -> Bool {
        compactHW() == other.compactHW()
    }
    func compactHW() -> String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

struct DeviceKeyView: View {
    @EnvironmentObject var controller: DaemonController
    let def: HWKeyDef
    /// Canvas display scale (HW units → screen px) — labels compensate their
    /// point size so text hits a target size ON SCREEN.
    let scale: CGFloat
    /// True while a drag from the action library hovers over this key.
    var dropHighlight: Bool = false

    /// HW-units font size whose on-screen size is `target` px. Capped so an
    /// extremely small pane doesn't explode fonts beyond the key.
    private func screenFont(_ target: CGFloat) -> CGFloat {
        min(target / max(scale, 0.12), 30)
    }

    @State private var hovered = false

    private var pressed: Bool { controller.pressedKeys.contains(def.key.id) }
    private var selected: Bool { controller.selectedControl == .key(def.key) }
    private var bound: Bool {
        !(controller.config.bindings[def.key.id] ?? []).isEmpty
            || !(controller.config.released[def.key.id] ?? []).isEmpty
    }
    private var disabledBinding: Bool { controller.config.disabledBindings.contains(def.key.id) }
    private var bindingName: String? { controller.bindingName(for: def.key.id) }
    /// "Show binding name on key": face legend follows the binding name.
    private var labelFromBinding: Bool {
        controller.config.labelFromBinding[def.key.id] ?? false
    }
    private var isLiveMode: Bool {
        def.modeKey && controller.deviceConnected
            && controller.dialState.uppercased().hasPrefix(def.key.label.uppercased())
    }

    // Pressed keys brighten and their face shifts down into the shell.
    private var faceColor: Color {
        var c = def.face.face
        if pressed { c = c.blend(white: 0.16) }
        else if hovered && !selected { c = c.blend(white: 0.05) }
        return c
    }

    /// Mapping is the only face style now: almost no simulated bevel edge and
    /// a lighter shadow, buying usable label space.
    private var faceInset: CGFloat { def.rect.width * 0.045 }
    private var faceShadowOpacity: Double { 0.25 }
    private var faceDrop: CGFloat { pressed ? 1.5 : 0 }

    var body: some View {
        ZStack {
            // 1 · Base shadow
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(pressed ? 0.15 : faceShadowOpacity))
                .offset(y: pressed ? 1.5 : 2)
                .frame(width: def.rect.width, height: def.rect.height)

            // 2 · Beveled shell
            RoundedRectangle(cornerRadius: 9)
                .fill(def.face.bevel)
                .frame(width: def.rect.width, height: def.rect.height)

            // 3 · Top face
            RoundedRectangle(cornerRadius: 5)
                .fill(faceColor)
                .frame(width: def.rect.width - 2 * faceInset,
                       height: def.rect.height - 2 * faceInset)
                .offset(y: faceDrop)

            // Legends
            legends
                .offset(y: faceDrop + (pressed ? 1 : 0))
                .allowsHitTesting(false)

            // Mode-key indicator slot (illuminates for the live dial mode)
            if def.modeKey {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(isLiveMode ? HWColor.activeRed : Color.black.opacity(0.55))
                    .frame(width: def.rect.width * 0.3, height: 6)
                    .position(x: def.rect.width / 2, y: def.rect.height * 0.18)
                    .allowsHitTesting(false)
            }

            // Selected-for-editing outline: outside the key, never recolored.
            if selected {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(HWColor.selection, lineWidth: 3)
                    .frame(width: def.rect.width + 8, height: def.rect.height + 8)
            }

            // Drop-target ring while a library action hovers over this key.
            if dropHighlight {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                    .foregroundColor(HWColor.brandOrange)
                    .frame(width: def.rect.width + 8, height: def.rect.height + 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(HWColor.selection.opacity(0.14))
                    )
            }
        }
        .frame(width: def.rect.width, height: def.rect.height)
        // Assigned-binding badge (outside the legend area)
        .overlay(alignment: .topTrailing) {
            if bound {
                Circle()
                    .fill(disabledBinding ? HWColor.enclosureEdge : Graphite.blue)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                    .offset(x: -6, y: 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { controller.selectedControl = .key(def.key) }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Copy Binding") { controller.copyBinding(forKeyId: def.key.id) }
                .disabled(!bound)
            Button("Paste Binding") { controller.pasteBinding(toKeyId: def.key.id) }
                .disabled(controller.clipboard == nil)
            Divider()
            Button("Clear Binding", role: .destructive) { controller.clearBinding(forKeyId: def.key.id) }
                .disabled(!bound)
        }
        // NOTE: drop targeting lives in the canvas-level CanvasDropDelegate
        // (DeviceCanvasView) — per-key onDrop under the scale transform is
        // unreliable and could mis-resolve the intended key.
        .help(helpText)
    }

    // MARK: Legends

    @ViewBuilder private var legends: some View {
        ZStack {
            mainLegends
                .offset(y: faceDrop + (pressed ? 1 : 0))
                .allowsHitTesting(false)
            subLegend
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, def.rect.height * 0.07)
                .offset(y: faceDrop)
                .allowsHitTesting(false)
        }
        .frame(width: def.rect.width, height: def.rect.height)
    }

    @ViewBuilder private var mainLegends: some View {
        // ONE readable main label per key, in screen-space px. No "unassigned",
        // no action counts, no printed lines — those live in the tooltip and
        // inspector. Hardware identity goes to a small corner tag only when it
        // differs from the main label.
        let main = bindingName ?? customLabel
        let hwIdentity = def.key.label
        ZStack(alignment: .topLeading) {
            VStack(spacing: screenFont(2)) {
                Text(main ?? hwIdentity)
                    .font(.system(size: screenFont(13), weight: .semibold))
                    .foregroundColor(def.face.label)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                // Dial-mode keys: sensitivity stays as a small indicator, in
                // the accent (cyan) — never as main-label styling.
                if def.modeKey {
                    Text(sensShort)
                        .font(.system(size: screenFont(9), weight: .medium))
                        .foregroundColor(HWColor.selection)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 2)

            if let m = main, !m.equalsIgnoringHW(hwIdentity) {
                Text(hwIdentity)
                    .font(.system(size: screenFont(8), weight: .semibold).monospaced())
                    .foregroundColor(def.face.subLabel)
                    .lineLimit(1)
                    .padding(2)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
        }
    }

    private var subLegend: some View {
        Group {
            if let sub = def.sub {
                Text(sub)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(def.face.subLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    /// User-set face label for this key (config · keyLabels).
    private var customLabel: String? {
        let s = controller.config.keyLabels[def.key.id] ?? ""
        return s.isEmpty ? nil : s
    }

    private var helpText: String {
        let name = customLabel ?? def.key.label
        if disabledBinding { return "\(name) — binding disabled" }

        var lines: [String]
        if bindingName != nil {
            lines = ["\(def.key.label) — \(bindingName!)"]
        } else if bound {
            lines = ["\(def.key.label) — \(bindingName ?? "\(stepCount) actions")"]
        } else {
            lines = [def.modeKey ? "\(def.key.label) — dial mode selector"
                                  : "\(def.key.label) — unassigned"]
        }
        if !def.modeKey {
            let pressed = (controller.config.bindings[def.key.id] ?? []).count
            let released = (controller.config.released[def.key.id] ?? []).count
            if bound {
                var detail = "When pressed: \(pressed) action\(pressed == 1 ? "" : "s")"
                if released > 0 {
                    detail += " · On release: \(released)"
                }
                lines.append(detail)
                // Warn about uncalibrated targets referenced by the steps.
                let steps = (controller.config.bindings[def.key.id] ?? [])
                    + (controller.config.released[def.key.id] ?? [])
                let missing = Set(steps.compactMap(\.target))
                    .subtracting(controller.config.targets.keys).sorted()
                for m in missing {
                    lines.append("⚠ '\(m)' not calibrated")
                }
                if let first = steps.compactMap(\.target).first,
                   let t = controller.config.targets[first] {
                    lines.append(String(format: "Target: (%.0f, %.0f)", t.point.x, t.point.y))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private var stepCount: Int {
        (controller.config.bindings[def.key.id] ?? []).count
            + (controller.config.released[def.key.id] ?? []).count
    }

    private var sensShort: String {
        if let v = controller.config.dialSensitivity[def.key.id] { return "×\(v)" }
        let defaults = ["jog": 1, "shtl": 4, "scrl": 8]
        return "×\(defaults[def.key.id] ?? 1) def"
    }
}

// Small helper so `hwLines(...)` compiles cleanly in legends above.
@ViewBuilder
private func hwLines(_ lines: [String], size: CGFloat, color: Color) -> some View {
    VStack(spacing: 1) {
        ForEach(lines, id: \.self) { l in
            Text(l).font(.system(size: size, weight: .medium)).foregroundColor(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

extension Color {
    /// Blend toward white (or away for negative).
    func blend(white amount: CGFloat) -> Color {
        let ui = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.gray
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: Double(min(1, r + amount)),
                     green: Double(min(1, g + amount)),
                     blue: Double(min(1, b + amount)))
    }
}

// MARK: - Search dial

struct SearchDialView: View {
    @EnvironmentObject var controller: DaemonController
    let bounds: CGRect

    @State private var hovered = false
    @State private var notchAngle: Double = 24

    private var selected: Bool { controller.selectedControl == .dial }
    private var dragging: Bool {
        controller.deviceConnected && controller.dialState.lowercased().contains("dragging")
    }

    var body: some View {
        let d = bounds.width
        ZStack {
            // Outer shadow ring + raised rim
            Circle()
                .fill(Color.black.opacity(0.5))
                .frame(width: d, height: d)
                .offset(y: 2.5)
            Circle()
                .fill(HWColor.dialRim)
                .frame(width: d - 8, height: d - 8)
            // Concentric rings
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 2)
                .frame(width: d - 26, height: d - 26)
            // Center disk (subtly shaded, unlabelled)
            Circle()
                .fill(RadialGradient(colors: [HWColor.dialDisk,
                                              HWColor.dialDisk.blend(white: -0.12)],
                                     center: .topLeading, startRadius: 2, endRadius: d))
                .frame(width: d - 46, height: d - 46)
                .rotationEffect(.degrees(notchAngle))
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                        .frame(width: d - 46, height: d - 46)
                )
                .overlay(alignment: .bottomTrailing) {
                    // Finger indentation
                    Circle()
                        .fill(Color.black.opacity(0.30))
                        .frame(width: d * 0.19, height: d * 0.19)
                        .blur(radius: d * 0.02)
                        .offset(x: -d * 0.06, y: -d * 0.06)
                }
            // Live-drag rotation notch
            Circle()
                .fill(dragging ? HWColor.activeRed : Color.white.opacity(0.12))
                .frame(width: 12, height: 12)
                .offset(x: 0, y: -(d - 46) / 2 - 3)
                .rotationEffect(.degrees(notchAngle))
        }
        .frame(width: d, height: d)
        .overlay(Circle().stroke(selected ? HWColor.selection : Color.clear,
                                 lineWidth: 3).frame(width: d + 8, height: d + 8))
        .contentShape(Circle())
        .onTapGesture { controller.selectedControl = .dial }
        .onHover { hovered = $0 }
        .onChange(of: controller.dialState) { _ in
            guard dragging else { return }
            notchAngle += 14
        }
        .help("Search dial — click to configure drag settings")
    }
}
