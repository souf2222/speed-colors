// AppShell.swift — the consistent application chrome: global top bar (device,
// profile, detected page, save state, Settings entry), section tabs
// (Controls / Targets / Profiles / Diagnostics), section content, and a
// compact status bar. Hidden ⌘Z / ⇧⌘Z buttons drive binding undo/redo.

import SwiftUI
import SpeedColorsCore

enum AppSection: String, CaseIterable, Identifiable {
    case controls = "Controls"
    case targets = "Targets"
    case profiles = "Profiles"
    case diagnostics = "Diagnostics"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .controls: return "slider.horizontal.3"
        case .targets: return "scope"
        case .profiles: return "person.crop.rectangle.stack"
        case .diagnostics: return "stethoscope"
        case .settings: return "gearshape"
        }
    }
}

struct AppShell: View {
    @EnvironmentObject var controller: DaemonController

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Graphite.border)
            sectionTabs
            Divider().overlay(Graphite.border)

            Group {
                switch controller.section {
                case .controls: ControlsView()
                case .targets: TargetsView()
                case .profiles: ProfilesView()
                case .diagnostics: DiagnosticsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Graphite.border)
            statusBar
        }
        .background(Graphite.bg)
        .preferredColorScheme(.dark)
        .overlay(undoRedoShortcuts)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("SpeedColors")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Graphite.text)

            // Device + connection status
            Pill(color: controller.deviceConnected ? Graphite.green
                  : (controller.isRunning ? Graphite.amber : Graphite.text3),
                 label: controller.deviceConnected ? "Speed Editor live"
                        : (controller.isRunning ? "waiting for device…" : "daemon stopped"))

            // Active profile (manual selection from the top bar)
            profileMenu

            // Detected app/page, with an explicit "Not detected" state.
            Pill(color: pageColor,
                 label: controller.page.map { p in
                     p == "color" ? "COLOR PAGE" : "page: \(p)"
                 } ?? "Not detected")

            Spacer()

            // Autosave indicator — the one predictable place.
            saveState

            Button {
                controller.section = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundColor(controller.section == .settings ? Graphite.blue : Graphite.text2)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var pageColor: Color {
        guard let p = controller.page else { return Graphite.text3 }
        return p == "color" ? Graphite.cyan : Graphite.blue
    }

    private var profileMenu: some View {
        Menu {
            ForEach(controller.profileNames, id: \.self) { name in
                Button {
                    controller.switchProfile(name)
                } label: {
                    if name == controller.activeProfileName {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.rectangle.stack")
                    .font(.system(size: 10))
                Text(controller.activeProfileName)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
            }
            .foregroundColor(Graphite.text2)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(Graphite.control))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Active profile")
    }

    private var saveState: some View {
        Group {
            switch controller.saveState {
            case .idle:
                EmptyView()
            case .saving:
                Text("Saving…").font(.system(size: 10)).foregroundColor(Graphite.text3)
            case .saved:
                Text("Saved").font(.system(size: 10)).foregroundColor(Graphite.green)
            case .failed(let msg):
                Text("Save failed: \(msg)")
                    .font(.system(size: 10))
                    .foregroundColor(Graphite.red)
            }
        }
    }

    // MARK: Section tabs

    private var sectionTabs: some View {
        HStack(spacing: 2) {
            ForEach([AppSection.controls, .targets, .profiles, .diagnostics], id: \.self) { s in
                Button {
                    controller.section = s
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: s.icon)
                            .font(.system(size: 10))
                        Text(s.rawValue)
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundColor(controller.section == s ? Graphite.text : Graphite.text2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(controller.section == s ? Graphite.hover : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(controller.isRunning
                      ? (controller.deviceConnected ? Graphite.green : Graphite.amber)
                      : Graphite.text3)
                .frame(width: 8, height: 8)
            Text(controller.isRunning
                 ? (controller.deviceConnected ? "Speed Editor connected" : "waiting for device…")
                 : "daemon stopped — Resolve has the Speed Editor (stock)")
                .font(.system(size: 10.5).monospaced())
                .foregroundColor(Graphite.text2)

            if !controller.accessibilityOK {
                Pill(color: Graphite.red, label: "⚠︎ Accessibility required")
            } else if !controller.screenRecordingOK {
                Pill(color: Graphite.amber, label: "⚠︎ Screen Recording off — no palette auto-detect")
            }

            if controller.deviceConnected != true || !controller.accessibilityOK {
                Button("Open Diagnostics") { controller.section = .diagnostics }
                    .buttonStyle(MiniButtonStyle())
            }

            Spacer()

            if controller.section == .diagnostics {
                Text("~/.speedcolors/color.json")
                    .font(.system(size: 9.5).monospaced())
                    .foregroundColor(Graphite.text3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: Undo/redo shortcuts (invisible but active)

    private var undoRedoShortcuts: some View {
        Group {
            Button("Undo") { controller.undoBinding() }
                .keyboardShortcut("z", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            Button("Redo") { controller.redoBinding() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }
}
