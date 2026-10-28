// TargetCatalog.swift — known Color-page UI elements, organized.
//
// A "target" is a calibrated screen position the cursor can be parked on
// (goto step) before click/hold. The catalog names the elements Resolve
// exposes on the Color page so bindings read like the UI:
//
//   wheel_1_color      the Lift wheel puck surface
//   wheel_1_amplitude  the Lift master amplitude slider under it
//   key_output_gain    Output Gain in the Key palette
//   …
//
// Any other name can still be calibrated and used (shows as "custom" in the
// UI); the catalog only adds labels, grouping, and search.

import Foundation

public struct TargetCatalogEntry {
    public let id: String
    public let label: String
    public let group: String

    public init(id: String, label: String, group: String) {
        self.id = id
        self.label = label
        self.group = group
    }
}

public enum TargetCatalog {

    public static let all: [TargetCatalogEntry] = [
        // MARK: Primaries wheels (1=Lift 2=Gamma 3=Gain 4=Offset)

        .init(id: "wheel_1_color",     label: "Wheel 1 · Lift — color",      group: "Primaries"),
        .init(id: "wheel_1_amplitude", label: "Wheel 1 · Lift — amplitude",  group: "Primaries"),
        .init(id: "wheel_2_color",     label: "Wheel 2 · Gamma — color",     group: "Primaries"),
        .init(id: "wheel_2_amplitude", label: "Wheel 2 · Gamma — amplitude", group: "Primaries"),
        .init(id: "wheel_3_color",     label: "Wheel 3 · Gain — color",      group: "Primaries"),
        .init(id: "wheel_3_amplitude", label: "Wheel 3 · Gain — amplitude",  group: "Primaries"),
        .init(id: "wheel_4_color",     label: "Wheel 4 · Offset — color",    group: "Primaries"),
        .init(id: "wheel_4_amplitude", label: "Wheel 4 · Offset — amplitude", group: "Primaries"),

        // MARK: HDR

        .init(id: "hdr_page",         label: "HDR palette tab",   group: "HDR"),
        .init(id: "hdr_global_exp",   label: "HDR global exposure", group: "HDR"),
        .init(id: "hdr_lift_color",   label: "HDR Lift wheel",    group: "HDR"),
        .init(id: "hdr_gamma_color",  label: "HDR Gamma wheel",   group: "HDR"),
        .init(id: "hdr_gain_color",   label: "HDR Gain wheel",    group: "HDR"),
        .init(id: "hdr_offset_color", label: "HDR Offset wheel",  group: "HDR"),

        // MARK: Palette pages (middle tab strip)

        .init(id: "color_page",        label: "Primaries (Color) tab", group: "Palette pages"),
        .init(id: "curves_page",       label: "Curves tab",            group: "Palette pages"),
        .init(id: "color_warper_page", label: "Color Warper tab",      group: "Palette pages"),
        .init(id: "key_page",          label: "Key tab",               group: "Palette pages"),
        .init(id: "blur_page",         label: "Blur tab",              group: "Palette pages"),
        .init(id: "motionfx_page",     label: "Motion Effects tab",    group: "Palette pages"),
        .init(id: "sizing_page",       label: "Sizing tab",            group: "Palette pages"),
        .init(id: "effects_page",      label: "Effects tab",           group: "Palette pages"),
        .init(id: "window_page",       label: "Window palette tab",    group: "Palette pages"),

        // MARK: Color Warper

        .init(id: "color_warper_outer_point", label: "Warper outer point",  group: "Color Warper"),
        .init(id: "color_warper_inner_point", label: "Warper inner point",  group: "Color Warper"),
        .init(id: "color_warper_select_ring", label: "Warper select ring",  group: "Color Warper"),
        .init(id: "color_warper_sat",         label: "Warper saturation",   group: "Color Warper"),

        // MARK: Key

        .init(id: "key_output_gain", label: "Key output gain", group: "Key"),

        // MARK: Curves & Blur

        .init(id: "curves_custom",  label: "Custom curve graph", group: "Curves"),
        .init(id: "curves_soft_clip", label: "Soft clip",        group: "Curves"),
        .init(id: "blur_radius",    label: "Blur radius",        group: "Blur"),

        // MARK: Nodes & clips

        .init(id: "node_window",      label: "Node graph",             group: "Nodes & clips"),
        .init(id: "group_pre_clip",   label: "Group pre-clip node",    group: "Nodes & clips"),
        .init(id: "clip",             label: "Current clip",           group: "Nodes & clips"),
        .init(id: "group_post_clip",  label: "Group post-clip node",   group: "Nodes & clips"),

        // MARK: Timeline panel

        .init(id: "gallery",   label: "Gallery",                 group: "Timeline panel"),
        .init(id: "01_tree",   label: "Timeline tree (01)",      group: "Timeline panel"),
        .init(id: "tree_clip", label: "Tree clip",               group: "Timeline panel"),

        // MARK: Viewer

        .init(id: "viewer_main", label: "Main viewer",                       group: "Viewer"),
        .init(id: "window_osc",  label: "Power window on-screen control",    group: "Viewer"),
    ]

    /// Catalog label for an id (nil = custom/user-defined target).
    public static func label(for id: String) -> String? {
        all.first(where: { $0.id == id })?.label
    }

    /// Group an id belongs to (nil = custom).
    public static func group(for id: String) -> String? {
        all.first(where: { $0.id == id })?.group
    }
}
