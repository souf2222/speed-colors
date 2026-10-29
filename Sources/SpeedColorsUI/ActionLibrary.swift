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

    /// Group order mirrors the intended sidebar: Targets → Mouse → Keyboard →
    /// Dial → Workflow. (Resolve navigation / nodes / playback land here as
    /// verified shortcut-backed actions are added.)
    static let groupOrder = ["Targets", "Mouse", "Keyboard", "Dial", "Workflow"]

    static let all: [Item] = [
        // Targets — friendly composites over goto + click.
        .init(id: "goto",       label: "Go to target",           group: "Targets", help: "Park the cursor on a calibrated target (no click)"),
        .init(id: "clicktarget", label: "Click target",          group: "Targets", help: "Move to a target and click (button + click count configurable)"),
        .init(id: "cycletarget", label: "Cycle targets",         group: "Targets", help: "Each press moves the cursor to the next target in a configured list"),
        .init(id: "savepos",    label: "Save cursor",            group: "Targets", help: "Remember the current cursor position for later restore"),
        .init(id: "restorepos", label: "Restore cursor",         group: "Targets", help: "Return to the previously saved cursor position"),

        // Mouse — reliable building blocks.
        .init(id: "click",    label: "Click at cursor",        group: "Mouse", help: "Click at the current position (left/right/middle, single/double)"),
        .init(id: "hold",     label: "Hold (dial drags)",      group: "Mouse", help: "Press the mouse down until the SE key is released; the search dial drags"),
        .init(id: "mousedown", label: "Mouse down",            group: "Mouse", help: "Press a mouse button without releasing it"),
        .init(id: "mouseup",  label: "Mouse up",               group: "Mouse", help: "Release a pressed mouse button"),
        .init(id: "dragby",   label: "Drag by amount",         group: "Mouse", help: "Press, drag by a configured X/Y offset, release"),
        .init(id: "moveby",   label: "Move cursor relatively", group: "Mouse", help: "Move the cursor by an X/Y offset from where it is"),
        .init(id: "scroll",   label: "Scroll",                 group: "Mouse", help: "Scroll the wheel vertically (positive = up lines)"),

        // Keyboard.
        .init(id: "key",    label: "Press shortcut", group: "Keyboard", help: "Inject a keyboard shortcut into Resolve"),
        .init(id: "keydown", label: "Key down",      group: "Keyboard", help: "Hold a key/combo (pair with Key up in the release phase)"),
        .init(id: "keyup",  label: "Key up",         group: "Keyboard", help: "Release a held key/combo"),

        // Dial — Sensitivity in percent of the mode's normal drag speed.
        .init(id: "sens", label: "Set dial sensitivity", group: "Dial", help: "Dial drag speed in percent (30 = precision; 100 = normal)"),

        // Workflow & safety.
        .init(id: "wait",       label: "Wait",                    group: "Workflow", help: "Pause between steps (ms, max 2000)"),
        .init(id: "releaseall", label: "Release all inputs",      group: "Workflow", help: "Stop everything SpeedColors is holding: mouse button, keys, sensitivity"),
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
        case "goto":        return .goto(defaultTarget ?? "wheel_1_color")
        case "clicktarget": return MacroStep(type: "clicktarget", target: defaultTarget ?? "wheel_1_color")
        case "cycletarget": return MacroStep(type: "cycletarget")
        case "click":       return .click()
        case "hold":        return .hold()
        case "mousedown":   return MacroStep(type: "mousedown")
        case "mouseup":     return MacroStep(type: "mouseup")
        case "dragby":      return MacroStep(type: "dragby", dy: 40)
        case "moveby":      return MacroStep(type: "moveby", dx: 0, dy: 24)
        case "scroll":      return MacroStep(type: "scroll", dy: 3)
        case "savepos":     return MacroStep(type: "savepos")
        case "restorepos":  return MacroStep(type: "restorepos")
        case "key":         return MacroStep(type: "key")
        case "keydown":     return MacroStep(type: "keydown")
        case "keyup":       return MacroStep(type: "keyup")
        case "sens":        return MacroStep(type: "sens", ms: 30)
        case "releaseall":  return MacroStep(type: "releaseall")
        case "wait":        return .wait(200)
        default:            return MacroStep(type: type)
        }
    }
}

// MARK: - Library panel

struct ActionLibrary: View {
    @EnvironmentObject var controller: DaemonController
    @State private var query = ""
    /// Collapsed group headers (search overrides and expands everything).
    @State private var collapsed: Set<String> = []
    /// Row density: compact by default; descriptions appear on hover or here.
    @AppStorage("speedcolors.libDetail") private var detailed = false

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
                Button {
                    detailed.toggle()
                } label: {
                    Image(systemName: detailed ? "list.bullet.rectangle" : "list.bullet")
                        .font(.system(size: 10))
                        .foregroundColor(detailed ? Graphite.cyan : Graphite.text3)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(detailed ? "Hide descriptions" : "Show descriptions")
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
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(groups, id: \.0) { group, items in
                        // Collapsible category header (search expands all).
                        Button {
                            if collapsed.contains(group) {
                                collapsed.remove(group)
                            } else {
                                collapsed.insert(group)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: collapsed.contains(group)
                                    ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(Graphite.text3)
                                    .frame(width: 10)
                                Text(group.uppercased())
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundColor(Graphite.text3)
                                Spacer()
                                Text("\(items.count)")
                                    .font(.system(size: 9).monospaced())
                                    .foregroundColor(Graphite.text3.opacity(0.7))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 5)

                        if !collapsed.contains(group) || !query.isEmpty {
                            ForEach(items) { item in
                                ActionLibraryRow(item: item, detailed: detailed)
                            }
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
/// Compact by default — description appears on hover (or always if the
/// library detail toggle is on).
struct ActionLibraryRow: View {
    let item: ActionCatalog.Item
    let detailed: Bool
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Graphite.text)
                .lineLimit(1)
            if detailed || hovered {
                Text(item.help)
                    .font(.system(size: 9.5))
                    .foregroundColor(Graphite.text3)
                    .lineLimit(detailed ? 2 : 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, detailed ? 6 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovered ? Graphite.hover : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(hovered ? Graphite.border : Color.clear, lineWidth: 1)
        )
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
