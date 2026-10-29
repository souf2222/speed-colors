// ControlsView.swift — the Controls workspace:
//
//   ┌─────────────────────────────────────────────┬─────────────┐
//   │  Device replica — fixed-proportion canvas   │ Action      │
//   │  (scaled uniformly, centered)               │ library     │
//   │  runtime dial status lives here, OFF device │ (collapsible│
//   ├─────────────────────── divider ─────────────┤  resizable) │
//   │  Selected control inspector (scrolls)       │             │
//   └─────────────────────────────────────────────┴─────────────┘

import SwiftUI

struct ControlsView: View {
    @EnvironmentObject var controller: DaemonController

    // (no view-mode switching — the replica is mapping-only)
    @AppStorage("speedcolors.canvasH") private var canvasHeight: Double = 440
    @State private var canvasDragStart: Double?
    @State private var libraryWidth: CGFloat = 236
    @State private var libraryDragStart: CGFloat?
    @State private var libraryCollapsed = false

    /// Dial-mode keys and the dial take sensitivity settings, not bindings —
    /// the action library would be misleading there.
    private var selectionIsNonMappable: Bool {
        switch controller.selectedControl {
        case .key(let key): return key == .shtl || key == .jog || key == .scrl
        case .dial: return true
        case .none: return false
        }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // Canvas pane: the replica scales uniformly to fit; it is
                    // centered, never stretched.
                    DeviceCanvasPlaceholder()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Graphite.bg)
                        .frame(height: clampedCanvasHeight(container: geo.size.height))
                    divider(height: 3)
                        .gesture(dragCanvas(container: geo.size.height))

                    // NOTE: the inspector's List scrolls ITSELF — no outer
                    // ScrollView here. A List nested in a ScrollView collapses
                    // to zero height on macOS (rows invisible).
                    BindingInspectorPane()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Graphite.bg)
                }
                .frame(maxWidth: .infinity)

                divider(width: 3, vertical: true)
                    .gesture(dragLibrary())

                if libraryCollapsed {
                    Button {
                        libraryCollapsed = false
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 10))
                            Image(systemName: "chevron.left")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundColor(Graphite.text3)
                        .frame(width: 26)
                        .frame(maxHeight: .infinity)
                        .background(Graphite.panel)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show action library")
                } else {
                    ZStack {
                        ActionLibrary()
                            .frame(width: libraryWidth)
                            .disabled(selectionIsNonMappable)

                        if selectionIsNonMappable {
                            VStack(spacing: 6) {
                                Image(systemName: "dial.low")
                                    .font(.system(size: 18))
                                    .foregroundColor(Graphite.text3)
                                Text("Dial mode control")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Graphite.text2)
                                Text("Dial keys adjust sensitivity — actions can't be assigned here. Configure them in the inspector below.")
                                    .font(.system(size: 10))
                                    .foregroundColor(Graphite.text3)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 14)
                            }
                            .padding(16)
                            .background(Graphite.panel.opacity(0.94))
                            .frame(width: libraryWidth)
                            .frame(maxHeight: .infinity)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Button {
                            libraryCollapsed = true
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Graphite.text3)
                                .padding(7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Collapse action library")
                    }
                }
            }
        }
    }

    // MARK: Sizing

    private func clampedCanvasHeight(container: CGFloat) -> CGFloat {
        max(240, min(CGFloat(canvasHeight), container - 220))
    }

    private func dragCanvas(container: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if canvasDragStart == nil { canvasDragStart = canvasHeight }
                canvasHeight = Double(max(240, min(canvasDragStart! + v.translation.height,
                                                   container - 220)))
            }
            .onEnded { _ in canvasDragStart = nil }
    }

    private func dragLibrary() -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if libraryDragStart == nil { libraryDragStart = libraryWidth }
                libraryWidth = max(190, min(380, libraryDragStart! - v.translation.width))
            }
            .onEnded { _ in libraryDragStart = nil }
    }

    // MARK: Dividers

    private func divider(height: CGFloat) -> some View {
        Rectangle()
            .fill(Graphite.border)
            .frame(height: height)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 12)
                    .offset(y: -4.5)
                    .contentShape(Rectangle())
            }
            .contentShape(Rectangle())
    }

    private func divider(width: CGFloat, vertical: Bool) -> some View {
        Rectangle()
            .fill(Graphite.border)
            .frame(width: width)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 12)
                    .offset(x: -4.5)
                    .contentShape(Rectangle())
            }
            .contentShape(Rectangle())
    }
}

// MARK: - Canvas pane (toolbar, fit / zoom, status)

/// The preview toolbar sits ABOVE the device: zoom on one side, runtime dial
/// status on the other. Fit shows the whole device; higher zooms pan.
struct DeviceCanvasPlaceholder: View {
    @EnvironmentObject var controller: DaemonController
    @AppStorage("speedcolors.hwZoom") private var zoomIndex: Int = 0

    private var clampedZoom: Int { zoomIndex < 0 ? 0 : (zoomIndex > 3 ? 3 : zoomIndex) }

    private static let zooms: [(label: String, factor: Double)] = [
        ("Fit", 1.0), ("125%", 1.25), ("150%", 1.5), ("200%", 2.0),
    ]

    var body: some View {
        GeometryReader { geo in
            let widthFit = (geo.size.width - 16) / HWCanvas.width
            let heightFit = (geo.size.height - 16 - 38) / HWCanvas.height
            // Whole device always visible at Fit; zoom multiplies and pans.
            let base = min(widthFit, heightFit)
            let s = max(0.18, base * Self.zooms[clampedZoom].factor)
            let overflows = HWCanvas.height * s > geo.size.height - 46
                || HWCanvas.width * s > geo.size.width - 8

            VStack(spacing: 6) {
                toolbar

                if overflows {
                    ScrollView([.horizontal, .vertical]) {
                        DeviceCanvasView(scale: s)
                            .frame(minWidth: geo.size.width - 8,
                                   minHeight: geo.size.height - 50) // center when smaller
                    }
                    .clipShape(Rectangle())
                } else {
                    DeviceCanvasView(scale: s)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    private var currentZoom: String {
        Self.zooms[clampedZoom].label
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Spacer()

            Text(controller.dialState)
                .font(.system(size: 10.5).monospaced())
                .foregroundColor(controller.dialState.lowercased().contains("dragging")
                                 ? Graphite.amber : Graphite.text2)
                .lineLimit(1)

            Menu {
                Button("Fit") { zoomIndex = 0 }
                Button("125%") { zoomIndex = 1 }
                Button("150%") { zoomIndex = 2 }
                Button("200%") { zoomIndex = 3 }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .medium))
                    Text(currentZoom)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(Graphite.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(Graphite.control))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Graphite.border, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Preview zoom — scroll to pan when zoomed in")
        }
        .padding(.horizontal, 12)
    }
}
