// TargetsView.swift — the Targets section: a hierarchical library of Color-page
// controls (groups in Resolve order, typed targets, favorites, calibrated
// counts, All/Calibrated/Uncalibrated filters) plus an inspector with capture,
// test, rename (custom only), and delete.

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

// MARK: - Type icon

/// Small glyph describing how a target is meant to be interacted with.
struct TargetTypeIcon: View {
    let type: TargetType?
    let calibrated: Bool

    private var symbol: String {
        switch type {
        case .click: return "cursorarrow.click"
        case .adjust: return "slider.horizontal.2"
        case .wheel: return "circle.lefthalf.filled"
        case .region: return "viewfinder"
        case nil: return "target"
        }
    }

    private var color: Color {
        if !calibrated && type == nil { return Graphite.text3 }
        return calibrated ? Graphite.cyan : Graphite.text3
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9))
            .foregroundColor(color)
            .help(type?.label ?? "Custom target")
    }
}

// MARK: - List

struct TargetList: View {
    @ObservedObject var controller: DaemonController

    @State private var query = ""
    @State private var showAddSheet = false
    @State private var newTargetName = ""
    @State private var newTargetLabel = ""
    @State private var calibrateAfterAdd = true
    @State private var filter: Filter = .all
    @State private var collapsed: Set<String> = []
    @State private var calibrationPending: String?

    enum Filter: String, CaseIterable {
        case all = "All"
        case calibrated = "Calibrated"
        case uncalibrated = "Uncalibrated"
    }

    struct SectionData: Identifiable {
        let title: String
        let rows: [TargetRow]
        /// "8/19 calibrated" — header count (unfiltered).
        let count: String
        var id: String { title }
    }

    struct TargetRow: Identifiable {
        let id: String
        let name: String
        let parentPath: String
        let type: TargetType?
        let calibrated: Bool
        let custom: Bool
    }

    // MARK: Data

    private func makeRow(id: String) -> TargetRow {
        let e = TargetCatalog.entry(for: id)
        let customName = controller.config.customTargets[id]
        return TargetRow(
            id: id,
            name: e?.name ?? (customName ?? id),
            parentPath: e?.parentPath ?? "",
            type: e?.type,
            calibrated: controller.config.targets[id] != nil,
            custom: TargetCatalog.entry(for: id) == nil)
    }

    private func passes(_ row: TargetRow) -> Bool {
        switch filter {
        case .all: break
        case .calibrated: guard row.calibrated else { return false }
        case .uncalibrated: guard !row.calibrated else { return false }
        }
        guard !query.isEmpty else { return true }
        let hay = (row.name + " " + row.parentPath + " "
                   + (TargetCatalog.label(for: row.id) ?? "") + " " + row.id).lowercased()
        return hay.contains(query.lowercased())
    }

    /// Favorites pinned in the user's order, then catalog groups in catalog
    /// order (favorited targets are not repeated in their group), then Custom.
    private var sections: [SectionData] {
        let calibratedCount = { (group: String) -> (Int, Int) in
            let all = TargetCatalog.all.filter { $0.topGroup == group }
            let done = all.filter { controller.config.targets[$0.id] != nil }.count
            return (done, all.count)
        }

        // Rows grouped by top-level catalog group.
        var grouped: [String: [TargetRow]] = [:]
        for e in TargetCatalog.all {
            guard !controller.config.favoriteTargets.contains(e.id) else { continue }  // no dupes
            let row = makeRow(id: e.id)
            guard passes(row) else { continue }
            grouped[e.topGroup, default: []].append(row)
        }

        var out: [SectionData] = []

        let favs = controller.config.favoriteTargets
            .filter { TargetCatalog.entry(for: $0) != nil || controller.config.targets[$0] != nil }
            .map(makeRow)
            .filter(passes)
        if !favs.isEmpty { out.append(SectionData(title: "Favorites", rows: favs, count: "")) }

        for group in TargetCatalog.groupOrder {
            let rows = grouped[group] ?? []
            let (done, total) = calibratedCount(group)
            // Empty groups stay visible: the count communicates availability.
            out.append(SectionData(title: group, rows: rows,
                                   count: total > 0 ? "\(done)/\(total) calibrated" : ""))
        }

        let customs = controller.config.customTargetIds.map(makeRow)
            .filter(passes)
        if !customs.isEmpty { out.append(SectionData(title: "Custom targets", rows: customs, count: "")) }

        return out
    }

    /// Structural note: group counts are computed on the unfiltered catalog,
    /// so they stay stable while a search narrows the rows.
    private var calibratedAll: Int {
        controller.config.targets.keys
            .filter { TargetCatalog.entry(for: $0) != nil || controller.config.targets[$0] != nil }.count
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("TARGETS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Graphite.text3)
                    Text("\(controller.config.targets.count) calibrated · \(TargetCatalog.all.count) available")
                        .font(.system(size: 9))
                        .foregroundColor(Graphite.text3.opacity(0.8))
                }
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
                TextField("Search full path…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Graphite.text)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Graphite.control))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Graphite.border, lineWidth: 1))
            .padding(.horizontal, 10)

            Picker("", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .font(.system(size: 10))
            .padding(.horizontal, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sections) { section in
                        sectionHeader(section)
                        if !collapsed.contains(section.title) {
                            ForEach(section.rows) { row in
                                targetRowButton(row)
                            }
                            if section.rows.isEmpty {
                                Text(query.isEmpty ? "No matching targets" : "No matches for “\(query)”")
                                    .font(.system(size: 11))
                                    .foregroundColor(Graphite.text3)
                                    .padding(.leading, 24)
                            }
                        }
                    }
                    if sections.isEmpty {
                        Text(query.isEmpty
                             ? "No targets match this filter."
                             : "No targets match “\(query)”.")
                            .font(.system(size: 11))
                            .foregroundColor(Graphite.text3)
                            .padding(.top, 8)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Graphite.panel)
        .sheet(isPresented: $showAddSheet) {
            addTargetSheet
        }
    }

    // MARK: Section header

    private func sectionHeader(_ section: SectionData) -> some View {
        Button {
            if collapsed.contains(section.title) { collapsed.remove(section.title) }
            else { collapsed.insert(section.title) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: collapsed.contains(section.title) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Graphite.text3)
                    .frame(width: 10)
                Text(section.title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(Graphite.text3)
                Spacer()
                if !section.count.isEmpty {
                    Text(section.count)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundColor(section.count.hasPrefix("0/") ? Graphite.text3 : Graphite.green.opacity(0.85))
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 5)
    }

    // MARK: Row

    private func targetRowButton(_ row: TargetRow) -> some View {
        let isFav = controller.isFavoriteTarget(row.id)
        return Button {
            controller.selectedTargetId = row.id
        } label: {
            HStack(spacing: 6) {
                TargetTypeIcon(type: row.type, calibrated: row.calibrated)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.name)
                        .font(.system(size: 12, weight: controller.selectedTargetId == row.id ? .semibold : .regular))
                        .foregroundColor(controller.selectedTargetId == row.id ? Graphite.text : Graphite.text2)
                        .lineLimit(1)
                    Text(row.custom ? row.id : row.parentPath)
                        .font(.system(size: 9))
                        .foregroundColor(Graphite.text3)
                        .lineLimit(1)
                }
                Spacer()
                if isFav {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundColor(Graphite.amber)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(
                controller.selectedTargetId == row.id ? Graphite.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(isFav ? "Remove from Favorites" : "Add to Favorites") {
                controller.toggleTargetFavorite(row.id)
            }
            Button("Calibrate in 3 s") { beginCalibration(row.id) }
            if row.calibrated {
                Button("Test") { controller.testTarget(row.id) }
            }
            if !row.calibrated {
                Button("Delete", role: .destructive) { controller.deleteTarget(row.id) }
                    .disabled(!row.custom)
            }
        }
    }

    /// Cheap guided calibration: countdown on the main queue, then save the
    /// cursor position under the target id (same flow as Capture in 3 s).
    private func beginCalibration(_ id: String) {
        guard calibrationPending == nil else { return }
        calibrationPending = id
        controller.appendLog("· calibrating '\(id)' in 3 s — move the cursor onto the control…")
        tick(3, id)
    }

    private func tick(_ n: Int, _ id: String) {
        if n == 0 {
            let p = CGEvent(source: nil)?.location ?? .zero
            controller.saveTarget(id, p)
            calibrationPending = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick(n - 1, id) }
    }

    // MARK: Add sheet

    private var addTargetSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New target")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Graphite.text)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name shown in the library and action pickers")
                    .font(.system(size: 10))
                    .foregroundColor(Graphite.text3)
                GraphiteField(placeholder: "Display name (e.g. HDR Trellis pivot)", text: $newTargetLabel)
                Text("Stable id — used by bindings and macros")
                    .font(.system(size: 10))
                    .foregroundColor(Graphite.text3)
                GraphiteField(placeholder: "snake_case id (e.g. hdr_trellis_pivot)", text: $newTargetName)
            }
            Toggle("Calibrate now (3 s countdown, then saves the cursor position)", isOn: $calibrateAfterAdd)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11))
                .foregroundColor(Graphite.text2)
            if !calibrateAfterAdd {
                Text("It will appear as uncalibrated — calibrate later from the row's right-click menu.")
                    .font(.system(size: 10))
                    .foregroundColor(Graphite.amber.opacity(0.9))
            }
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
        .frame(width: 372)
        .background(Graphite.bg)
        .preferredColorScheme(.dark)
    }

    /// Slugs a display name into a snake_case id.
    private func slug(_ s: String) -> String {
        let folded = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var out = ""
        var lastUnderscore = true
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastUnderscore = false
            } else if !lastUnderscore {
                out.append("_")
                lastUnderscore = true
            }
        }
        return out.hasSuffix("_") ? String(out.dropLast()) : out
    }

    private func createTarget() {
        let label = newTargetLabel.trimmingCharacters(in: .whitespaces)
        let rawId = newTargetName.trimmingCharacters(in: .whitespaces)
        let id = slug(rawId.isEmpty ? label : rawId)
        guard !id.isEmpty else { return }
        let display = label.isEmpty ? rawId : label
        // addCustomTarget logs a failure itself when the id is already taken.
        guard controller.addCustomTarget(id: id, label: display) else { return }
        controller.selectedTargetId = id
        if calibrateAfterAdd { beginCalibration(id) }
        newTargetName = ""
        newTargetLabel = ""
        showAddSheet = false
    }
}

// MARK: - Inspector

struct TargetInspectorPane: View {
    @ObservedObject var controller: DaemonController

    var body: some View {
        Group {
            if let id = controller.selectedTargetId,
               TargetCatalog.entry(for: id) != nil || controller.config.targets[id] != nil {
                TargetInspector(controller: controller, targetId: id)
            } else {
                EmptyState(icon: "scope",
                           title: "Select a target",
                           detail: "Targets are screen positions the cursor can park on. Pick one from the library, or add a new target.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Graphite.bg)
    }
}

struct TargetInspector: View {
    @ObservedObject var controller: DaemonController
    let targetId: String

    @State private var renameDraft = ""
    @State private var showDeleteConfirm = false
    @State private var justCaptured = false

    private var entry: TargetCatalogEntry? { TargetCatalog.entry(for: targetId) }
    private var calibrated: Bool { controller.config.targets[targetId] != nil }
    private var label: String { controller.config.targetLabel(targetId) }
    private var usage: [String] { controller.targetUsage(targetId) }
    private var isFavorite: Bool { controller.isFavoriteTarget(targetId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Name + type + favorite
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry?.name ?? targetId)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Graphite.text)
                        HStack(spacing: 6) {
                            if let e = entry {
                                Pill(color: Graphite.cyan.opacity(0.9), label: e.type.label)
                            } else {
                                Pill(color: Graphite.amber.opacity(0.9), label: "Custom")
                            }
                            Text(parentPathText)
                                .font(.system(size: 10))
                                .foregroundColor(Graphite.text3)
                        }
                    }
                    Spacer()
                    Button {
                        controller.toggleTargetFavorite(targetId)
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .foregroundColor(isFavorite ? Graphite.amber : Graphite.text3)
                    }
                    .buttonStyle(.plain)
                    .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                }

                if let req = entry?.requires {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9))
                            .foregroundColor(Graphite.amber.opacity(0.9))
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Requires")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Graphite.text3)
                            Text(req)
                                .font(.system(size: 11))
                                .foregroundColor(Graphite.amber.opacity(0.9))
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Graphite.amber.opacity(0.07)))
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

                // Rename — only for custom targets; catalog ids are stable and
                // referenced by autocal + bindings, so they aren't renamable.
                if entry == nil {
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
                }

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
                        .disabled(!calibrated && entry != nil)
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

    private var parentPathText: String {
        if let e = entry { return e.parentPath }
        return "custom target"
    }

    private var deleteMessage: String {
        guard calibrated else { return "Remove “\(entry?.name ?? targetId)” from the list." }
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
