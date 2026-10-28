// TargetsView.swift — the Targets section: searchable list + inspector with
// capture, test, rename, and delete (showing which bindings use the target).

import SwiftUI
import SpeedColorsCore

struct TargetsView: View {
    @EnvironmentObject var controller: DaemonController

    var body: some View {
        HStack(spacing: 0) {
            TargetList(controller: controller)
                .frame(width: 320)
            Divider().overlay(Graphite.border)
            TargetInspectorPane(controller: controller)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - List

struct TargetList: View {
    @ObservedObject var controller: DaemonController
    @State private var query = ""
    @State private var showAddSheet = false
    @State private var newTargetName = ""

    /// Calibrated catalog targets, then uncalibrated catalog targets, then
    /// custom (non-catalog) calibrated ids.
    private var rows: [TargetRow] {
        let q = query.lowercased()
        var out: [TargetRow] = []
        for e in TargetCatalog.all where controller.config.targets[e.id] != nil {
            if matches(e.label, e.id, q) { out.append(.init(id: e.id, label: e.label, group: e.group, calibrated: true)) }
        }
        for id in controller.config.targets.keys.sorted() where TargetCatalog.label(for: id) == nil {
            if matches(id, id, q) { out.append(.init(id: id, label: id, group: "Calibrated (custom)", calibrated: true)) }
        }
        for e in TargetCatalog.all where controller.config.targets[e.id] == nil {
            if matches(e.label, e.id, q) { out.append(.init(id: e.id, label: e.label, group: e.group, calibrated: false)) }
        }
        return out
    }

    private func matches(_ label: String, _ id: String, _ q: String) -> Bool {
        q.isEmpty || label.lowercased().contains(q) || id.lowercased().contains(q)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("TARGETS (\(controller.config.targets.count))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Graphite.text3)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundColor(Graphite.cyan)
                }
                .buttonStyle(.plain)
                .help("Add a target")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Graphite.text3)
                TextField("Search targets…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Graphite.text)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Graphite.control))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Graphite.border, lineWidth: 1))
            .padding(.horizontal, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        Button {
                            controller.selectedTargetId = row.id
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(row.calibrated ? Graphite.cyan : Graphite.text3.opacity(0.4))
                                    .frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(row.label)
                                        .font(.system(size: 12, weight: controller.selectedTargetId == row.id ? .semibold : .regular))
                                        .foregroundColor(controller.selectedTargetId == row.id ? Graphite.text : Graphite.text2)
                                        .lineLimit(1)
                                    if let t = controller.config.targets[row.id] {
                                        Text("(\(Int(t.x)), \(Int(t.y)))")
                                            .font(.system(size: 9).monospacedDigit())
                                            .foregroundColor(Graphite.text3)
                                    } else {
                                        Text("uncalibrated")
                                            .font(.system(size: 9))
                                            .foregroundColor(Graphite.amber.opacity(0.85))
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 5).fill(
                                controller.selectedTargetId == row.id ? Graphite.hover : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Graphite.panel)
        .sheet(isPresented: $showAddSheet) {
            addTargetSheet
        }
    }

    private var addTargetSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New target")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Graphite.text)
            Text("The target starts at the current cursor position — use Capture or Manual capture to set the real spot.")
                .font(.system(size: 11))
                .foregroundColor(Graphite.text3)
            GraphiteField(placeholder: "target id (e.g. lut_zone_left)", text: $newTargetName)
            HStack {
                Spacer()
                Button("Cancel") { showAddSheet = false }
                    .buttonStyle(MiniButtonStyle())
                Button("Create") { createTarget() }
                    .buttonStyle(GraphiteButtonStyle(accent: Graphite.blue))
                    .disabled(newTargetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(Graphite.bg)
        .preferredColorScheme(.dark)
    }

    private func createTarget() {
        let name = newTargetName.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_").lowercased()
        guard !name.isEmpty else { return }
        let p = CGEvent(source: nil)?.location ?? .zero
        controller.saveTarget(name, p)
        controller.selectedTargetId = name
        newTargetName = ""
        showAddSheet = false
    }
}

struct TargetRow: Identifiable {
    let id: String
    let label: String
    let group: String
    let calibrated: Bool
}

// MARK: - Inspector

struct TargetInspectorPane: View {
    @ObservedObject var controller: DaemonController

    var body: some View {
        Group {
            if let id = controller.selectedTargetId,
               catalogLabel(for: id) != nil || controller.config.targets[id] != nil {
                TargetInspector(controller: controller, targetId: id)
            } else {
                EmptyState(icon: "scope",
                           title: "Select a target",
                           detail: "Targets are screen positions the cursor can park on. Pick one from the list, or add a new target.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Graphite.bg)
    }

    private func catalogLabel(for id: String) -> String? {
        TargetCatalog.label(for: id)
    }
}

struct TargetInspector: View {
    @ObservedObject var controller: DaemonController
    let targetId: String

    @State private var renameDraft = ""
    @State private var showDeleteConfirm = false
    @State private var justCaptured = false

    private var calibrated: Bool { controller.config.targets[targetId] != nil }
    private var label: String { controller.config.targetLabel(targetId) }
    private var usage: [String] { controller.targetUsage(targetId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Graphite.text)
                    Text(targetId)
                        .font(.system(size: 10).monospaced())
                        .foregroundColor(Graphite.text3)
                }

                // Position
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(title: "Position")
                    if let t = controller.config.targets[targetId] {
                        Text("x \(Int(t.x))  ·  y \(Int(t.y))")
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundColor(Graphite.cyan)
                    } else {
                        Text("Not calibrated — capture a position first.")
                            .font(.system(size: 11))
                            .foregroundColor(Graphite.amber)
                    }

                    TargetCaptureButtons(controller: controller, targetId: targetId)

                    HStack(spacing: 8) {
                        Button("Test") { controller.testTarget(targetId) }
                            .buttonStyle(MiniButtonStyle())
                            .disabled(!calibrated)
                        if justCaptured {
                            Text("saved")
                                .font(.system(size: 10))
                                .foregroundColor(Graphite.green)
                        }
                    }
                }

                Divider().overlay(Graphite.border)

                // Rename
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(title: "Name")
                    HStack(spacing: 8) {
                        GraphiteField(placeholder: "target id…", text: $renameDraft, width: 220)
                        Button("Rename") { applyRename() }
                            .buttonStyle(MiniButtonStyle())
                            .disabled(renameDraft.isEmpty || renameDraft == targetId)
                    }
                    Text("Renaming rewrites every binding that references this target.")
                        .font(.system(size: 10))
                        .foregroundColor(Graphite.text3)
                }

                Divider().overlay(Graphite.border)

                // Usage
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(title: "Used by")
                    if usage.isEmpty {
                        Text("No bindings reference this target.")
                            .font(.system(size: 11))
                            .foregroundColor(Graphite.text3)
                    } else {
                        ForEach(usage, id: \.self) { u in
                            Text("· \(u)")
                                .font(.system(size: 11).monospaced())
                                .foregroundColor(Graphite.text2)
                        }
                    }
                }

                Divider().overlay(Graphite.border)

                HStack {
                    Spacer()
                    Button("Delete Target…") { showDeleteConfirm = true }
                        .buttonStyle(MiniButtonStyle(danger: true))
                }
            }
            .padding(16)
        }
        .onAppear { renameDraft = targetId }
        .onChange(of: targetId) { renameDraft = $0 }
        .onChange(of: controller.configRevision) { _ in
            // Capture saved → brief confirmation.
            justCaptured = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justCaptured = false }
        }
        .alert("Delete target?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                controller.deleteTarget(targetId)
            }
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        guard calibrated else { return "Remove “\(label)” from the list." }
        if usage.isEmpty {
            return "“\(label)” is not used by any binding. Delete it?"
        }
        return "“\(label)” is used by \(usage.count) binding\(usage.count == 1 ? "" : "s"):\n" + usage.prefix(6).joined(separator: "\n")
            + (usage.count > 6 ? "\n…" : "")
            + "\n\nSteps referencing it will keep pointing at the deleted id and report “target not calibrated” when run."
    }

    private func applyRename() {
        let new = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != targetId else { return }
        if controller.renameTarget(targetId, to: new) {
            controller.selectedTargetId = new
        }
    }
}
