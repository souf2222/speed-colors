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
            HStack(spacing: 10) {
                Circle()
                    .fill(controller.accessibilityOK ? Graphite.green : Graphite.red)
                    .frame(width: 8, height: 8)
                Text(controller.accessibilityOK
                     ? "Accessibility granted — key and mouse injection work."
                     : "Accessibility required — enable SpeedColors in System Settings.")
                    .font(.system(size: 12))
                    .foregroundColor(controller.accessibilityOK ? Graphite.text2 : Graphite.text)
                Spacer()
                if !controller.accessibilityOK {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .buttonStyle(MiniButtonStyle(accent: Graphite.blue))
                }
            }
            Text("Key capture uses an Input Monitoring event tap (system-wide, swallowed keys). If capture misses keys, grant Input Monitoring too.")
                .font(.system(size: 10.5))
                .foregroundColor(Graphite.text3)
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
