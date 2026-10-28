// HardwareLayout.swift — the Speed Editor rendered in graphite: real physical
// arrangement, single-click SELECTS a control (never executes), live hardware
// presses light up distinctly, right-click copies/pastes/clears bindings, and
// action-library drags can be dropped onto any control to assign a binding.

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

// MARK: - Layout

struct HardwareLayout: View {
    @EnvironmentObject var controller: DaemonController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1 · Top: 3-wide edit block | 4-wide block (the 4-wide sits exactly
            //     above the CAM block, same as the hardware)
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        HWKey(key: .smartInsrt, lines: ["SMART", "INSRT"])
                        HWKey(key: .appnd, lines: ["APPND"])
                        HWKey(key: .riplOwr, lines: ["RIPL", "O/WR"])
                    }
                    HStack(spacing: 6) {
                        HWKey(key: .closeUp, lines: ["CLOSE", "UP"])
                        HWKey(key: .placeOnTop, lines: ["PLACE", "ON TOP"])
                        HWKey(key: .srcOwr, lines: ["SRC", "O/WR"])
                    }
                }
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        HWKey(key: .esc, lines: ["ESC"])
                        HWKey(key: .syncBin, lines: ["SYNC", "BIN"])
                        HWKey(key: .audioLevel, lines: ["AUDIO", "LEVEL"])
                        HWKey(key: .fullView, lines: ["FULL", "VIEW"])
                    }
                    HStack(spacing: 6) {
                        HWKey(key: .trans, lines: ["TRANS"])
                        HWKey(key: .split, lines: ["SPLIT"])
                        HWKey(key: .snap, lines: ["SNAP"])
                        HWKey(key: .riplDel, lines: ["RIPL", "DEL"])
                    }
                }
            }
            // 2 · IN OUT (left, spans the trim block) ··· SOURCE TIMELINE (right,
            //     above the jog cluster)
            HStack(spacing: 6) {
                HWKey(key: .markIn, lines: ["IN"], width: 114)
                HWKey(key: .markOut, lines: ["OUT"], width: 114)
                Spacer()
                HWKey(key: .source, lines: ["SOURCE"], width: 96)
                HWKey(key: .timeline, lines: ["TIMELINE"], width: 96)
            }
            // 3 · Trim block | CAM block (LIVE/VIDEO/AUDIO on the right) | jog cluster
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        HWKey(key: .trimIn, lines: ["TRIM", "IN"])
                        HWKey(key: .trimOut, lines: ["TRIM", "OUT"])
                        HWKey(key: .roll, lines: ["ROLL"])
                    }
                    HStack(spacing: 6) {
                        HWKey(key: .slipSrc, lines: ["SLIP", "SRC"])
                        HWKey(key: .slipDest, lines: ["SLIP", "DEST"])
                        HWKey(key: .transDur, lines: ["TRANS", "DUR"])
                    }
                    HStack(spacing: 6) {
                        HWKey(key: .cut, lines: ["CUT"])
                        HWKey(key: .dis, lines: ["DIS"])
                        HWKey(key: .smthCut, lines: ["SMTH", "CUT"])
                    }
                }
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        HWKey(key: .cam7, lines: ["CAM 7"])
                        HWKey(key: .cam8, lines: ["CAM 8"])
                        HWKey(key: .cam9, lines: ["CAM 9"])
                        HWKey(key: .liveOwr, lines: ["LIVE", "O/WR"])
                    }
                    HStack(spacing: 6) {
                        HWKey(key: .cam4, lines: ["CAM 4"])
                        HWKey(key: .cam5, lines: ["CAM 5"])
                        HWKey(key: .cam6, lines: ["CAM 6"])
                        HWKey(key: .videoOnly, lines: ["VIDEO", "ONLY"])
                    }
                    HStack(spacing: 6) {
                        HWKey(key: .cam1, lines: ["CAM 1"])
                        HWKey(key: .cam2, lines: ["CAM 2"])
                        HWKey(key: .cam3, lines: ["CAM 3"])
                        HWKey(key: .audioOnly, lines: ["AUDIO", "ONLY"])
                    }
                }
                Spacer()
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        HWKey(key: .shtl, lines: ["SHTL"], width: 62)
                        HWKey(key: .jog, lines: ["JOG"], width: 62)
                        HWKey(key: .scrl, lines: ["SCRL"], width: 62)
                    }
                    DialControl()
                }
            }
            // 4 · STOP/PLAY centered under the CAM block
            HStack {
                Spacer()
                HWKey(key: .stopPlay, lines: ["STOP/PLAY"], width: 190)
                Spacer()
            }
        }
        .padding(16)
    }
}

// MARK: - Key control

struct HWKey: View {
    @EnvironmentObject var controller: DaemonController
    let key: SpeedEditorKey
    let lines: [String]
    var width: CGFloat = 74

    @State private var hovered = false

    private var pressed: Bool { controller.pressedKeys.contains(key.id) }
    private var selected: Bool { controller.selectedControl == .key(key) }
    private var bound: Bool {
        !(controller.config.bindings[key.id] ?? []).isEmpty
            || !(controller.config.released[key.id] ?? []).isEmpty
    }
    private var name: String? {
        guard bound else { return nil }
        return controller.bindingName(for: key.id)
    }
    private var disabledBinding: Bool { controller.config.disabledBindings.contains(key.id) }

    private var isDialModeKey: Bool { key == .shtl || key == .jog || key == .scrl }

    var body: some View {
        VStack(spacing: 1) {
            ForEach(lines, id: \.self) { l in
                Text(l)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if isDialModeKey {
                // Dial-mode keys show the active sensitivity instead of a binding.
                Text(sensLabel)
                    .font(.system(size: 8.5).monospaced())
                    .foregroundColor(Graphite.cyan.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else if let name {
                Text(name)
                    .font(.system(size: 8.5).monospaced())
                    .foregroundColor(Graphite.cyan.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else if bound {
                Text("\(stepCount) steps")
                    .font(.system(size: 8.5).monospaced())
                    .foregroundColor(Graphite.cyan.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Text("—").font(.system(size: 8.5)).foregroundColor(Graphite.text3.opacity(0.5))
            }
        }
        .frame(width: width, height: 42)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(borderColor, lineWidth: selected ? 2 : (pressed || hovered ? 1.5 : 1))
        )
        .overlay(alignment: .topLeading) {
            if bound {
                Circle()
                    .fill(disabledBinding ? Graphite.text3 : Graphite.blue)
                    .frame(width: 5, height: 5)
                    .padding(4)
            }
        }
        .cornerRadius(5)
        .contentShape(Rectangle())
        .onTapGesture { controller.selectedControl = .key(key) }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Copy Binding") { controller.copyBinding(forKeyId: key.id) }
                .disabled(!bound)
            Button("Paste Binding") { controller.pasteBinding(toKeyId: key.id) }
                .disabled(controller.clipboard == nil)
            Divider()
            Button("Clear Binding", role: .destructive) { controller.clearBinding(forKeyId: key.id) }
                .disabled(!bound)
        }
        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
            guard !isDialModeKey else { return false }
            let defaultTarget = controller.config.targets.keys.sorted().first
            return ActionDrop.step(from: providers.first ?? NSItemProvider(),
                                   defaultTarget: defaultTarget) { step in
                guard let step else { return }
                controller.appendDroppedAction(toKeyId: key.id, step)
            }
        }
        .help(bound ? (disabledBinding ? "\(key.label) — binding disabled" : "\(key.label) — \(name ?? "bound")")
                    : (isDialModeKey ? "\(key.label) — dial mode selector" : "\(key.label) — unassigned"))
    }

    private var textColor: Color {
        pressed ? Graphite.text : (selected ? Graphite.text : Graphite.text2)
    }

    private var background: Color {
        if pressed { return Graphite.hover }                    // live hardware input
        if selected { return Graphite.hover.opacity(0.65) }     // selection
        if hovered { return Graphite.hover.opacity(0.5) }
        return Graphite.control
    }

    private var borderColor: Color {
        if selected { return Graphite.blue }
        if pressed { return Graphite.blue.opacity(0.55) }       // distinct from selection
        return Graphite.border
    }

    private var stepCount: Int {
        (controller.config.bindings[key.id] ?? []).count
            + (controller.config.released[key.id] ?? []).count
    }

    private var sensLabel: String {
        let modeId = key.id
        if let v = controller.config.dialSensitivity[modeId] {
            return "×\(v)"
        }
        let defaults = ["jog": 1, "shtl": 4, "scrl": 8]
        return "×\(defaults[modeId] ?? 1) default"
    }
}

// MARK: - Dial control

struct DialControl: View {
    @EnvironmentObject var controller: DaemonController
    @State private var hovered = false

    private var selected: Bool { controller.selectedControl == .dial }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(selected ? Graphite.blue : (hovered ? Graphite.hover : Graphite.border),
                            lineWidth: selected ? 3 : 2)
                    .frame(width: 104, height: 104)
                Circle().fill(Graphite.control).frame(width: 92, height: 92)
                VStack(spacing: 2) {
                    Text("SEARCH").font(.system(size: 10, weight: .medium)).foregroundColor(Graphite.text2)
                    Text("DIAL").font(.system(size: 10, weight: .medium)).foregroundColor(Graphite.text2)
                }
            }
            .contentShape(Circle())
            .onTapGesture { controller.selectedControl = .dial }
            .onHover { hovered = $0 }
            .help("Search dial — click to configure drag settings")

            // Runtime state line (JOG · Target: Wheel 1 — Lift).
            Text(controller.dialState)
                .font(.system(size: 9).monospaced())
                .foregroundColor(controller.dialState.contains("dragging") ? Graphite.amber : Graphite.text3)
                .lineLimit(1)
                .frame(maxWidth: 150)
        }
    }
}
