// Theme.swift — graphite design system: palette + shared controls used by
// every section of the app (buttons, pills, section titles, fields).

import SwiftUI

// MARK: - Palette

enum Graphite {
    static let bg      = Color(hex: 0x1E1E22)
    static let panel   = Color(hex: 0x232327)   // slightly raised surface
    static let control = Color(hex: 0x343438)
    static let hover   = Color(hex: 0x3E3E43)
    static let border  = Color(hex: 0x414146)
    static let text    = Color(hex: 0xE5E5E7)
    static let text2   = Color(hex: 0xA6A6AD)
    static let text3   = Color(hex: 0x6E6E76)
    static let blue    = Color(hex: 0x2785F5)
    static let green   = Color(hex: 0x42C38F)
    static let cyan    = Color(hex: 0x42D0E9)
    static let amber   = Color(hex: 0xE5B34F)
    static let red     = Color(hex: 0xE65E70)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }
}

// MARK: - Shared controls

struct Pill: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(Graphite.text2)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(Graphite.control))
    }
}

struct GraphiteButtonStyle: ButtonStyle {
    var accent: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Graphite.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed ? Graphite.hover : Graphite.control)
            )
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(accent ?? Graphite.border, lineWidth: accent == nil ? 1 : 1.5))
    }
}

/// Small bordered button used inside inspectors and rows.
struct MiniButtonStyle: ButtonStyle {
    var accent: Color? = nil
    var danger = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(danger ? Graphite.red : Graphite.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed ? Graphite.hover : Graphite.control.opacity(0.7))
            )
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(accent ?? Graphite.border, lineWidth: 1))
    }
}

/// Uppercased section label.
struct SectionTitle: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Graphite.text3)
    }
}

/// Field label + value row used in inspectors.
struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Graphite.text2)
            Spacer()
            content
        }
    }
}

/// Standard rounded text field.
struct GraphiteField: View {
    var placeholder: String = ""
    @Binding var text: String
    var width: CGFloat? = nil

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(Graphite.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Graphite.control))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Graphite.border, lineWidth: 1))
            .frame(width: width)
    }
}

/// Empty-state placeholder for panes.
struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundColor(Graphite.text3)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Graphite.text2)
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(Graphite.text3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
