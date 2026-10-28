// TargetPicker.swift — searchable, grouped catalog of Color-page elements,
// plus the calibrate-with-mouse flow (3 s countdown, then grab cursor pos).

import AppKit
import SwiftUI
import SpeedColorsCore

// MARK: - Picker

struct TargetPicker: View {
    @ObservedObject var controller: DaemonController
    let selected: String?
    let onSelect: (String) -> Void

    @State private var query = ""

    private struct Row: Identifiable {
        let id: String
        let label: String
        let group: String
        let calibrated: Bool
    }

    private var rows: [Row] {
        var out: [Row] = []
        let q = query.lowercased()
        for e in TargetCatalog.all {
            if q.isEmpty || e.id.lowercased().contains(q) || e.label.lowercased().contains(q) {
                out.append(Row(id: e.id, label: e.label, group: e.group,
                               calibrated: controller.config.targets[e.id] != nil))
            }
        }
        // Custom (non-catalog) calibrated targets, e.g. from `coords --save`.
        for id in controller.config.targets.keys.sorted() where TargetCatalog.label(for: id) == nil {
            if q.isEmpty || id.lowercased().contains(q) {
                out.append(Row(id: id, label: id, group: "Calibrated (custom)", calibrated: true))
            }
        }
        return out
    }

    private var grouped: [(String, [Row])] {
        var order: [String] = []
        var byGroup: [String: [Row]] = [:]
        for r in rows {
            if byGroup[r.group] == nil { order.append(r.group) }
            byGroup[r.group, default: []].append(r)
        }
        return order.map { ($0, byGroup[$0]!) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Graphite.text3)
                TextField("search color-page elements…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Graphite.text)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(Graphite.control))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Graphite.border, lineWidth: 1))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(grouped, id: \.0) { group, items in
                        Text(group.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Graphite.text3)
                            .padding(.top, 3)
                        ForEach(items) { row in
                            Button {
                                onSelect(row.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(row.calibrated ? Graphite.cyan : Graphite.text3.opacity(0.4))
                                        .frame(width: 5, height: 5)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(row.label)
                                            .font(.system(size: 12))
                                            .foregroundColor(Graphite.text)
                                        Text(row.id)
                                            .font(.system(size: 9).monospaced())
                                            .foregroundColor(Graphite.text3)
                                    }
                                    Spacer()
                                    if !row.calibrated {
                                        Text("uncalibrated")
                                            .font(.system(size: 9))
                                            .foregroundColor(Graphite.amber.opacity(0.85))
                                    }
                                    if selected == row.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(Graphite.blue)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if grouped.isEmpty {
                        Text("no match")
                            .font(.system(size: 11))
                            .foregroundColor(Graphite.text3)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 280)
        }
    }
}

// MARK: - Calibrator

/// Picker + calibrate footer. Selecting an entry calls `onSelectOnly` (the
/// binding editor uses it to set the step's target); "Calibrate in 3 s"
/// counts down, grabs the cursor position, and saves it as the target.
struct TargetCalibrator: View {
    @ObservedObject var controller: DaemonController
    var onSelectOnly: ((String) -> Void)? = nil
    var onSaved: ((String) -> Void)? = nil

    @State private var pending: String?
    @State private var countdown: Int?
    @State private var armedManual = false
    @State private var clickMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TargetPicker(controller: controller, selected: pending) { id in
                pending = id
                onSelectOnly?(id)
            }
            HStack(spacing: 8) {
                if armedManual {
                    Text("click the element in Resolve…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Graphite.amber)
                    Button("cancel") { disarmManual() }
                        .buttonStyle(GraphiteButtonStyle())
                } else if let cd = countdown {
                    Text("move the mouse onto “\(pending ?? "?")” … \(cd)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Graphite.amber)
                } else {
                    Button("Calibrate \(pending ?? "—") in 3 s") { begin() }
                        .buttonStyle(GraphiteButtonStyle())
                        .disabled(pending == nil)
                    Button("Manual: click the element") { armManual() }
                        .buttonStyle(GraphiteButtonStyle(accent: Graphite.blue))
                        .disabled(pending == nil)
                    Text("next click anywhere saves that spot")
                        .font(.system(size: 10))
                        .foregroundColor(Graphite.text3)
                }
                Spacer()
            }
        }
        .padding(10)
        .background(Graphite.bg)
        .onDisappear { disarmManual() }
    }

    private func begin() {
        guard let name = pending, countdown == nil else { return }
        tick(3, name)
    }

    private func tick(_ n: Int, _ name: String) {
        countdown = n
        if n == 0 {
            let p = CGEvent(source: nil)?.location ?? .zero
            controller.saveTarget(name, p)
            onSaved?(name)
            countdown = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick(n - 1, name) }
    }

    // MARK: Manual capture (no countdown)

    /// Manual mode: the next click ANYWHERE outside this app saves the cursor
    /// position under the selected target. Global monitors only see clicks in
    /// OTHER applications, so the arming button itself can never capture.
    private func armManual() {
        guard pending != nil, !armedManual else { return }
        armedManual = true
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            guard armedManual, let name = pending else { return }
            let p = CGEvent(source: nil)?.location ?? .zero
            disarmManual()
            controller.saveTarget(name, p)
            onSaved?(name)
        }
    }

    private func disarmManual() {
        armedManual = false
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }
}

// MARK: - Standalone capture buttons (Targets section)

/// Capture controls for a named target: 3-second countdown or "next click
/// anywhere" manual capture. Used by the Targets section inspector.
struct TargetCaptureButtons: View {
    @ObservedObject var controller: DaemonController
    let targetId: String

    @State private var countdown: Int?
    @State private var armedManual = false
    @State private var clickMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            if armedManual {
                Text("click the element in Resolve…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Graphite.amber)
                Button("cancel") { disarmManual() }
                    .buttonStyle(MiniButtonStyle())
            } else if let cd = countdown {
                Text("move the mouse onto “\(controller.config.targetLabel(targetId))” … \(cd)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Graphite.amber)
            } else {
                Button("Capture in 3 s") { beginCountdown() }
                    .buttonStyle(MiniButtonStyle())
                Button("Manual: click the element") { armManual() }
                    .buttonStyle(MiniButtonStyle(accent: Graphite.blue))
                Text("next click anywhere saves that spot")
                    .font(.system(size: 9.5))
                    .foregroundColor(Graphite.text3)
            }
        }
        .onDisappear { disarmManual() }
    }

    private func beginCountdown() {
        guard countdown == nil else { return }
        tick(3)
    }

    private func tick(_ n: Int) {
        countdown = n
        if n == 0 {
            let p = CGEvent(source: nil)?.location ?? .zero
            controller.saveTarget(targetId, p)
            countdown = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick(n - 1) }
    }

    /// Manual mode: the next click ANYWHERE outside this app saves the cursor
    /// position under this target. Global monitors only see clicks in OTHER
    /// applications, so the arming button itself can never capture.
    private func armManual() {
        guard !armedManual else { return }
        armedManual = true
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            guard armedManual else { return }
            let p = CGEvent(source: nil)?.location ?? .zero
            disarmManual()
            controller.saveTarget(targetId, p)
        }
    }

    private func disarmManual() {
        armedManual = false
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }
}
