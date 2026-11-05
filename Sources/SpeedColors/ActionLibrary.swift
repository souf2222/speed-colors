// ActionLibrary.swift — the action catalog (single source of names, icons,
// search aliases) + the task-oriented picker used by BOTH the sidebar column
// and the inline "Add action" popovers, + drop-payload parsing.
//
// Design: task-oriented categories ("what do I want to do?"), compact icon
// rows with a detail area instead of permanent descriptions, Favorites,
// searchable aliases, and advanced primitives tucked into Advanced sections.

import SwiftUI
import UniformTypeIdentifiers
import SpeedColorsCore

// MARK: - Action catalog (single source of names)

enum ActionCatalog {
    struct Item: Identifiable {
        let id: String       // MacroStep.type
        let label: String    // task-oriented name
        let group: String
        let help: String
        var icon: String = "square.dashed"
        var aliases: [String] = []   // extra search terms
        var advanced: Bool = false   // hidden while browsing; searchable w/ badge
    }

    /// Category order: task-oriented first, primitives tucked away.
    static let groupOrder = [
        "Targets & adjustments",
        "Mouse & cursor",
        "Keyboard",
        "Logic & flow",
        "State",
        "Lights",
        "Safety",
    ]

    static let all: [Item] = [
        // Targets & adjustments — the everyday color-grading actions.
        .init(id: "goto",        label: "Move to target",        group: "Targets & adjustments",
              help: "Move the cursor onto a calibrated target (no click)",
              icon: "scope", aliases: ["move", "navigate", "position", "wheel"]),
        .init(id: "clicktarget", label: "Click target",          group: "Targets & adjustments",
              help: "Move to a target and click it (button + click count configurable)",
              icon: "cursorarrow.click", aliases: ["click", "press control"]),
        .init(id: "cycletarget", label: "Cycle targets",         group: "Targets & adjustments",
              help: "Each press moves to the next target in the list (wraps around)",
              icon: "arrow.triangle.2.circlepath", aliases: ["next", "rotate", "cycle"]),
        .init(id: "hold",        label: "Hold to adjust",        group: "Targets & adjustments",
              help: "Hold the mouse button while this hardware key is pressed; turn the dial to adjust. Release is guaranteed by the engine.",
              icon: "slider.horizontal.3", aliases: ["drag", "adjust", "dial", "wheel drag"]),
        .init(id: "sens",        label: "Set dial sensitivity",  group: "Targets & adjustments",
              help: "Fine-tune dial drag speed for the rest of this press (100 = normal)",
              icon: "gauge", aliases: ["precision", "sensitivity", "fine", "speed"]),

        // Mouse & cursor — primitives.
        .init(id: "click",       label: "Click at cursor",       group: "Mouse & cursor",
              help: "Click at the current position (left/right/middle, single/double)",
              icon: "cursorarrow.click.2", aliases: ["click", "press"]),
        .init(id: "dragby",      label: "Drag by amount",        group: "Mouse & cursor",
              help: "One-shot drag from the current position by a pixel offset",
              icon: "hand.draw", aliases: ["drag", "nudge", "swipe"]),
        .init(id: "moveby",      label: "Move cursor",           group: "Mouse & cursor",
              help: "Move the cursor by a pixel offset (relative)",
              icon: "arrow.move", aliases: ["move", "relative", "offset"]),
        .init(id: "scroll",      label: "Scroll",                group: "Mouse & cursor",
              help: "Scroll wheel lines (negative = down)",
              icon: "arrow.up.arrow.down", aliases: ["wheel", "list"]),
        .init(id: "savepos",     label: "Save cursor position",  group: "Mouse & cursor",
              help: "Remember the current cursor position (restore it later)",
              icon: "square.and.arrow.down", aliases: ["remember", "park"]),
        .init(id: "restorepos",  label: "Restore cursor position", group: "Mouse & cursor",
              help: "Move back to the last saved cursor position",
              icon: "arrow.uturn.backward", aliases: ["return", "recall", "park"]),
        .init(id: "mousedown",   label: "Mouse down",            group: "Mouse & cursor",
              help: "Press a mouse button without releasing (advanced — prefer Hold to adjust)",
              icon: "computermouse", aliases: ["press", "button down"], advanced: true),
        .init(id: "mouseup",     label: "Mouse up",              group: "Mouse & cursor",
              help: "Release a mouse button (advanced — prefer Hold to adjust)",
              icon: "computermouse", aliases: ["release", "button up"], advanced: true),

        // Keyboard.
        .init(id: "key",         label: "Press shortcut",        group: "Keyboard",
              help: "Tap a keyboard shortcut (⌘/⌥/⇧/⌃ + key) — click the card to capture",
              icon: "keyboard", aliases: ["hotkey", "shortcut", "combo", "keypress"]),
        .init(id: "keydown",     label: "Key down",              group: "Keyboard",
              help: "Hold a key down until a matching Key up (advanced)",
              icon: "keyboard", aliases: ["hotkey", "hold key"], advanced: true),
        .init(id: "keyup",       label: "Key up",                group: "Keyboard",
              help: "Release a held key (advanced)",
              icon: "keyboard", aliases: ["release key"], advanced: true),

        // Logic & flow — Home-Assistant-style building blocks.
        .init(id: "if",          label: "If / Else",             group: "Logic & flow",
              help: "Run one list of actions when a condition is true, another when false",
              icon: "arrow.triangle.branch", aliases: ["branch", "condition", "palette branch", "if else"]),
        .init(id: "choose",      label: "Choose / Switch",       group: "Logic & flow",
              help: "Switch on a condition: options evaluated top to bottom, first match runs, otherwise Default",
              icon: "arrow.triangle.swap", aliases: ["switch", "case", "branch", "palette", "by current palette"]),
        .init(id: "sequence",    label: "Sequence",              group: "Logic & flow",
              help: "Group actions under a name (pure organization — runs top to bottom)",
              icon: "list.bullet", aliases: ["group", "folder"]),
        .init(id: "repeat",      label: "Repeat",                group: "Logic & flow",
              help: "Run its child actions a fixed number of times (max 50)",
              icon: "arrow.clockwise", aliases: ["loop", "times", "again"]),
        .init(id: "wait",        label: "Delay",                 group: "Logic & flow",
              help: "Pause between steps (ms, max 2000)",
              icon: "timer", aliases: ["wait", "pause", "sleep"]),
        .init(id: "stop",        label: "Stop sequence",         group: "Logic & flow",
              help: "End the whole sequence immediately, with an optional explanation",
              icon: "stop.fill", aliases: ["break", "end", "abort", "cancel"]),

        // State.
        .init(id: "palette",     label: "Set palette state",     group: "State",
              help: "Update the palette state SpeedColors remembers (lights the tagged key). Naming a state is NOT navigating Resolve — pair it with Click target for that.",
              icon: "paintpalette", aliases: ["hdr", "primaries", "state", "remember", "tag"]),
        .init(id: "ensure",      label: "Ensure palette",        group: "State",
              help: "Make sure Resolve shows this palette before continuing: skips if verified on screen, otherwise clicks the palette's tab (idempotent opener)",
              icon: "checkmark.seal", aliases: ["open palette", "resync", "idempotent", "safe"]),

        // Lights — manual panel-light control.
        .init(id: "lighton",    label: "Turn on light",     group: "Lights",
              help: "Light a key's LED (any page). Put the matching Turn off in the release sequence, or drive lights continuously with indicators in Settings.",
              icon: "lightbulb", aliases: ["led", "light", "beacon", "indicator"]),
        .init(id: "lightoff",   label: "Turn off light",    group: "Lights",
              help: "Extinguish a key's LED (any page)",
              icon: "lightbulb.slash", aliases: ["led", "light", "beacon", "indicator"]),
        .init(id: "lighttoggle", label: "Toggle light",     group: "Lights",
              help: "Flip a key's LED on/off — handy for press/release pairs",
              icon: "circle.lefthalf.filled", aliases: ["led", "light", "beacon", "switch"]),

        // Safety.
        .init(id: "releaseall",  label: "Release all held inputs", group: "Safety",
              help: "Release everything SpeedColors holds: mouse button, keys, sensitivity",
              icon: "hand.raised.slash", aliases: ["release", "safety", "panic", "unstick"]),
    ]

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
        case "palette":     return .setTag("HDR")
        case "ensure":      return MacroStep(type: "ensure", tag: "HDR", target2: "auto")
        case "lighton":     return MacroStep(type: "lighton", tag: "cam1")
        case "lightoff":    return MacroStep(type: "lightoff", tag: "cam1")
        case "lighttoggle": return MacroStep(type: "lighttoggle", tag: "cam1")
        // Logic blocks arrive with one ready-made child so the editor shows
        // the nested structure immediately; everything is editable after.
        // If/Else arrives EMPTY too: no placeholder condition or THEN row —
        // you pick the condition (Edit on the "When …" heading) and fill the
        // branches yourself. The daemon safely no-ops an unconfigured If.
        case "if":          return MacroStep(type: "if", expr: nil, children: [], children2: [])
        // Choose/Switch arrives EMPTY: you add your own branches (the guide
        // shows "Otherwise" + Add branch; the empty-state warning marks it
        // incomplete until you do). No pre-filled HDR/goto placeholder.
        case "choose":      return .choose([], default: [])
        case "sequence":    return .sequence([], name: "New sequence")
        case "repeat":      return .repeatBlock(3, [.click()])
        case "stop":        return .stop(nil)
        case "wait":        return .wait(200)
        default:            return MacroStep(type: type)
        }
    }

    /// Search across label, aliases, and help text.
    static func matches(_ item: Item, query q: String) -> Bool {
        if q.isEmpty { return true }
        let ql = q.lowercased()
        if item.label.lowercased().contains(ql) { return true }
        if item.aliases.contains(where: { $0.contains(ql) }) { return true }
        return item.help.lowercased().contains(ql)
    }
}

// MARK: - Drop parsing

enum ActionDrop {
    /// Payload kinds: a library action ("action:<type>"), a dragged hardware
    /// key ("key:<id>", used to swap bindings), or an existing action node
    /// ("node:<base64 JSON>") moved around the tree.
    enum Payload {
        case action(String)
        case key(String)
        case node(MacroStep)
    }

    /// Drag source for an existing node (whole subtree travels in the payload).
    static func dragProvider(_ node: MacroStep) -> NSItemProvider {
        let data = (try? JSONEncoder().encode(node)) ?? Data()
        return NSItemProvider(object: "node:\(data.base64EncodedString())" as NSString)
    }

    /// Parse a dropped NSItemProvider payload and hand the discriminated
    /// payload to `then` on the main thread. Node payloads are self-contained
    /// (the whole subtree serializes along), so a cancelled drag mutates
    /// nothing — the tree only changes when the drop is accepted.
    static func payload(from provider: NSItemProvider,
                        then: @escaping (Payload?) -> Void) -> Bool {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            let text = obj as? String
            var parsed: Payload?
            if let t = text {
                if t.hasPrefix("action:") {
                    parsed = .action(String(t.dropFirst("action:".count)))
                } else if t.hasPrefix("key:") {
                    parsed = .key(String(t.dropFirst("key:".count)))
                } else if t.hasPrefix("node:") {
                    let b64 = String(t.dropFirst("node:".count))
                    if let data = Data(base64Encoded: b64),
                       let node = try? JSONDecoder().decode(MacroStep.self, from: data) {
                        parsed = .node(node)
                    }
                }
            }
            let p = parsed
            DispatchQueue.main.async { then(p) }
        }
        return true
    }

    /// Parse a dropped NSItemProvider payload ("action:<type>") into a step.
    static func step(from provider: NSItemProvider,
                     defaultTarget: String?,
                     then: @escaping (MacroStep?) -> Void) -> Bool {
        _ = payload(from: provider) { p in
            guard case .action(let type) = p else { then(nil); return }
            then(ActionCatalog.newStep(forType: type, defaultTarget: defaultTarget))
        }
        return true
    }
}

// MARK: - Picker row (shared by sidebar and inline popovers)

/// One compact row: icon · label · [ADV] · ☆ · ⠿. Click = select (detail
/// below), + = insert, double-click = insert, drag = classic drag & drop.
struct ActionPickerRow: View {
    @EnvironmentObject var controller: DaemonController
    let item: ActionCatalog.Item
    let selected: Bool
    let onSelect: () -> Void
    let onInsert: () -> Void

    @State private var hovered = false

    private var favorite: Bool { controller.isFavoriteAction(item.id) }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: item.icon)
                .font(.system(size: 11))
                .foregroundColor(selected ? HWColor.selection : Graphite.text3)
                .frame(width: 16)
            Text(item.label)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundColor(labelColor)
                .lineLimit(1)
            if item.advanced {
                Text("ADV")
                    .font(.system(size: 7.5, weight: .bold).monospaced())
                    .foregroundColor(Graphite.text3)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Graphite.border.opacity(0.35)))
            }
            Spacer(minLength: 4)
            if hovered || favorite {
                Button {
                    controller.toggleFavoriteAction(item.id)
                } label: {
                    Image(systemName: favorite ? "star.fill" : "star")
                        .font(.system(size: 10))
                        .foregroundColor(favorite ? Graphite.amber : Graphite.text3)
                }
                .buttonStyle(.plain)
                .help(favorite ? "Remove from Favorites" : "Add to Favorites")
            }
            if hovered || selected {
                Button {
                    onInsert()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(HWColor.selection)
                }
                .buttonStyle(.plain)
                .help("Insert here")
            }
            if hovered {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Graphite.text3.opacity(0.8))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(selected ? HWColor.selection.opacity(0.14)
                          : hovered ? Graphite.hover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onTapGesture(count: 2) { onInsert() }
        .onDrag { NSItemProvider(object: "action:\(item.id)" as NSString) }
        .onHover { hovered = $0 }
        .help("\(item.label) — \(item.help)")
    }

    private var labelColor: Color {
        selected ? HWColor.selection : Graphite.text
    }
}

// MARK: - Picker body (search + groups + favorites + detail)

/// The scrollable picker body shared by the sidebar column and the inline
/// "Add action" popover. Query replaces the category tree with grouped
/// results; advanced items surface in search with an ADV badge.
struct ActionPickerBody: View {
    @EnvironmentObject var controller: DaemonController
    @Binding var query: String
    @Binding var selectedId: String?
    @Binding var collapsed: Set<String>
    var onInsert: ((MacroStep) -> Void)? = nil

    private var favorites: [ActionCatalog.Item] {
        controller.config.favoriteActions.compactMap { id in ActionCatalog.item(forType: id) }
    }

    private var groups: [(String, [ActionCatalog.Item])] {
        let items = ActionCatalog.all.filter { ActionCatalog.matches($0, query: query) }
        var out: [(String, [ActionCatalog.Item])] = []
        // Browsing: hide advanced items (they surface via search).
        let visible = query.isEmpty ? items.filter { !$0.advanced } : items
        for g in ActionCatalog.groupOrder {
            let inGroup = visible.filter { $0.group == g }
            if !inGroup.isEmpty { out.append((g, inGroup)) }
        }
        return out
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                if !favorites.isEmpty && query.isEmpty {
                    groupHeader("Favorites", systemImage: "star.fill")
                    if !collapsed.contains("Favorites") {
                        ForEach(favorites) { item in
                            ActionPickerRow(item: item,
                                            selected: selectedId == item.id,
                                            onSelect: { selectedId = item.id },
                                            onInsert: { insert(item) })
                        }
                    }
                }
                ForEach(groups, id: \.0) { group, items in
                    groupHeader(group, systemImage: nil)
                    if !collapsed.contains(group) || !query.isEmpty {
                        ForEach(items) { item in
                            ActionPickerRow(item: item,
                                            selected: selectedId == item.id,
                                            onSelect: { selectedId = item.id },
                                            onInsert: { insert(item) })
                        }
                    }
                }
                if groups.isEmpty && favorites.isEmpty {
                    Text("no match")
                        .font(.system(size: 11))
                        .foregroundColor(Graphite.text3)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private func groupHeader(_ title: String, systemImage: String?) -> some View {
        Button {
            if collapsed.contains(title) {
                collapsed.remove(title)
            } else {
                collapsed.insert(title)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: collapsed.contains(title) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Graphite.text3)
                    .frame(width: 10)
                if let sf = systemImage {
                    Image(systemName: sf)
                        .font(.system(size: 8.5))
                        .foregroundColor(Graphite.amber)
                }
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(Graphite.text3)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 5)
    }

    private func insert(_ item: ActionCatalog.Item) {
        let target = controller.config.targets.keys.sorted().first
        let node = ActionCatalog.newStep(forType: item.id, defaultTarget: target)
        if let onInsert {
            onInsert(node)
        } else {
            controller.insertFromLibrary(node)
        }
    }
}

// MARK: - Sidebar library column

struct ActionLibrary: View {
    @EnvironmentObject var controller: DaemonController
    @State private var query = ""
    @State private var selectedId: String?
    @State private var collapsed: Set<String> = []

    private var selectedItem: ActionCatalog.Item? {
        selectedId.flatMap { ActionCatalog.item(forType: $0) }
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
                Menu {
                    Button("Expand all") { collapsed = [] }
                    Button("Collapse all") {
                        collapsed = Set(ActionCatalog.groupOrder)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Graphite.text3)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
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
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Graphite.text3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Graphite.control))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Graphite.border, lineWidth: 1))
            .padding(.horizontal, 10)

            ActionPickerBody(query: $query, selectedId: $selectedId, collapsed: $collapsed)
                .frame(maxHeight: .infinity)

            // Detail area — one description at a time, no permanent clutter.
            VStack(alignment: .leading, spacing: 3) {
                if let item = selectedItem {
                    Text(item.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Graphite.text)
                    Text(item.help)
                        .font(.system(size: 10))
                        .foregroundColor(Graphite.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Drag into a sequence, click + to insert, or double-click.")
                        .font(.system(size: 9.5))
                        .foregroundColor(Graphite.text3)
                } else {
                    Text("Click an action for details.")
                        .font(.system(size: 10))
                        .foregroundColor(Graphite.text3)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Graphite.bg.opacity(0.6))
        }
        .frame(maxHeight: .infinity)
        .background(Graphite.panel)
    }
}

// MARK: - Inline picker popover ("Add action" with a resolved destination)

/// The same picker, opened from an inline "+ Add action" button with the
/// destination already resolved ("Add action to: When pressed › If › Then").
struct ActionPickerPopover: View {
    @EnvironmentObject var controller: DaemonController
    let destinationPath: String
    let onAdd: (MacroStep) -> Void

    @State private var query = ""
    @State private var selectedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "plus.square.dashed")
                    .font(.system(size: 10))
                    .foregroundColor(HWColor.selection)
                Text("Add action to:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Graphite.text2)
                Text(destinationPath)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(HWColor.selection)
                    .lineLimit(1)
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
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Graphite.control))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Graphite.border, lineWidth: 1))
            .padding(.horizontal, 10)

            ActionPickerBody(query: $query, selectedId: $selectedId, collapsed: .constant([]), onInsert: onAdd)
                .frame(width: 300, height: 380)

            HStack {
                if let item = selectedId.flatMap({ ActionCatalog.item(forType: $0) }) {
                    Text(item.help)
                        .font(.system(size: 10))
                        .foregroundColor(Graphite.text2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Click an action for details · double-click inserts")
                        .font(.system(size: 10))
                        .foregroundColor(Graphite.text3)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}
