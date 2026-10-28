// ActionLibrary.swift — the canonical action catalog (identical names in the
// library, inspector menus, action rows, and diagnostics) + the searchable,
// draggable library column of the Controls section.

import SwiftUI
import UniformTypeIdentifiers
import SpeedColorsCore

// MARK: - Action catalog (single source of names)

enum ActionCatalog {
    struct Item: Identifiable {
        let id: String       // MacroStep.type
        let label: String    // canonical name
        let group: String
        let help: String
    }

    static let all: [Item] = [
        .init(id: "goto",  label: "Go to target",  group: "Cursor",   help: "Park the cursor on a calibrated target"),
        .init(id: "click", label: "Click",         group: "Cursor",   help: "Full mouse click at the current position"),
        .init(id: "hold",  label: "Hold (dial drags)", group: "Cursor", help: "Press the mouse down until the SE key is released; the search dial drags"),
        .init(id: "key",   label: "Press key",     group: "Keyboard", help: "Inject a keyboard shortcut into Resolve"),
        .init(id: "wait",  label: "Wait",          group: "Workflow", help: "Pause between steps (ms)"),
    ]

    /// Canonical label for a step's type (unknown types pass through).
    static func label(forType type: String) -> String {
        all.first { $0.id == type }?.label ?? type
    }

    static func label(for step: MacroStep) -> String { label(forType: step.type) }

    static func item(forType type: String) -> Item? {
        all.first { $0.id == type }
    }

    /// A fresh step for an action id (defaults; refined in the inspector).
    static func newStep(forType type: String, defaultTarget: String?) -> MacroStep {
        switch type {
        case "goto":  return .goto(defaultTarget ?? "wheel_1_color")
        case "click": return .click()
        case "hold":  return .hold()
        case "key":   return MacroStep(type: "key")
        case "wait":  return .wait(200)
        default:      return MacroStep(type: type)
        }
    }
}

// MARK: - Library panel

struct ActionLibrary: View {
    @EnvironmentObject var controller: DaemonController
    @State private var query = ""

    private var groups: [(String, [ActionCatalog.Item])] {
        let q = query.lowercased()
        let items = ActionCatalog.all.filter {
            q.isEmpty || $0.label.lowercased().contains(q) || $0.help.lowercased().contains(q)
        }
        var order: [String] = []
        var byGroup: [String: [ActionCatalog.Item]] = [:]
        for i in items {
            if byGroup[i.group] == nil { order.append(i.group) }
            byGroup[i.group, default: []].append(i)
        }
        return order.map { ($0, byGroup[$0]!) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 10))
                    .foregroundColor(Graphite.text3)
                Text("ACTION LIBRARY")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Graphite.text3)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Graphite.text3)
                TextField("Search actions…", text: $query)
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
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(groups, id: \.0) { group, items in
                        SectionTitle(title: group)
                            .padding(.top, 4)
                        ForEach(items) { item in
                            ActionLibraryRow(item: item)
                        }
                    }
                    if groups.isEmpty {
                        Text("no match")
                            .font(.system(size: 11))
                            .foregroundColor(Graphite.text3)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Graphite.panel)
    }
}

/// A draggable action entry. Dropping onto a hardware control creates a
/// binding; dropping onto the inspector's sequence inserts a step.
struct ActionLibraryRow: View {
    let item: ActionCatalog.Item
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Graphite.text)
                .lineLimit(1)
            Text(item.help)
                .font(.system(size: 9.5))
                .foregroundColor(Graphite.text3)
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovered ? Graphite.hover : Graphite.control.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Graphite.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onDrag {
            NSItemProvider(object: "action:\(item.id)" as NSString)
        }
        .help("\(item.help) — drag onto a control or into a sequence")
    }
}

// MARK: - Drop parsing

enum ActionDrop {
    /// Parse a dropped NSItemProvider payload ("action:<type>") into a step.
    static func step(from provider: NSItemProvider,
                     defaultTarget: String?,
                     then: @escaping (MacroStep?) -> Void) -> Bool {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            let text = obj as? String
            guard let t = text, t.hasPrefix("action:") else {
                DispatchQueue.main.async { then(nil) }
                return
            }
            let type = String(t.dropFirst("action:".count))
            let step = ActionCatalog.newStep(forType: type, defaultTarget: defaultTarget)
            DispatchQueue.main.async { then(step) }
        }
        return true
    }
}
