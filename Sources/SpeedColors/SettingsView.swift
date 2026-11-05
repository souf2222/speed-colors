// SettingsView.swift — global preferences, device options, permissions, and
// daemon controls. Profile-specific dial settings live on the profile/controls,
// not here.

import AppKit
import SwiftUI
import SpeedColorsCore

struct SettingsView: View {
    @EnvironmentObject var controller: DaemonController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                deviceAndDaemon
                Divider().overlay(Graphite.border)
                panelLights
                Divider().overlay(Graphite.border)
                globalDefaults
                Divider().overlay(Graphite.border)
                permissions
                Divider().overlay(Graphite.border)
                advanced
            }
            .padding(18)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    // MARK: Panel lights (custom tracking)

    private var panelLights: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Panel lights")
            Text("Layers, bottom to top: SNAP marks the Color page · palette keys light while their palette is open · \"Turn on / off / toggle light\" actions set lights manually · indicators below light a key while a condition holds (any page).")
                .font(.system(size: 10.5))
                .foregroundColor(Graphite.text3)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(controller.config.ledIndicators) { ind in
                IndicatorRow(controller: controller, indicator: ind)
            }

            Button {
                controller.addIndicator()
            } label: {
                Label("Add indicator", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Graphite.text2)
            }
            .buttonStyle(.plain)
            .help("Light a key while a condition holds — e.g. CAM8 while the tracked palette is HDR, or TRANS while the Resolve page is edit")
        }
    }

    // MARK: Device & daemon

    private var deviceAndDaemon: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Device & connection")
            HStack(spacing: 10) {
                Circle()
                    .fill(controller.deviceConnected ? Graphite.green : Graphite.amber)
                    .frame(width: 8, height: 8)
                Text(controller.deviceConnected
                     ? "Speed Editor connected & authenticated"
                     : "Waiting for device… (unplugged? locked by Resolve?)")
                    .font(.system(size: 12))
                    .foregroundColor(Graphite.text)
                Spacer()
                Button(controller.isRunning ? "Stop daemon" : "Start daemon") {
                    controller.isRunning ? controller.stopDaemon() : controller.startDaemon()
                }
                .buttonStyle(GraphiteButtonStyle(accent: controller.isRunning ? Graphite.red : Graphite.green))
            }
            Text("While the daemon runs, SpeedColors owns the Speed Editor. Stopping releases it — Resolve instantly regains its native integration.")
                .font(.system(size: 10.5))
                .foregroundColor(Graphite.text3)
            if let batt = controller.batteryLine {
                HStack(spacing: 6) {
                    Image(systemName: "battery.100")
                        .font(.system(size: 11))
                        .foregroundColor(Graphite.text3)
                    Text(batt)
                        .font(.system(size: 11).monospaced())
                        .foregroundColor(Graphite.text2)
                }
            }
        }
    }

    // MARK: Global defaults

    private var globalDefaults: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Global defaults")
            HStack {
                Text("Jog units per arrow (non-Color pages)")
                    .font(.system(size: 12))
                    .foregroundColor(Graphite.text)
                Spacer()
                Text("\(controller.config.jogUnitsPerArrow ?? 800)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(Graphite.cyan)
                Stepper("", value: jogBinding, in: 100...5000, step: 100)
                    .labelsHidden()
                    .controlSize(.mini)
            }
            Text("How many jog ticks accumulate before one arrow tap is injected on Cut/Edit/Media/Fairlight. Dial sensitivity per mode is per-profile (SHTL / JOG / SCRL buttons in Controls).")
                .font(.system(size: 10.5))
                .foregroundColor(Graphite.text3)
        }
    }

    private var jogBinding: Binding<Int> {
        Binding(
            get: { controller.config.jogUnitsPerArrow ?? 800 },
            set: {
                controller.config.jogUnitsPerArrow = $0
                controller.scheduleConfigSave()
            })
    }

    // MARK: Permissions

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Permissions")
            ForEach(AppPermissions.Kind.allCases) { kind in
                permissionRow(kind)
            }
            HStack {
                Text("Asked at launch. If SpeedColors is already listed but greyed out, macOS skips the dialog — toggle it off/on, or use Reset entry….")
                    .font(.system(size: 10.5))
                    .foregroundColor(Graphite.text3)
                Spacer()
                Button("Re-check") {
                    controller.refreshPermissions(reprobeInputMonitoring: true)
                }
                .buttonStyle(MiniButtonStyle())
            }
        }
    }

    private func permissionRow(_ kind: AppPermissions.Kind) -> some View {
        let ok = kind == .accessibility ? controller.accessibilityOK
            : kind == .screenRecording ? controller.screenRecordingOK
            : controller.inputMonitoringOK
        return HStack(spacing: 10) {
            Circle()
                .fill(ok ? Graphite.green : Graphite.red)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(kind.title) — \(kind.why)")
                    .font(.system(size: 12))
                    .foregroundColor(ok ? Graphite.text2 : Graphite.text)
                Text(ok ? "granted" : "missing — enable SpeedColors in System Settings")
                    .font(.system(size: 10.5))
                    .foregroundColor(ok ? Graphite.text3 : Graphite.amber)
            }
            Spacer()
            if !ok {
                Button("Reset entry…") { controller.resetAndReAskPermission(kind) }
                    .buttonStyle(MiniButtonStyle())
                    .help("Clears the stale permission entry for this app (tccutil) so the system dialog can appear again — use this when Grant… seems to do nothing")
                Button("Grant…") { controller.grantPermission(kind) }
                    .buttonStyle(MiniButtonStyle(accent: Graphite.blue))
            }
        }
    }

    // MARK: Advanced

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Advanced")
            kv("Config file", ColorModeConfig.defaultPath.path)
            kv("Resolve bundle id", "com.blackmagic-design.DaVinciResolve")
            HStack(spacing: 8) {
                Button("Reveal config in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ColorModeConfig.defaultPath])
                }
                .buttonStyle(MiniButtonStyle())
                Button("Auto-detect targets") { controller.runAutocal(force: false) }
                    .buttonStyle(MiniButtonStyle())
                    .disabled(controller.autocalBusy)
                if controller.autocalBusy {
                    Text("detecting…")
                        .font(.system(size: 10))
                        .foregroundColor(Graphite.amber)
                }
            }
            Text("Daemon reconnect: 1 → 2 → 3 → 5 s backoff · re-auth every 8 min · config hot-reloads on every edit.")
                .font(.system(size: 10.5))
                .foregroundColor(Graphite.text3)
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(k)
                .font(.system(size: 11))
                .foregroundColor(Graphite.text3)
                .frame(width: 150, alignment: .leading)
            Text(v)
                .font(.system(size: 11).monospaced())
                .foregroundColor(Graphite.text2)
                .textSelection(.enabled)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - One indicator row (key + condition)

struct IndicatorRow: View {
    @ObservedObject var controller: DaemonController
    let indicator: ColorModeConfig.LEDIndicator
    @State private var editingCond = false
    @State private var condDraft: MacroExpr = .group(.all, [])

    private var keyLabel: String {
        SpeedEditorKey.allCases.first { $0.id == indicator.key }?.label ?? indicator.key
    }
    private var hasBacklight: Bool {
        SpeedEditorKey.allCases.first { $0.id == indicator.key }?.led != nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(hasBacklight ? Graphite.cyan : Graphite.text3)
                .frame(width: 6, height: 6)
            Menu {
                ForEach(SpeedEditorKey.allCases.filter { $0.led != nil }, id: \.self) { k in
                    Button(k.label) { controller.setIndicatorKey(k.id, index: index) }
                }
            } label: {
                Text(keyLabel)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Graphite.text)
            }
            .controlSize(.small)
            .fixedSize()

            Text("while")
                .font(.system(size: 10))
                .foregroundColor(Graphite.text3)

            Text(indicator.expr.summary())
                .font(.system(size: 11))
                .foregroundColor(HWColor.selection)
                .lineLimit(1)
            Button("Edit") {
                condDraft = indicator.expr
                editingCond = true
            }
            .font(.system(size: 10))
            .foregroundColor(HWColor.selection)
            .buttonStyle(.plain)
            .popover(isPresented: $editingCond, arrowEdge: .bottom) {
                ConditionEditorPopover(
                    controller: controller,
                    draft: $condDraft,
                    onDone: {
                        controller.setIndicatorExpr(condDraft, index: index)
                        editingCond = false
                    },
                    onCancel: { editingCond = false })
            }

            Spacer(minLength: 4)

            Button {
                controller.removeIndicator(indicator.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Graphite.text3)
            }
            .buttonStyle(.plain)
            .help("Remove indicator")
        }
        .padding(.vertical, 3)
    }

    private var index: Int {
        controller.config.ledIndicators.firstIndex { $0.id == indicator.id } ?? 0
    }
}
