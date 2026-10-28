// BindingInspector.swift — the persistent inspector of the Controls section.
//
// Selecting any hardware control (button or dial) shows its editor here —
// clicking another control updates the pane in place, there is no dialog.
// Button inspector = name + enabled toggle, "When pressed" and "When
// released" sequences, action rows (grip · # · type · settings · ×), Add
// action, and Test with live step highlighting and per-step failures.

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
                KeyInspector(controller: controller, key: key)
            case .dial:
                DialInspector(controller: controller)
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

    @State private var draftPressed: [MacroStep] = []
    @State private var draftReleased: [MacroStep] = []
    @State private var nameDraft = ""
    @State private var enabled = true
    @State private var nameSaveWork: DispatchWorkItem?
    @State private var showReleased = false

    private var keyId: String { key.id }
    private var isDialModeKey: Bool { key == .shtl || key == .jog || key == .scrl }
    private var hasBinding: Bool { !draftPressed.isEmpty || !draftReleased.isEmpty }
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
        .onChange(of: controller.selectedControl) { _ in sync() }
        .onChange(of: controller.configRevision) { _ in sync() }
        .onChange(of: controller.config.bindings[keyId]) { _ in
            // External change (paste/clear via context menu) → reload drafts.
            sync()
        }
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
                    Text("Name")
                        .font(.system(size: 11))
                        .foregroundColor(Graphite.text3)
                    GraphiteField(placeholder: "binding name…", text: $nameDraft)
                        .frame(maxWidth: .infinity)
                        .disabled(!hasBinding)
                        .onChange(of: nameDraft) { _ in scheduleNameSave() }
                    Toggle("Enabled", isOn: $enabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 11))
                        .foregroundColor(Graphite.text2)
                        .disabled(!hasBinding)
                        .onChange(of: enabled) { v in controller.setBindingEnabled(keyId, v) }
                }

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

    // MARK: Sequence editor

    private var sequenceEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("WHEN PRESSED") {
                    if draftPressed.isEmpty {
                        Text(draftReleased.isEmpty
                             ? "Unassigned — drag an action from the library onto the button, or use Add action."
                             : "No press actions — the button only acts on release.")
                            .font(.system(size: 11))
                            .foregroundColor(Graphite.text3)
                    }
                    ForEach(draftPressed.indices, id: \.self) { i in
                        ActionRow(controller: controller,
                                  step: binding(for: i, in: $draftPressed, commit: commitPressed),
                                  index: i,
                                  phase: "pressed",
                                  active: controller.testStepIndex == i,
                                  error: controller.testErrors[i],
                                  onRemove: {
                                      draftPressed.remove(at: i)
                                      commitPressed()
                                  },
                                  onInsertAfter: { new in
                                      draftPressed.insert(new, at: min(i + 1, draftPressed.count))
                                      commitPressed()
                                  })
                    }
                    .onMove { src, dst in
                        draftPressed.move(fromOffsets: src, toOffset: dst)
                        commitPressed()
                    }
                    .onDelete { offsets in
                        draftPressed.remove(atOffsets: offsets)
                        commitPressed()
                    }
                }

                Section {
                    if showReleased || !draftReleased.isEmpty {
                        if draftReleased.isEmpty {
                            Text("No release actions — add one to run steps when the key is released.")
                                .font(.system(size: 11))
                                .foregroundColor(Graphite.text3)
                        }
                        ForEach(draftReleased.indices, id: \.self) { i in
                            ActionRow(controller: controller,
                                      step: binding(for: i, in: $draftReleased, commit: commitReleased),
                                      index: i,
                                      phase: "released",
                                      active: false,
                                      error: nil,
                                      onRemove: {
                                          draftReleased.remove(at: i)
                                          commitReleased()
                                      },
                                      onInsertAfter: { new in
                                          draftReleased.insert(new, at: min(i + 1, draftReleased.count))
                                          commitReleased()
                                      })
                        }
                        .onMove { src, dst in
                            draftReleased.move(fromOffsets: src, toOffset: dst)
                            commitReleased()
                        }
                        .onDelete { offsets in
                            draftReleased.remove(atOffsets: offsets)
                            commitReleased()
                        }
                    } else {
                        Button {
                            showReleased = true
                        } label: {
                            Label("When released", systemImage: "chevron.down")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Graphite.text2)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("WHEN RELEASED")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)

            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(ActionCatalog.all) { item in
                    Button(item.label) {
                        appendAction(item.id)
                    }
                }
            } label: {
                Label("Add action", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Graphite.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Graphite.control))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Graphite.border, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.vertical, -5)

            Spacer()

            Button("Clear Binding", role: .destructive) {
                controller.clearBinding(forKeyId: keyId)
            }
            .buttonStyle(MiniButtonStyle(danger: true))
            .disabled(!hasBinding)

            Button("Test") {
                controller.testSequence(draftPressed)
            }
            .buttonStyle(GraphiteButtonStyle(accent: Graphite.blue))
            .disabled(draftPressed.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Drafts & commits

    private func sync() {
        draftPressed = controller.config.bindings[keyId] ?? []
        draftReleased = controller.config.released[keyId] ?? []
        nameDraft = controller.config.bindingNames[keyId] ?? ""
        enabled = !disabledBinding
        showReleased = !draftReleased.isEmpty
    }

    private func commitPressed() {
        controller.setBinding(keyId, phase: .pressed, draftPressed)
    }

    private func commitReleased() {
        controller.setBinding(keyId, phase: .released, draftReleased)
    }

    private func appendAction(_ typeId: String) {
        let target = controller.config.targets.keys.sorted().first
        draftPressed.append(ActionCatalog.newStep(forType: typeId, defaultTarget: target))
        commitPressed()
    }

    private func scheduleNameSave() {
        nameSaveWork?.cancel()
        let work = DispatchWorkItem { [weak controller] in
            controller?.setBindingName(keyId, nameDraft)
        }
        nameSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func binding(for i: Int,
                         in draft: Binding<[MacroStep]>,
                         commit: @escaping () -> Void) -> Binding<MacroStep> {
        Binding(
            get: { draft.wrappedValue.indices.contains(i) ? draft.wrappedValue[i] : MacroStep(type: "click") },
            set: {
                if draft.wrappedValue.indices.contains(i) {
                    draft.wrappedValue[i] = $0
                    commit()
                }
            })
    }
}

// MARK: - Action row

/// `grip · # · action type · settings · remove` — identical structure for
/// every action type; only the settings area changes.
struct ActionRow: View {
    @ObservedObject var controller: DaemonController
    @Binding var step: MacroStep
    let index: Int
    let phase: String       // "pressed" | "released"
    let active: Bool
    let error: String?
    let onRemove: () -> Void
    let onInsertAfter: (MacroStep) -> Void

    @State private var hovered = false

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Graphite.text3)
                    .help("Drag to reorder")
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundColor(Graphite.text2)
                    .frame(width: 14)
                Text(ActionCatalog.label(for: step))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Graphite.text)
                    .frame(width: 96, alignment: .leading)
                    .lineLimit(1)
                settings
                Spacer(minLength: 2)
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Graphite.text3.opacity(hovered ? 1 : 0.6))
                }
                .buttonStyle(.plain)
                .help("Remove action")
            }
            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(Graphite.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 44)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(rowStroke, lineWidth: active ? 1.5 : 1)
        )
        .onHover { hovered = $0 }
        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
            // Dropping an action onto a row inserts AFTER it.
            let defaultTarget = controller.config.targets.keys.sorted().first
            return ActionDrop.step(from: providers.first ?? NSItemProvider(),
                                   defaultTarget: defaultTarget) { new in
                guard let new else { return }
                onInsertAfter(new)
            }
        }
    }

    private var rowFill: Color {
        if error != nil { return Graphite.red.opacity(0.12) }
        if active { return Graphite.amber.opacity(0.14) }
        if hovered { return Graphite.control.opacity(0.85) }
        return Graphite.control.opacity(0.5)
    }

    private var rowStroke: Color {
        if error != nil { return Graphite.red.opacity(0.7) }
        if active { return Graphite.amber }
        return Graphite.border.opacity(0.6)
    }

    @ViewBuilder
    private var settings: some View {
        switch step.type {
        case "goto":
            HStack(spacing: 5) {
                TargetMenuButton(controller: controller, step: $step)
                if controller.config.targets[step.target ?? ""] == nil {
                    Text("(uncalibrated)")
                        .font(.system(size: 9.5))
                        .foregroundColor(Graphite.amber)
                }
            }
        case "click":
            Text("at current position")
                .font(.system(size: 10))
                .foregroundColor(Graphite.text3)
        case "hold":
            Text(phase == "pressed"
                 ? "mouse down until key release"
                 : "acts as a click on release")
                .font(.system(size: 10))
                .foregroundColor(Graphite.text3)
        case "key":
            KeyCaptureButton(step: $step)
        case "wait":
            HStack(spacing: 4) {
                TextField("ms", value: msBinding, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 56)
                Text("ms")
                    .font(.system(size: 10))
                    .foregroundColor(Graphite.text3)
            }
        default:
            EmptyView()
        }
    }

    private var msBinding: Binding<Int> {
        Binding(
            get: { step.ms ?? 200 },
            set: { step.ms = max(0, min($0, 2000)) })
    }
}

// MARK: - Target menu (goto rows)

/// Target selector for a "Go to target" step: catalog label + searchable
/// picker popover with the calibrate-with-mouse flow built in.
struct TargetMenuButton: View {
    @ObservedObject var controller: DaemonController
    @Binding var step: MacroStep
    @State private var pickerOpen = false

    var body: some View {
        Button {
            pickerOpen = true
        } label: {
            HStack(spacing: 5) {
                Text(step.target.map { controller.config.targetLabel($0) } ?? "target…")
                    .font(.system(size: 11.5))
                    .foregroundColor(Graphite.text)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundColor(Graphite.text2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Graphite.control))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Graphite.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
            TargetCalibrator(
                controller: controller,
                onSelectOnly: { id in step.target = id })
                .frame(width: 330)
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
