// ProfilesView.swift — the Profiles section: create, duplicate, rename,
// delete, switch, and optional per-app association (auto-switching itself is
// not active yet).

import AppKit
import SwiftUI
import SpeedColorsCore

struct ProfilesView: View {
    @EnvironmentObject var controller: DaemonController

    @State private var selected: String?
    @State private var sheet: ProfileSheet?

    enum ProfileSheet: Identifiable {
        case create
        case duplicate(String)
        case rename(String)

        var id: String {
            switch self {
            case .create: return "create"
            case .duplicate(let s): return "dup-\(s)"
            case .rename(let s): return "ren-\(s)"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    SectionTitle(title: "Profiles")
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(controller.profileNames, id: \.self) { name in
                            profileRow(name)
                        }
                    }
                    .padding(.horizontal, 10)
                }

                Divider().overlay(Graphite.border)

                HStack(spacing: 6) {
                    Button("New…") { sheet = .create }
                        .buttonStyle(MiniButtonStyle())
                    Button("Duplicate…") {
                        sheet = .duplicate(selected ?? controller.activeProfileName)
                    }
                    .buttonStyle(MiniButtonStyle())
                    Button("Rename…") {
                        sheet = .rename(selected ?? controller.activeProfileName)
                    }
                    .buttonStyle(MiniButtonStyle())
                    Spacer()
                    Button("Delete") {
                        let target = selected ?? ""
                        controller.deleteProfile(target)
                        selected = controller.activeProfileName
                    }
                    .buttonStyle(MiniButtonStyle(danger: true))
                    .disabled(canDelete(selected) == false)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .frame(width: 300)
            .background(Graphite.panel)

            Divider().overlay(Graphite.border)

            Group {
                if let name = selected ?? controller.profileNames.first {
                    ProfileInspector(controller: controller, profileName: name)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $sheet) { s in
            nameSheet(s)
        }
        .onAppear {
            if selected == nil { selected = controller.activeProfileName }
        }
    }

    private func canDelete(_ name: String?) -> Bool {
        guard let name,
              controller.profileExists(name),
              name != ColorModeConfig.defaultProfile else { return false }
        return true
    }

    private func profileRow(_ name: String) -> some View {
        let isActive = name == controller.activeProfileName
        let isSel = (selected ?? controller.activeProfileName) == name
        return Button {
            selected = name
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(isActive ? Graphite.green : Graphite.text3.opacity(0.4))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 12, weight: isSel ? .semibold : .regular))
                        .foregroundColor(isSel ? Graphite.text : Graphite.text2)
                    HStack(spacing: 8) {
                        Text("\(controller.profileBindingCount(name)) bindings")
                        if let apps = controller.config.profileApps[name], !apps.isEmpty {
                            Text("\(apps.count) app\(apps.count == 1 ? "" : "s")")
                        }
                    }
                    .font(.system(size: 9.5))
                    .foregroundColor(Graphite.text3)
                }
                Spacer()
                if isActive {
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Graphite.green)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(isSel ? Graphite.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Switch to this profile") { controller.switchProfile(name) }
                .disabled(isActive)
            Divider()
            Button("Duplicate…") { sheet = .duplicate(name) }
            Button("Rename…") { sheet = .rename(name) }
                .disabled(name == ColorModeConfig.defaultProfile)
            Divider()
            Button("Delete", role: .destructive) {
                controller.deleteProfile(name)
                selected = controller.activeProfileName
            }
            .disabled(!canDelete(name))
        }
    }

    // MARK: Name sheet (create / duplicate / rename)

    @State private var sheetName = ""

    private func nameSheet(_ s: ProfileSheet) -> some View {
        let title: String
        switch s {
        case .create:      title = "New profile"
        case .duplicate(let src): title = "Duplicate “\(src)”"
        case .rename(let src):    title = "Rename “\(src)”"
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Graphite.text)
            GraphiteField(placeholder: "profile name", text: $sheetName)
            HStack {
                Spacer()
                Button("Cancel") {
                    sheet = nil
                    sheetName = ""
                }
                .buttonStyle(MiniButtonStyle())
                Button("OK") {
                    let name = sheetName.trimmingCharacters(in: .whitespaces)
                    switch s {
                    case .create:
                        controller.createProfile(name)
                        selected = name
                    case .duplicate(let src):
                        controller.duplicateProfile(src, as: name)
                    case .rename(let src):
                        controller.renameProfile(src, to: name)
                        if selected == src { selected = name }
                    }
                    sheet = nil
                    sheetName = ""
                }
                .buttonStyle(GraphiteButtonStyle(accent: Graphite.blue))
                .disabled(sheetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Graphite.bg)
        .preferredColorScheme(.dark)
        .onAppear { sheetName = "" }
    }
}

// MARK: - Inspector

struct ProfileInspector: View {
    @ObservedObject var controller: DaemonController
    let profileName: String

    @State private var newAppId = ""

    private var isActive: Bool { profileName == controller.activeProfileName }
    private var apps: [String] { controller.config.profileApps[profileName] ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(profileName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Graphite.text)
                        if isActive {
                            Pill(color: Graphite.green, label: "active")
                        }
                    }
                    Text(isActive
                         ? "This profile's bindings are live on the daemon."
                         : "Stored profile — switch to it to load its bindings.")
                        .font(.system(size: 11))
                        .foregroundColor(Graphite.text3)
                }

                if !isActive {
                    Button("Switch to this profile") { controller.switchProfile(profileName) }
                        .buttonStyle(GraphiteButtonStyle(accent: Graphite.blue))
                }

                Divider().overlay(Graphite.border)

                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(title: "Contents")
                    Text("\(controller.profileBindingCount(profileName)) bound button\(controller.profileBindingCount(profileName) == 1 ? "" : "s") · dial settings and drag tuning are per-profile")
                        .font(.system(size: 11))
                        .foregroundColor(Graphite.text2)
                }

                Divider().overlay(Graphite.border)

                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(title: "App association (optional)")
                    Text("Profiles can remember which app they belong to. Automatic switching is not active yet — selection stays manual from the top bar.")
                        .font(.system(size: 10))
                        .foregroundColor(Graphite.text3)

                    ForEach(apps, id: \.self) { appId in
                        HStack(spacing: 6) {
                            Image(systemName: "app")
                                .font(.system(size: 10))
                                .foregroundColor(Graphite.text3)
                            Text(appId)
                                .font(.system(size: 11).monospaced())
                                .foregroundColor(Graphite.text)
                            Spacer()
                            Button {
                                controller.removeProfileApp(profileName, appId)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Graphite.text3)
                            }
                            .buttonStyle(.plain)
                            .help("Remove app association")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Graphite.control.opacity(0.6)))
                    }

                    HStack(spacing: 6) {
                        GraphiteField(placeholder: "bundle id (com.company.app)", text: $newAppId, width: 240)
                        Button("Add") { addApp() }
                            .buttonStyle(MiniButtonStyle())
                            .disabled(newAppId.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Frontmost app") { addFrontmostApp() }
                            .buttonStyle(MiniButtonStyle())
                    }
                }

                Spacer()
            }
            .padding(16)
        }
    }

    private func addApp() {
        let id = newAppId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        controller.addProfileApp(profileName, id)
        newAppId = ""
    }

    private func addFrontmostApp() {
        if let app = NSWorkspace.shared.frontmostApplication,
           let bundle = app.bundleIdentifier {
            controller.addProfileApp(profileName, bundle)
        }
    }
}
