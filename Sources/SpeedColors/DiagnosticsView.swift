// DiagnosticsView.swift — connection/auth state, execution errors, config
// activity, and technical details. The full activity log lives here.

import SwiftUI
import SpeedColorsCore

struct DiagnosticsView: View {
    @EnvironmentObject var controller: DaemonController

    var body: some View {
        HStack(spacing: 0) {
            // Left: state cards + technical details
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    stateCards
                    Divider().overlay(Graphite.border)
                    technical
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 340)
            Divider().overlay(Graphite.border)

            // Right: activity log
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SectionTitle(title: "Activity")
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(controller.logLines.joined(separator: "\n"), forType: .string)
                    }
                    .buttonStyle(MiniButtonStyle())
                    Button("Clear") { controller.logLines = [] }
                        .buttonStyle(MiniButtonStyle())
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(controller.logLines.enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(.system(size: 10).monospaced())
                                    .foregroundColor(logColor(line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id(i)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .onChange(of: controller.logLines.count) { _ in
                        proxy.scrollTo(controller.logLines.count - 1, anchor: .bottom)
                    }
                }
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity)
            .background(Graphite.panel)
        }
    }

    // MARK: State cards

    private var stateCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "State")
            stateRow(color: controller.deviceConnected ? Graphite.green : Graphite.amber,
                     title: "Device",
                     value: controller.deviceConnected ? "Connected & authenticated" : "Waiting for device…")
            stateRow(color: controller.isRunning ? Graphite.green : Graphite.text3,
                     title: "Daemon",
                     value: controller.isRunning ? "Running — Speed Editor owned" : "Stopped — Resolve has the device (stock)")
            stateRow(color: controller.page == "color" ? Graphite.cyan : (controller.page == nil ? Graphite.text3 : Graphite.blue),
                     title: "Page",
                     value: controller.page.map { "Detected: \($0)" } ?? "Not detected")
            stateRow(color: controller.accessibilityOK ? Graphite.green : Graphite.red,
                     title: "Permissions",
                     value: controller.accessibilityOK ? "Accessibility granted" : "Accessibility required — key injection will fail")
            stateRow(color: controller.screenRecordingOK ? Graphite.green : Graphite.amber,
                     title: "Screen Rec.",
                     value: controller.screenRecordingOK ? "Granted — palette auto-detect works"
                         : "Missing — palette auto-detect disabled")
            stateRow(color: controller.inputMonitoringOK ? Graphite.green : Graphite.amber,
                     title: "Input Monit.",
                     value: controller.inputMonitoringOK ? "Granted — shortcut recorder swallows keys"
                         : "Missing — key capture falls back (keys may leak)")
            if let batt = controller.batteryLine {
                stateRow(color: Graphite.text2, title: "Battery", value: batt)
            }
        }
    }

    private func stateRow(color: Color, title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Graphite.text2)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(Graphite.text)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 3)
    }

    // MARK: Technical

    private var technical: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Technical")
            kv("Config file", ColorModeConfig.defaultPath.path)
            kv("Active profile", controller.activeProfileName)
            kv("Targets", "\(controller.config.targets.count) calibrated")
            kv("Bindings (active profile)", "\(controller.config.bindings.filter { !$0.value.isEmpty }.count) pressed · \(controller.config.released.filter { !$0.value.isEmpty }.count) released")
            kv("Disabled bindings", controller.config.disabledBindings.isEmpty ? "none" : controller.config.disabledBindings.joined(separator: ", "))
            kv("Jog units / arrow", "\(controller.config.jogUnitsPerArrow ?? 800)")
            kv("Drag px / unit", String(format: "%.3f", controller.config.pixelsPerUnit))
            kv("Drag release idle", String(format: "%.2f s", controller.config.dragReleaseIdle))

            HStack(spacing: 8) {
                Button("Reload config from disk") { controller.reloadFromDisk(manual: true) }
                    .buttonStyle(MiniButtonStyle())
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ColorModeConfig.defaultPath])
                }
                .buttonStyle(MiniButtonStyle())
            }
            .padding(.top, 4)
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(k)
                .font(.system(size: 11))
                .foregroundColor(Graphite.text3)
                .frame(width: 170, alignment: .leading)
            Text(v)
                .font(.system(size: 11).monospaced())
                .foregroundColor(Graphite.text2)
                .textSelection(.enabled)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer()
        }
    }

    private func logColor(_ line: String) -> Color {
        if line.hasPrefix("✗") { return Graphite.red }
        if line.contains("✗") { return Graphite.red }
        if line.hasPrefix("✓") { return Graphite.green }
        if line.hasPrefix("⚠") { return Graphite.amber }
        if line.hasPrefix("🎨") || line.hasPrefix("⌨") || line.hasPrefix("🎡") { return Graphite.cyan.opacity(0.9) }
        return Graphite.text2
    }
}
