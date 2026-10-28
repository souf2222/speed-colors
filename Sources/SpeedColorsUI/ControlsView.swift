// ControlsView.swift — the Controls workspace:
//
//   ┌──────────────────────────────────────────────┬──────────────┐
//   │      Speed Editor hardware layout            │ Action       │
//   ├──────────────────────────────────────────────┤ library      │
//   │      Selected control inspector              │              │
//   └──────────────────────────────────────────────┴──────────────┘

import SwiftUI

struct ControlsView: View {
    @EnvironmentObject var controller: DaemonController

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    HardwareLayout()
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)

                Divider().overlay(Graphite.border)

                BindingInspectorPane()
                    .frame(height: 300)
            }
            .frame(maxWidth: .infinity)

            Divider().overlay(Graphite.border)

            ActionLibrary()
                .frame(width: 236)
        }
    }
}
