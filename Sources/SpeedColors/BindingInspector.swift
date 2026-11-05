// BindingInspector.swift — the persistent inspector of the Controls section.
//
// Selecting any hardware control (button or dial) shows its editor here —
// clicking another control updates the pane in place, there is no dialog.
// The sequence editor is a TREE, Home-Assistant-style: ordinary actions are
// cards; logic blocks (If/Else, Choose, Sequence, Repeat) contain their own
// nested action lists. Drag & drop works across the whole tree; every card
// has a grip (drag), chevron (expand/collapse), summary, warning, and an
// overflow menu (move/duplicate/disable/delete).

import SwiftUI
import UniformTypeIdentifiers
import SpeedColorsCore

// MARK: - Router

struct BindingInspectorPane: View {
    @EnvironmentObject var controller: DaemonController

    var body: some View {
        Group {
            switch controller.selectedControl {
            case .none:
                EmptyState(icon: "hand.point.up.left",
                           title: "Select a control",
                           detail: "Click a button or the dial in the layout to edit what it does on the Color page.")
            case .key(let key):
                // Fresh identity per key: @State can never carry one key's
                // drafts/labels into another key's editor (the "settings copy"
                // bug), and no onChange closure can fire with a stale key.
                KeyInspector(controller: controller, key: key)
                    .id(key.id)
            case .dial:
                DialInspector(controller: controller)
                    .id("dial")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Graphite.bg)
    }
}

// MARK: - Button inspector

struct KeyInspector: View {
    @ObservedObject var controller: DaemonController
    let key: SpeedEditorKey

    @State private var nameDraft = ""
    @State private var labelDraft = ""
    @State private var labelFromBindingDraft = false
    @State private var enabled = true
    @State private var nameSaveWork: DispatchWorkItem?
    @State private var labelSaveWork: DispatchWorkItem?
    @State private var showReleased = false
    @State private var pressedExpanded = true
    @State private var releasedExpanded = false

    private var keyId: String { key.id }
    private var isDialModeKey: Bool { key == .shtl || key == .jog || key == .scrl }
    private var pressedSteps: [MacroStep] { controller.config.bindings[keyId] ?? [] }
    private var releasedSteps: [MacroStep] { controller.config.released[keyId] ?? [] }
    private var hasBinding: Bool { !pressedSteps.isEmpty || !releasedSteps.isEmpty }
    private var disabledBinding: Bool { controller.config.disabledBindings.contains(keyId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Graphite.border)
            if isDialModeKey {
                DialModeInspector(controller: controller, modeKey: key)
            } else {
                sequenceEditor
            }
        }
        .onAppear(perform: sync)
        .onChange(of: controller.configRevision) { _ in sync() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(key.label)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Graphite.text)
                Text(keyId)
                    .font(.system(size: 10).monospaced())
                    .foregroundColor(Graphite.text3)
                Spacer()
                if disabledBinding {
                    Pill(color: Graphite.text3, label: "disabled")
                }
            }

            if !isDialModeKey {
                HStack(spacing: 10) {
                    Text("Binding name")
                        .font(.system(size: 11))
                        .foregroundColor(Graphite.text3)
                    GraphiteField(placeholder: "name this binding…", text: $nameDraft)
                        .frame(maxWidth: .infinity)
                        .disabled(!hasBinding)
                        // Only arm the debounced save for USER edits. Programmatic
                        // resets (sync() reloading values on key switch) also
                        // fire onChange — arming those is exactly the "copied
                        // settings" bug.
                        .onChange(of: nameDraft) { _ in
                            let stored = controller.config.bindingNames[keyId] ?? ""
                            if nameDraft != stored {
                                scheduleNameSave()
                            }
                        }
                    Toggle("Enabled", isOn: Binding(
                        get: { enabled },
                        set: { v in
                            enabled = v
                            controller.setBindingEnabled(keyId, v)
                        }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 11))
                        .foregroundColor(Graphite.text2)
                        .disabled(!hasBinding)
                }
            }

            // Key-face text override. Optional: with the checkbox on, the
            // binding name IS the key face; otherwise the custom text (if
            // any) wins, else the hardware legend stays.
            HStack(spacing: 10) {
                Text("Display on key")
                    .font(.system(size: 11))
                    .foregroundColor(Graphite.text3)
                GraphiteField(placeholder: "optional custom text…", text: $labelDraft)
                    .frame(maxWidth: .infinity)
                    .disabled(labelFromBindingDraft)
                    .onChange(of: labelDraft) { _ in
                        let stored = controller.config.keyLabels[keyId] ?? ""
                        if labelDraft != stored {
                            scheduleLabelSave()
                        }
                    }
                Toggle("Name binding", isOn: $labelFromBindingDraft)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .foregroundColor(Graphite.text2)
                    .help("Key face shows the binding name (updates when renamed)")
                    .onChange(of: labelFromBindingDraft) { v in
                        guard v != (controller.config.labelFromBinding[keyId] ?? false)
                        else { return }
                        controller.setKeyLabelFromBinding(keyId, v)
                    }
            }

            if !isDialModeKey {
                if key == .esc {
                    Text("ESC always force-releases an active hold — it is not rebindable on the Color page.")
                        .font(.system(size: 10))
                        .foregroundColor(Graphite.amber.opacity(0.9))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Sequence editor (nested tree)

    private var sequenceEditor: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // WHEN PRESSED — the primary phase.
                    SectionHeaderView(title: "When pressed",
                                      count: pressedSteps.map(\.actionCount).reduce(0, +),
                                      expanded: $pressedExpanded)
                    if pressedExpanded {
                        ActionListEditor(
                            controller: controller,
                            keyId: keyId,
                            phase: .pressed,
                            parentID: "",
                            slot: "root",
                            pathLabel: "When pressed",
                            list: Binding(
                                get: { controller.config.bindings[keyId] ?? [] },
                                set: { controller.setBinding(keyId, phase: .pressed, $0) }),
                            depth: 0,
                            addLabel: "Add action")
                    }

                    // WHEN RELEASED — collapsible; expanded automatically when
                    // the key has release actions the user hasn't seen yet.
                    SectionHeaderView(title: "When released",
                                      count: releasedSteps.map(\.actionCount).reduce(0, +),
                                      expanded: $releasedExpanded)
                        .onAppear {
                            if !releasedSteps.isEmpty { showReleased = true }
                        }
                    if releasedExpanded {
                        ActionListEditor(
                            controller: controller,
                            keyId: keyId,
                            phase: .released,
                            parentID: "",
                            slot: "root",
                            pathLabel: "When released",
                            list: Binding(
                                get: { controller.config.released[keyId] ?? [] },
                                set: { controller.setBinding(keyId, phase: .released, $0) }),
                            depth: 0,
                            addLabel: "Add release action")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: .infinity)

            footer
        }
        .onChange(of: showReleased) { on in
            if on { releasedExpanded = true }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()

            Button("Clear Binding", role: .destructive) {
                controller.clearBinding(forKeyId: keyId)
            }
            .buttonStyle(MiniButtonStyle(danger: true))
            .disabled(!hasBinding)

            Button("Test") {
                controller.testSequence(pressedSteps)
            }
            .buttonStyle(GraphiteButtonStyle(accent: Graphite.blue))
            .disabled(pressedSteps.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Drafts & saves (names/labels only — steps edit through the tree)

    private func sync() {
        nameDraft = controller.config.bindingNames[keyId] ?? ""
        labelDraft = controller.config.keyLabels[keyId] ?? ""
        labelFromBindingDraft = controller.config.labelFromBinding[keyId] ?? false
        enabled = !disabledBinding
    }

    private func scheduleNameSave() {
        nameSaveWork?.cancel()
        // Snapshot BOTH the key id and the draft: the work item executes 0.5 s
        // later — possibly after the user has already selected another key —
        // so late-binding `keyId`/`nameDraft` would write A's text onto B.
        let scheduledKeyId = keyId
        let draft = nameDraft
        let work = DispatchWorkItem { [weak controller] in
            controller?.setBindingName(scheduledKeyId, draft)
        }
        nameSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func scheduleLabelSave() {
        labelSaveWork?.cancel()
        let scheduledKeyId = keyId
        let draft = labelDraft
        let work = DispatchWorkItem { [weak controller] in
            controller?.setKeyLabel(scheduledKeyId, draft)
        }
        labelSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

// MARK: - Section header (collapsible, with action count)

struct SectionHeaderView: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Graphite.text3)
                    .frame(width: 12)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Graphite.text2)
                Spacer()
                Text(count == 0 ? "No actions"
                                : "\(count) action\(count == 1 ? "" : "s")")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(count == 0 ? Graphite.text3 : Graphite.cyan)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Action list editor (one nested child list)

/// Renders one child list (root, THEN, an option, or a sequence body): its
/// cards and a drop zone. The permanent "+ Add action" lives only at the END
/// of the main sequence; inside branches the + appears on hover (and always
/// when the branch is empty).
struct ActionListEditor: View {
    @ObservedObject var controller: DaemonController
    let keyId: String
    let phase: BindingPhase
    let parentID: String     // "" = phase root list
    let slot: String         // "root" | "then" | "else" | "children" | "default" | "option:<id>"
    let pathLabel: String    // human path for the picker header ("When pressed › Choose › Then")
    @Binding var list: [MacroStep]
    let depth: Int
    let addLabel: String

    @State private var dropActive = false
    @State private var pickerOpen = false
    @State private var hovered = false

    /// Branch lists (depth > 0) reveal the add button on hover only.
    private var compactAdd: Bool { depth > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(list.indices, id: \.self) { i in
                if i < list.count {
                    ActionCard(controller: controller,
                               node: childBinding(i),
                               keyId: keyId,
                               phase: phase,
                               parentID: parentID,
                               slot: slot,
                               index: i,
                               depth: depth,
                               pathLabel: pathLabel)
                }
            }
            .onChange(of: list.count) { _ in }  // keep identity stable

            if !compactAdd || hovered || list.isEmpty {
                Button {
                    pickerOpen = true
                } label: {
                    Label(list.isEmpty ? "Add action" : "Add action",
                          systemImage: "plus")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Graphite.text3)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .padding(.vertical, 2)
                .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                    ActionPickerPopover(destinationPath: pathLabel) { node in
                        controller.insertNode(node, keyId: keyId, phase: phase,
                                              parentID: parentID, slot: slot,
                                              index: list.count)
                    }
                }
            }
        }
        .padding(.leading, CGFloat(16))
        .overlay(alignment: .leading) {
            // Thin branch guide — hierarchy from alignment, not borders.
            Rectangle()
                .fill(Graphite.border.opacity(0.45))
                .frame(width: 1)
                .padding(.leading, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(HWColor.selection.opacity(dropActive ? 0.10 : 0))
        )
        .contentShape(Rectangle())
        .onHover { h in
            hovered = h
            if h {
                controller.setPendingInsert(keyId: keyId, phase: phase,
                                            parentID: parentID, slot: slot,
                                            path: pathLabel)
            }
        }
        .onDrop(of: [UTType.plainText], isTargeted: $dropActive) { providers in
            handleDrop(providers, index: list.count)
        }
    }

    /// Accepts library actions and moved nodes. `index` = insertion point.
    func handleDrop(_ providers: [NSItemProvider], index: Int) -> Bool {
        guard let provider = providers.first else { return false }
        return ActionDrop.payload(from: provider) { p in
            switch p {
            case .action(let type):
                let target = controller.config.targets.keys.sorted().first
                controller.insertNode(ActionCatalog.newStep(forType: type, defaultTarget: target),
                                      keyId: keyId, phase: phase,
                                      parentID: parentID, slot: slot, index: index)
            case .node(let n):
                guard n.id != nil else { return }
                if parentID.isEmpty {
                    controller.moveNode(id: n.id!, keyId: keyId,
                                        toParentID: "", toSlot: "root", toIndex: index)
                } else {
                    controller.moveNode(id: n.id!, keyId: keyId,
                                        toParentID: parentID, toSlot: slot, toIndex: index)
                }
            case .key, nil:
                break
            }
        }
    }

    private func childBinding(_ i: Int) -> Binding<MacroStep> {
        Binding(
            get: { list.indices.contains(i) ? list[i] : MacroStep(type: "wait", ms: 0) },
            set: { if list.indices.contains(i) { list[i] = $0 } })
    }
}

// MARK: - Action card (sentence-style rows)

/// Leaf actions = ONE always-visible editable line:
///   ⠿  Move to  [Lift › Color balance ▾]        ⋯
/// Logic blocks = a heading line + a light branch guide with readable
/// headings ("When tracked palette is HDR", "Otherwise") and an anchored
/// condition editor on demand. No borders, counts, or repeated chevrons.
struct ActionCard: View {
    @ObservedObject var controller: DaemonController
    @Binding var node: MacroStep
    let keyId: String
    let phase: BindingPhase
    let parentID: String
    let slot: String
    let index: Int
    let depth: Int
    let pathLabel: String

    @State private var hovered = false
    @State private var dropHover = false
    @State private var editingCond = false
    @State private var editOptionIndex: Int? = nil
    @State private var condDraft: MacroExpr = .group(.all, [])

    // Test highlighting maps through the flattened leaf order.
    private var leafIndex: Int? {
        guard let id = node.id else { return nil }
        return controller.testLeafIds.firstIndex(of: id)
    }
    private var testActive: Bool {
        guard let li = leafIndex else { return false }
        return controller.testStepIndex == li
    }
    private var testError: String? {
        guard let li = leafIndex else { return nil }
        return controller.testErrors[li]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if node.isContainer {
                containerHeader
                containerBody
            } else {
                leafRow
            }
            if let err = testError {
                Text("✕ \(err)")
                    .font(.system(size: 10))
                    .foregroundColor(Graphite.red)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(rowBackground)
        // Insertion line: exactly where the drop will land.
        .overlay(alignment: .bottom) {
            if dropHover {
                Rectangle()
                    .fill(HWColor.selection)
                    .frame(height: 2)
                    .offset(y: 1)
            }
        }
        .onHover { hovered = $0 }
        .onDrop(of: [UTType.plainText], isTargeted: $dropHover) { providers in
            handleDrop(providers, index: index + 1)
        }
        .popover(isPresented: $editingCond, arrowEdge: .bottom) {
            ConditionEditorPopover(
                controller: controller,
                draft: $condDraft,
                onDone: {
                    if let oi = editOptionIndex {
                        optionExprBinding(oi).wrappedValue = condDraft
                    } else {
                        node.expr = condDraft
                    }
                    editingCond = false
                },
                onCancel: { editingCond = false })
        }
    }

    private var rowBackground: Color {
        if testActive { return Graphite.amber.opacity(0.14) }
        if dropHover { return HWColor.selection.opacity(0.08) }
        if hovered { return Graphite.control.opacity(0.45) }
        if node.off == true { return Graphite.control.opacity(0.18) }
        return Color.clear
    }

    // MARK: Grip & menu

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(Graphite.text3.opacity(hovered ? 1 : 0.45))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onDrag { ActionDrop.dragProvider(node) }
            .help("Drag to move (into branches, between sections, or onto a hardware key)")
    }

    private var overflowMenu: some View {
        Menu {
            Button("Move up") { controller.moveNodeBy(id: node.id ?? "", keyId: keyId, offset: -1) }
                .disabled(index == 0)
            Button("Move down") { controller.moveNodeBy(id: node.id ?? "", keyId: keyId, offset: +1) }
            Button("Duplicate") { controller.duplicateNode(id: node.id ?? "", keyId: keyId) }
            Button(node.off == true ? "Enable" : "Disable") {
                controller.setNodeDisabled(node.off != true, id: node.id ?? "", keyId: keyId)
            }
            Divider()
            Button("Delete", role: .destructive) {
                controller.deleteNode(id: node.id ?? "", keyId: keyId)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Graphite.text3.opacity(hovered ? 1 : 0.55))
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .help("Move, duplicate, disable, delete")
    }

    // MARK: Leaf row (one line, always editable)

    private var leafRow: some View {
        HStack(spacing: 6) {
            grip
            Text(leafTitle)
                .font(.system(size: 13))
                .foregroundColor(node.off == true ? Graphite.text3 : Graphite.text)
                .frame(minWidth: 88, alignment: .leading)
                .lineLimit(1)
                .help(leafHelp)
            settings
            Spacer(minLength: 4)
            if let w = warning, node.type != "goto", node.type != "clicktarget" {
                // goto/clicktarget show their warning beside the selector.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(Graphite.amber)
                    .help(w)
            }
            overflowMenu
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    /// Compact task words for the row's fixed column.
    private var leafTitle: String {
        switch node.type {
        case "goto": return "Move to"
        case "clicktarget": return "Click"
        case "cycletarget": return "Cycle targets"
        case "hold": return "Hold to adjust"
        case "sens": return "Sensitivity"
        case "click": return "Click"
        case "mousedown": return "Mouse down"
        case "mouseup": return "Mouse up"
        case "dragby": return "Drag by"
        case "moveby": return "Move by"
        case "scroll": return "Scroll"
        case "savepos": return "Save cursor position"
        case "restorepos": return "Restore cursor position"
        case "key": return "Press"
        case "keydown": return "Key down"
        case "keyup": return "Key up"
        case "palette": return "Set palette"
        case "ensure": return "Ensure palette"
        case "lighton": return "Light on"
        case "lightoff": return "Light off"
        case "lighttoggle": return "Toggle light"
        case "releaseall": return "Release all held inputs"
        case "stop": return "Stop sequence"
        case "wait": return "Delay"
        default: return ActionCatalog.label(for: node)
        }
    }

    private var leafHelp: String {
        ActionCatalog.item(forType: node.type)?.help ?? node.describe(labels: { controller.config.targetLabel($0) })
    }

    private var warning: String? {
        switch node.type {
        case "goto", "clicktarget":
            if let t = node.target, controller.config.targets[t] == nil {
                return controller.config.isKnownTarget(t)
                    ? "Target '\(controller.config.targetLabel(t))' is not calibrated"
                    : "Target unavailable — select a replacement"
            }
            return nil
        case "key", "keydown", "keyup":
            return node.keyCode == nil ? "No key captured yet" : nil
        default:
            return nil
        }
    }

    // MARK: Container header & branch guide

    private var containerTitle: String {
        switch node.type {
        case "choose": return node.name?.isEmpty == false ? node.name! : "Choose"
        case "if": return "If / Else"
        case "sequence": return node.name?.isEmpty == false ? node.name! : "Sequence"
        case "repeat": return "Repeat ×\(node.count ?? 2)"
        default: return node.describe(labels: { controller.config.targetLabel($0) })
        }
    }

    private var containerHeader: some View {
        HStack(spacing: 6) {
            grip
            Text(containerTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(node.off == true ? Graphite.text3 : Graphite.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            overflowMenu
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    /// One light guide: readable branch headings + aligned child lists.
    private var containerBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            if node.type == "if" {
                branchHeading(condHeading(node.expr), tone: HWColor.selection,
                              editable: true) { openCondEditor(nil) }
                ActionListEditor(controller: controller, keyId: keyId, phase: phase,
                                 parentID: node.id ?? "", slot: "then",
                                 pathLabel: "\(pathLabel) › Then",
                                 list: Binding(get: { node.children ?? [] },
                                               set: { node.children = $0 }),
                                 depth: depth + 1, addLabel: "Add action")
                branchHeading("Otherwise", tone: Graphite.text2, editable: false, onEdit: {})
                ActionListEditor(controller: controller, keyId: keyId, phase: phase,
                                 parentID: node.id ?? "", slot: "else",
                                 pathLabel: "\(pathLabel) › Else",
                                 list: Binding(get: { node.children2 ?? [] },
                                               set: { node.children2 = $0 }),
                                 depth: depth + 1, addLabel: "Add action")
            } else if node.type == "choose" {
                ForEach(Array((node.options ?? []).enumerated()), id: \.element.id) { oi, opt in
                    HStack(spacing: 4) {
                        branchHeading(condHeading(opt.expr), tone: HWColor.selection,
                                      editable: true) { openCondEditor(oi) }
                        if let err = opt.expr.validate() {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8.5))
                                .foregroundColor(Graphite.amber)
                                .help(err)
                        }
                    }
                    ActionListEditor(controller: controller, keyId: keyId, phase: phase,
                                     parentID: node.id ?? "", slot: "option:\(opt.id)",
                                     pathLabel: "\(pathLabel) › Option \(oi + 1)",
                                     list: optionListBinding(oi),
                                     depth: depth + 1, addLabel: "Add action")
                }
                branchHeading("Otherwise", tone: Graphite.text2, editable: false, onEdit: {})
                ActionListEditor(controller: controller, keyId: keyId, phase: phase,
                                 parentID: node.id ?? "", slot: "default",
                                 pathLabel: "\(pathLabel) › Default",
                                 list: Binding(get: { node.children ?? [] },
                                               set: { node.children = $0 }),
                                 depth: depth + 1, addLabel: "Add action")
                Button {
                    node.options = (node.options ?? []) + [ChooseOption(
                        expr: .group(.all, [.cond(MacroCond(
                            kind: .palette,
                            value: ActionCard.knownTags(controller).first ?? "HDR"))]))]
                } label: {
                    Label("Add branch", systemImage: "plus")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Graphite.text3)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            } else if node.type == "repeat" {
                branchHeading("Do", tone: Graphite.text2, editable: false, onEdit: {})
                ActionListEditor(controller: controller, keyId: keyId, phase: phase,
                                 parentID: node.id ?? "", slot: "children",
                                 pathLabel: "\(pathLabel) › Repeat",
                                 list: Binding(get: { node.children ?? [] },
                                               set: { node.children = $0 }),
                                 depth: depth + 1, addLabel: "Add action")
            } else {
                ActionListEditor(controller: controller, keyId: keyId, phase: phase,
                                 parentID: node.id ?? "", slot: "children",
                                 pathLabel: "\(pathLabel) › Sequence",
                                 list: Binding(get: { node.children ?? [] },
                                               set: { node.children = $0 }),
                                 depth: depth + 1, addLabel: "Add action")
            }
        }
        .padding(.leading, 16)
        .padding(.bottom, 3)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Graphite.border.opacity(0.4))
                .frame(width: 1)
                .padding(.leading, 6)
        }
    }

    private func condHeading(_ e: MacroExpr?) -> String {
        guard let e else { return "When …" }
        return "When " + e.summary()
    }

    private func branchHeading(_ text: String, tone: Color, editable: Bool,
                               onEdit: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(Graphite.text3)
            Text(text)
                .font(.system(size: 11.5, weight: editable ? .semibold : .medium))
                .foregroundColor(tone)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if editable {
                Button("Edit") { onEdit() }
                    .font(.system(size: 10))
                    .foregroundColor(HWColor.selection)
                    .buttonStyle(.plain)
                    .opacity(hovered || (node.type == "if" && node.expr == nil) ? 1 : 0.6)
                    .help("Edit this condition")
            }
            Spacer(minLength: 4)
        }
    }

    private func openCondEditor(_ optionIndex: Int?) {
        if let oi = optionIndex {
            let opts = node.options ?? []
            condDraft = opts.indices.contains(oi) ? opts[oi].expr : .group(.all, [])
        } else {
            condDraft = node.expr ?? .group(.all, [])
        }
        editOptionIndex = optionIndex
        editingCond = true
    }

    // MARK: Leaf settings (inline, compact)

    @ViewBuilder
    private var settings: some View {
        switch node.type {
        case "goto":
            TargetMenuButton(controller: controller, step: $node)
        case "clicktarget":
            HStack(spacing: 5) {
                TargetMenuButton(controller: controller, step: $node)
                Menu {
                    ForEach(MouseController.HWButton.allCases, id: \.rawValue) { b in
                        Button(buttonLabel(b)) { node.button = b.rawValue }
                    }
                } label: {
                    menuChip(buttonLabel(MouseController.HWButton(rawValue: node.button ?? 0) ?? .left))
                }
                .controlSize(.mini)
                .fixedSize()
            }
        case "click":
            HStack(spacing: 5) {
                Menu {
                    ForEach(MouseController.HWButton.allCases, id: \.rawValue) { b in
                        Button(buttonLabel(b)) { node.button = b.rawValue }
                    }
                } label: {
                    menuChip(buttonLabel(MouseController.HWButton(rawValue: node.button ?? 0) ?? .left))
                }
                .controlSize(.mini)
                .fixedSize()
                Picker("", selection: Binding(
                    get: { node.count ?? 1 },
                    set: { node.count = $0 })) {
                    Text("single").tag(1)
                    Text("double").tag(2)
                    Text("triple").tag(3)
                }
                .controlSize(.mini)
                .pickerStyle(.segmented)
            }
        case "cycletarget":
            TargetMenuButton(controller: controller, step: $node)
        case "mousedown", "mouseup":
            Menu {
                ForEach(MouseController.HWButton.allCases, id: \.rawValue) { b in
                    Button(buttonLabel(b)) { node.button = b.rawValue }
                }
            } label: {
                menuChip(buttonLabel(MouseController.HWButton(rawValue: node.button ?? 0) ?? .left))
            }
            .controlSize(.mini)
            .fixedSize()
        case "moveby", "dragby":
            HStack(spacing: 4) {
                TextField("x", value: Binding(get: { node.dx ?? 0 }, set: { node.dx = $0 }),
                          formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 48)
                TextField("y", value: Binding(get: { node.dy ?? 0 }, set: { node.dy = $0 }),
                          formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 48)
                Text("px").font(.system(size: 10)).foregroundColor(Graphite.text3)
            }
        case "scroll":
            HStack(spacing: 4) {
                TextField("lines", value: Binding(get: { node.dy ?? 3 }, set: { node.dy = $0 }),
                          formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 48)
                Text("lines").font(.system(size: 10)).foregroundColor(Graphite.text3)
            }
        case "sens":
            HStack(spacing: 4) {
                TextField("%", value: Binding(
                    get: { node.ms ?? 100 },
                    set: { node.ms = max(1, min($0, 1000)) }), formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 48)
                Text("% speed").font(.system(size: 10)).foregroundColor(Graphite.text3)
            }
        case "palette":
            TextField("HDR", text: Binding(
                get: { node.tag ?? "" },
                set: { node.tag = $0 }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 88)
        case "ensure":
            HStack(spacing: 4) {
                Menu {
                    ForEach(Self.knownTags(controller), id: \.self) { t in
                        Button("“\(t)”") { node.tag = t }
                    }
                } label: {
                    menuChip("“\(node.tag ?? "?")”")
                }
                .controlSize(.mini)
                .fixedSize()
                Menu {
                    Button("Automatic") { node.target2 = "auto" }
                    Button("Left (main strip)") { node.target2 = "left" }
                    Button("Right (second panel)") { node.target2 = "right" }
                } label: {
                    menuChip(node.target2.flatMap { $0.isEmpty ? nil : $0 } ?? "auto")
                }
                .controlSize(.mini)
                .fixedSize()
                .help("Automatic clicks the palette's calibrated tab. Explicit slots need per-panel calibration — not yet available.")
            }
        case "key":
            KeyCaptureButton(step: $node)
        case "wait":
            HStack(spacing: 4) {
                TextField("ms", value: Binding(
                    get: { node.ms ?? 200 },
                    set: { node.ms = max(0, min($0, 2000)) }), formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 52)
                Text("ms").font(.system(size: 10)).foregroundColor(Graphite.text3)
            }
        case "lighton", "lightoff", "lighttoggle":
            Menu {
                ForEach(SpeedEditorKey.allCases.filter { $0.led != nil }, id: \.self) { k in
                    Button(k.label) { node.tag = k.id }
                }
            } label: {
                menuChip(node.tag.flatMap { id in
                    SpeedEditorKey.allCases.first { $0.id == id }?.label
                } ?? "key…")
            }
            .controlSize(.mini)
            .fixedSize()
            .help("Only the 18 backlit keys can light (CAM1–9, LIVE O/WR, VIDEO ONLY, AUDIO ONLY, CLOSE UP, CUT, DIS, SMTH CUT, TRANS, SNAP)")
        case "stop":
            TextField("optional reason…", text: Binding(
                get: { node.tag ?? "" },
                set: { node.tag = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 140)
        default:
            EmptyView()
        }
    }

    // MARK: Option bindings

    private func optionListBinding(_ i: Int) -> Binding<[MacroStep]> {
        Binding(
            get: {
                let opts = node.options ?? []
                return opts.indices.contains(i) ? opts[i].actions : []
            },
            set: {
                var opts = node.options ?? []
                if opts.indices.contains(i) {
                    opts[i].actions = $0
                    node.options = opts
                }
            })
    }

    private func optionExprBinding(_ i: Int) -> Binding<MacroExpr> {
        Binding(
            get: {
                let opts = node.options ?? []
                return opts.indices.contains(i) ? opts[i].expr : .group(.all, [])
            },
            set: {
                var opts = node.options ?? []
                if opts.indices.contains(i) {
                    opts[i].expr = $0
                    node.options = opts
                }
            })
    }

    // MARK: Drops

    func handleDrop(_ providers: [NSItemProvider], index: Int) -> Bool {
        guard let provider = providers.first else { return false }
        return ActionDrop.payload(from: provider) { p in
            switch p {
            case .action(let type):
                let target = controller.config.targets.keys.sorted().first
                controller.insertNode(ActionCatalog.newStep(forType: type, defaultTarget: target),
                                      keyId: keyId, phase: phase,
                                      parentID: parentID, slot: slot, index: index)
            case .node(let n):
                guard let nid = n.id, nid != node.id else { return }
                controller.moveNode(id: nid, keyId: keyId,
                                    toParentID: parentID, toSlot: slot, toIndex: index)
            case .key, nil:
                break
            }
        }
    }

    // MARK: Shared helpers

    /// Palette names used anywhere in the config (leaf "palette" steps and
    /// condition expressions) — the value menu for conditions.
    static func knownTags(_ controller: DaemonController) -> [String] {
        var found: Set<String> = ["HDR"]

        func walk(_ list: [MacroStep]) {
            for n in list {
                if n.type == "palette", let t = n.tag, !t.isEmpty { found.insert(t) }
                n.expr?.collectPaletteValues(into: &found)
                walk(n.children ?? [])
                walk(n.children2 ?? [])
                for o in n.options ?? [] {
                    o.expr.collectPaletteValues(into: &found)
                    walk(o.actions)
                }
            }
        }
        for v in controller.config.bindings.values { walk(v) }
        for v in controller.config.released.values { walk(v) }
        return found.sorted()
    }

    private func menuChip(_ text: String) -> some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 10.5))
                .foregroundColor(Graphite.text)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 6.5, weight: .semibold))
                .foregroundColor(Graphite.text2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(Graphite.control))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Graphite.border, lineWidth: 1))
    }

    private func buttonLabel(_ b: MouseController.HWButton) -> String {
        switch b {
        case .left: return "left"
        case .right: return "right"
        case .middle: return "middle"
        }
    }
}

// MARK: - Condition editor popover (edit on demand)

/// The readable branch heading opens this anchored editor: the full AND/OR
/// builder with Cancel/Done. Changes apply only on Done.
struct ConditionEditorPopover: View {
    @ObservedObject var controller: DaemonController
    @Binding var draft: MacroExpr
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EDIT CONDITIONS")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Graphite.text3)
            ConditionGroupEditor(controller: controller, group: $draft, depth: 0)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(MiniButtonStyle())
                Button("Done") { onDone() }
                    .buttonStyle(GraphiteButtonStyle(accent: Graphite.blue))
            }
        }
        .padding(10)
        .frame(width: 460)
    }
}

// MARK: - Condition builder (recursive AND/OR groups)

/// Recursive condition editor: a group shows its AND/OR selector, its
/// children (comparison rows and/or nested groups), and add-controls.
/// Nested groups get a bordered box + indent so grouping stays unambiguous —
/// no flat "A OR B AND C" ambiguity.
struct ConditionGroupEditor: View {
    @ObservedObject var controller: DaemonController
    @Binding var group: MacroExpr   // always .group (normalized at load)
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Group header: the single source of the AND/OR operator.
            HStack(spacing: 5) {
                if depth > 0 {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Graphite.text3)
                }
                Text(depth == 0 ? "Match" : "Match")
                    .font(.system(size: 10))
                    .foregroundColor(Graphite.text3)
                opMenu
                Spacer(minLength: 4)
                if depth > 0 {
                    Menu {
                        Button("Duplicate group") { onDuplicateGroup?() }
                        Button("Delete group", role: .destructive) { onDeleteGroup?() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Graphite.text3)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .controlSize(.small)
                }
            }

            ForEach(childrenArr.indices, id: \.self) { i in
                if i < childrenArr.count {
                    childView(i)
                    if i < childrenArr.count - 1 {
                        // Visual reminder of the operator between rows —
                        // controlled at the group level, never per-row.
                        HStack(spacing: 0) {
                            Text(opBinding.wrappedValue.joiner.uppercased())
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                .foregroundColor(HWColor.selection)
                                .frame(width: 44, alignment: .leading)
                            Spacer()
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    childrenBinding.wrappedValue.append(
                        .cond(MacroCond(kind: .palette, value: ActionCard.knownTags(controller).first ?? "HDR")))
                } label: {
                    Label("Add condition", systemImage: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Graphite.text2)
                }
                .buttonStyle(.plain)
                Button {
                    childrenBinding.wrappedValue.append(.group(.all, [
                        .cond(MacroCond(kind: .palette, value: ActionCard.knownTags(controller).first ?? "HDR"))]))
                } label: {
                    Label("Add group", systemImage: "plus.square.on.square")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Graphite.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, depth == 0 ? 0 : 4)
        .padding(.horizontal, depth == 0 ? 0 : 7)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(depth == 0 ? Color.clear : Graphite.control.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(depth == 0 ? Color.clear : Graphite.border.opacity(0.8), lineWidth: 1))
        .padding(.leading, depth == 0 ? 0 : 8)
    }

    // Hooks injected by the parent builder so nested groups can delete
    // themselves (the binding chain reaches the owning array).
    var onDuplicateGroup: (() -> Void)? = nil
    var onDeleteGroup: (() -> Void)? = nil

    private var childrenArr: [MacroExpr] {
        if case .group(_, let kids) = group { return kids }
        return []
    }

    private var opBinding: Binding<CondGroupOp> {
        Binding(
            get: {
                if case .group(let op, _) = group { return op }
                return .all
            },
            set: {
                if case .group(_, let kids) = group { group = .group($0, kids) }
            })
    }

    private var childrenBinding: Binding<[MacroExpr]> {
        Binding(
            get: { childrenArr },
            set: {
                if case .group(let op, _) = group { group = .group(op, $0) }
            })
    }

    private func childBinding(_ i: Int) -> Binding<MacroExpr> {
        Binding(
            get: { childrenArr.indices.contains(i) ? childrenArr[i] : .group(.all, []) },
            set: {
                var kids = childrenArr
                if kids.indices.contains(i) {
                    kids[i] = $0
                    childrenBinding.wrappedValue = kids
                }
            })
    }

    @ViewBuilder
    private func childView(_ i: Int) -> some View {
        switch childrenArr[i] {
        case .cond:
            ConditionRow(controller: controller,
                         cond: condChildBinding(i),
                         knownTags: ActionCard.knownTags(controller),
                         onRemove: {
                             var kids = childrenArr
                             guard kids.indices.contains(i) else { return }
                             kids.remove(at: i)
                             childrenBinding.wrappedValue = kids
                         },
                         onDuplicate: {
                             var kids = childrenArr
                             guard kids.indices.contains(i) else { return }
                             var c = kids[i]
                             if case .cond(let cc) = c {
                                 c = .cond(MacroCond(kind: cc.kind, op: cc.op, value: cc.value, values: cc.values))
                             }
                             kids.insert(c, at: i + 1)
                             childrenBinding.wrappedValue = kids
                         },
                         onMove: { offset in
                             let j = i + offset
                             var kids = childrenArr
                             guard kids.indices.contains(i), kids.indices.contains(j) else { return }
                             kids.swapAt(i, j)
                             childrenBinding.wrappedValue = kids
                         })
        case .group:
            ConditionGroupEditor(controller: controller,
                                 group: childBinding(i),
                                 depth: depth + 1,
                                 onDuplicateGroup: {
                                     var kids = childrenArr
                                     guard kids.indices.contains(i),
                                           let dup = try? JSONDecoder().decode(MacroExpr.self,
                                                                               from: try JSONEncoder().encode(kids[i])) else { return }
                                     // Fresh ids aren't needed for conditions.
                                     kids.insert(dup, at: i + 1)
                                     childrenBinding.wrappedValue = kids
                                 },
                                 onDeleteGroup: {
                                     var kids = childrenArr
                                     guard kids.indices.contains(i) else { return }
                                     kids.remove(at: i)
                                     childrenBinding.wrappedValue = kids
                                 })
        }
    }

    private func condChildBinding(_ i: Int) -> Binding<MacroCond> {
        Binding(
            get: {
                if case .cond(let c) = childrenArr.indices.contains(i) ? childrenArr[i] : .group(.all, []) {
                    return c
                }
                return MacroCond(kind: .palette)
            },
            set: {
                var kids = childrenArr
                if kids.indices.contains(i) {
                    kids[i] = .cond($0)
                    childrenBinding.wrappedValue = kids
                }
            })
    }

    private var opMenu: some View {
        Menu {
            ForEach(CondGroupOp.allCases, id: \.self) { op in
                Button(op.label) { opBinding.wrappedValue = op }
            }
        } label: {
            HStack(spacing: 4) {
                Text(opBinding.wrappedValue.label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(HWColor.selection)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(Graphite.text2)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Graphite.control))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Graphite.border, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .help("AND: every condition must match · OR: at least one")
    }
}

/// One comparison row: [Property ▾] [Operator ▾] [Value] ⋯
struct ConditionRow: View {
    @ObservedObject var controller: DaemonController
    @Binding var cond: MacroCond
    let knownTags: [String]
    var onRemove: () -> Void
    var onDuplicate: () -> Void
    var onMove: (Int) -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            kindMenu
            opMenu
            valueEditor
            Spacer(minLength: 2)
            Menu {
                Button("Move up") { onMove(-1) }
                Button("Move down") { onMove(+1) }
                Button("Duplicate") { onDuplicate() }
                Divider()
                Button("Delete condition", role: .destructive) { onRemove() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Graphite.text3.opacity(hovered ? 1 : 0.6))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .help("Move, duplicate, delete condition")
        }
        .onHover { hovered = $0 }
    }

    private var kindMenu: some View {
        Menu {
            ForEach(MacroCondKind.allCases, id: \.self) { k in
                Button(k.label) {
                    cond = MacroCond(kind: k)  // resets op + value to kind defaults
                }
            }
        } label: {
            menuChip(cond.kind.label)
        }
        .controlSize(.mini)
        .fixedSize()
    }

    private var opMenu: some View {
        Menu {
            ForEach(cond.kind.ops, id: \.self) { op in
                Button(op.rawValue) { cond.op = op }
            }
        } label: {
            menuChip(cond.op.rawValue)
        }
        .controlSize(.mini)
        .fixedSize()
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch cond.kind {
        case .palette:
            if cond.op == .isOneOf || cond.op == .isNotOneOf {
                // Compact multi-select: chips + add menu (equivalent to ORs).
                HStack(spacing: 3) {
                    ForEach(cond.values ?? [], id: \.self) { v in
                        HStack(spacing: 3) {
                            Text(v).font(.system(size: 10.5))
                            Button {
                                cond.values = (cond.values ?? []).filter { $0 != v }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundColor(Graphite.text3)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Graphite.control))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Graphite.border, lineWidth: 1))
                    }
                    Menu {
                        ForEach(knownTags, id: \.self) { t in
                            Button("“\(t)”") {
                                var vs = cond.values ?? []
                                if !vs.contains(t) { vs.append(t) }
                                cond.values = vs
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Graphite.text2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Graphite.control))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Graphite.border, lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .controlSize(.mini)
                }
            } else {
                Menu {
                    ForEach(knownTags, id: \.self) { t in
                        Button("“\(t)”") { cond.value = t }
                    }
                } label: {
                    menuChip("“\(cond.value.isEmpty ? "?" : cond.value)”", highlight: true)
                }
                .controlSize(.mini)
                .fixedSize()
            }
        case .paletteVisible:
            Menu {
                ForEach(knownTags, id: \.self) { t in
                    Button("“\(t)”") { cond.value = t }
                }
            } label: {
                menuChip("“\(cond.value.isEmpty ? "?" : cond.value)”", highlight: true)
            }
            .controlSize(.mini)
            .fixedSize()
            .help("Checks every visible palette slot (split workspaces included)")
        case .paletteConfidence, .layout, .page:
            let choices = MacroCond.valueChoices(kind: cond.kind, tags: knownTags, profiles: controller.config.profileNames)
            Menu {
                ForEach(choices, id: \.self) { c in
                    Button(c) { cond.value = c }
                }
            } label: {
                menuChip("“\(cond.value.isEmpty ? "?" : cond.value)”", highlight: true)
            }
            .controlSize(.mini)
            .fixedSize()
        case .profile:
            Menu {
                ForEach(controller.config.profileNames, id: \.self) { p in
                    Button(p) { cond.value = p }
                }
            } label: {
                menuChip("“\(cond.value.isEmpty ? "?" : cond.value)”", highlight: true)
            }
            .controlSize(.mini)
            .fixedSize()
        case .dialMode:
            Menu {
                ForEach([SpeedEditorKey.shtl, .jog, .scrl], id: \.self) { k in
                    Button(k.label) { cond.value = k.label }
                }
            } label: {
                menuChip("“\(cond.value.isEmpty ? "?" : cond.value)”", highlight: true)
            }
            .controlSize(.mini)
            .fixedSize()
        case .targetCalibrated:
            Menu {
                ForEach(controller.config.targets.keys.sorted(), id: \.self) { id in
                    Button(controller.config.targetLabel(id)) { cond.value = id }
                }
            } label: {
                menuChip(cond.value.isEmpty ? "target…" : controller.config.targetLabel(cond.value), highlight: true)
            }
            .controlSize(.mini)
            .fixedSize()
        case .keyHeld:
            Menu {
                ForEach(SpeedEditorKey.allCases.filter { $0 != .none }, id: \.self) { k in
                    Button(k.label) { cond.value = k.id }
                }
            } label: {
                menuChip(cond.value.isEmpty ? "key…" : ColorModeConfig.label(forKeyId: cond.value), highlight: true)
            }
            .controlSize(.mini)
            .fixedSize()
        case .deviceConnected:
            Text("—")
                .font(.system(size: 10.5))
                .foregroundColor(Graphite.text3)
        }
    }

    private func menuChip(_ text: String, highlight: Bool = false) -> some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 10.5))
                .foregroundColor(highlight ? HWColor.selection : Graphite.text)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 6.5, weight: .semibold))
                .foregroundColor(Graphite.text2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Graphite.control))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Graphite.border, lineWidth: 1))
    }
}

// MARK: - Target menu (goto rows)

/// Target selector for a "Go to target" step: catalog label + searchable
/// picker popover with the calibrate-with-mouse flow built in.
struct TargetMenuButton: View {
    @ObservedObject var controller: DaemonController
    @Binding var step: MacroStep
    @State private var pickerOpen = false

    /// Readable name for the current reference — or nil when the target
    /// can't be resolved at all (deleted/unknown id): never show raw IDs.
    private var resolvedName: String? {
        guard let id = step.target else { return nil }
        if id.isEmpty { return nil }
        // Known = catalog entry or custom (renamable) target.
        guard controller.config.isKnownTarget(id) else { return nil }
        return controller.config.targetLabel(id)
    }

    /// True when the reference points at a calibrated position.
    private var calibrated: Bool {
        guard let id = step.target else { return false }
        return controller.config.targets[id] != nil
    }

    var body: some View {
        HStack(spacing: 5) {
            Button {
                pickerOpen = true
            } label: {
                HStack(spacing: 5) {
                    Text(resolvedName ?? "Target unavailable — select a replacement")
                        .font(.system(size: 11.5))
                        .foregroundColor(resolvedName == nil ? Graphite.red : Graphite.text)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundColor(Graphite.text2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Graphite.control))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(resolvedName == nil ? Graphite.red.opacity(0.6) : Graphite.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                TargetCalibrator(
                    controller: controller,
                    onSelectOnly: { id in step.target = id })
                    .frame(width: 330)
            }
            if resolvedName != nil && !calibrated {
                Text("(uncalibrated)")
                    .font(.system(size: 9.5))
                    .foregroundColor(Graphite.amber)
            }
        }
    }
}

// MARK: - Dial inspector (the dial graphic control)

struct DialInspector: View {
    @ObservedObject var controller: DaemonController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SEARCH DIAL")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Graphite.text)
                Text("Drag behavior while a Color-page hold is active")
                    .font(.system(size: 11))
                    .foregroundColor(Graphite.text3)
            }

            HStack(spacing: 6) {
                Text("Current state")
                    .font(.system(size: 12))
                    .foregroundColor(Graphite.text2)
                Text(controller.dialState)
                    .font(.system(size: 11).monospaced())
                    .foregroundColor(controller.dialState.contains("dragging") ? Graphite.amber : Graphite.cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Graphite.control))
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Drag")
                slider("Drag px / unit", Binding(
                    get: { controller.config.pixelsPerUnit },
                    set: { controller.config.pixelsPerUnit = $0; controller.scheduleConfigSave() }),
                       0.002...0.08, format: "%.3f")
                slider("Drag release idle (s)", Binding(
                    get: { controller.config.dragReleaseIdle },
                    set: { controller.config.dragReleaseIdle = $0; controller.scheduleConfigSave() }),
                       0.1...2.0, format: "%.2f")
            }

            Text("Sensitivity per dial mode lives on the SHTL / JOG / SCRL buttons.")
                .font(.system(size: 10))
                .foregroundColor(Graphite.text3)
            Spacer()
        }
        .padding(14)
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 12)).foregroundColor(Graphite.text)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(Graphite.cyan)
            }
            Slider(value: value, in: range).controlSize(.mini)
        }
    }
}

// MARK: - SHTL / JOG / SCRL inspector

struct DialModeInspector: View {
    @ObservedObject var controller: DaemonController
    let modeKey: SpeedEditorKey

    private var modeId: String { modeKey.id }

    private var current: Int? {
        controller.config.dialSensitivity[modeId]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(modeKey.label) — dial mode")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Graphite.text)
                Text("Selects the search-dial sensitivity; not a mappable button.")
                    .font(.system(size: 11))
                    .foregroundColor(Graphite.text3)
            }

            HStack(spacing: 6) {
                Text("Current state")
                    .font(.system(size: 12))
                    .foregroundColor(Graphite.text2)
                Text(controller.dialState)
                    .font(.system(size: 11).monospaced())
                    .foregroundColor(controller.dialState.hasPrefix(modeKey.label) ? Graphite.amber : Graphite.cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Graphite.control))
            }

            FieldRow(label: "Sensitivity") {
                sensitivityMenu
            }

            Text("Jog units per arrow (non-Color pages) is a global default — see Settings.")
                .font(.system(size: 10))
                .foregroundColor(Graphite.text3)
            Spacer()
        }
        .padding(14)
    }

    private var sensitivityMenu: some View {
        Menu {
            Button("Profile default") { controller.setDialSensitivity(modeId, nil) }
            Divider()
            ForEach(1...12, id: \.self) { v in
                Button("×\(v)") { controller.setDialSensitivity(modeId, v) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(current.map { "×\($0)" } ?? "Profile default")
                    .font(.system(size: 12))
                    .foregroundColor(Graphite.text)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundColor(Graphite.text2)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(Graphite.control))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Graphite.border, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
