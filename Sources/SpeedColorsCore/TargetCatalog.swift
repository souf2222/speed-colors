// TargetCatalog.swift — hierarchical, typed catalog of Color-page targets.
//
// A "target" is a calibrated screen position/region the cursor parks on
// (goto step) before click/hold. This file is the BUILT-IN catalog only —
// purely definitions (what a control is, its display path, interaction type,
// prerequisites). Captured coordinates live in the user config
// (~/.speedcolors/color.json), so updating this catalog never touches
// calibration data.
//
// Structure mirrors the Color page:
//
//   Primaries › Lift › Color balance        (a color wheel)
//   Primaries › General adjustments › Tint  (a slider)
//   HDR › Zones › Black · exposure
//   Finishing › Key › Output Gain
//
// Display identity is the PATH ("Primaries › Lift › Master level"); the raw id
// (wheel_1_amplitude — historical, stable) is secondary metadata that keeps
// autocal + existing bindings + saved calibrations working.
//
// Any other id can still be calibrated (shows as "Custom" in the UI).

import Foundation

/// How a target is meant to be interacted with.
public enum TargetType: String, Codable, CaseIterable, Sendable {
    /// Palette tab, mode button, one-shot action.
    case click
    /// Numeric value / slider — meant to be dragged with the search dial.
    case adjust
    /// Two-dimensional color-balance surface (puck drag).
    case wheel
    /// Area to interact inside (viewer, curve graph, warper surface).
    case region

    public var label: String {
        switch self {
        case .click: return "Click"
        case .adjust: return "Adjust"
        case .wheel: return "Color wheel"
        case .region: return "Region"
        }
    }
}

public struct TargetCatalogEntry: Sendable {
    public let id: String
    /// Display path, e.g. ["Primaries", "Lift", "Master level"].
    public let path: [String]
    public let type: TargetType
    /// What must be visible/enabled on screen before this target is valid.
    public let requires: String?

    public init(id: String, path: [String], type: TargetType, requires: String? = nil) {
        self.id = id
        self.path = path
        self.type = type
        self.requires = requires
    }

    public var name: String { path.last ?? id }
    public var topGroup: String { path.first ?? "Custom" }
    public var parentPath: String { path.dropLast().joined(separator: " › ") }
    public var fullPath: String { path.joined(separator: " › ") }
}

public enum TargetCatalog {

    /// Top-level group display order.
    public static let groupOrder: [String] = [
        "Primaries", "Log", "HDR", "Curves", "Qualifier",
        "Windows & Tracking", "Finishing", "Viewer & Workspace",
    ]

    public static let all: [TargetCatalogEntry] = [
        // MARK: Primaries

        .init(id: "color_page", path: ["Primaries", "Navigation", "Open Primaries palette"], type: .click),

        .init(id: "prim_mode_wheels", path: ["Primaries", "Navigation", "Color Wheels mode"], type: .click,
              requires: "Primaries palette open"),
        .init(id: "prim_mode_bars", path: ["Primaries", "Navigation", "Color Bars mode"], type: .click,
              requires: "Primaries palette open"),
        .init(id: "prim_mode_log", path: ["Primaries", "Navigation", "Log Wheels mode"], type: .click,
              requires: "Primaries palette open"),

        .init(id: "wheel_1_color", path: ["Primaries", "Lift", "Color balance"], type: .wheel,
              requires: "Primaries › Color Wheels mode"),
        .init(id: "wheel_1_amplitude", path: ["Primaries", "Lift", "Master level"], type: .adjust,
              requires: "Primaries › Color Wheels mode"),
        .init(id: "wheel_2_color", path: ["Primaries", "Gamma", "Color balance"], type: .wheel,
              requires: "Primaries › Color Wheels mode"),
        .init(id: "wheel_2_amplitude", path: ["Primaries", "Gamma", "Master level"], type: .adjust,
              requires: "Primaries › Color Wheels mode"),
        .init(id: "wheel_3_color", path: ["Primaries", "Gain", "Color balance"], type: .wheel,
              requires: "Primaries › Color Wheels mode"),
        .init(id: "wheel_3_amplitude", path: ["Primaries", "Gain", "Master level"], type: .adjust,
              requires: "Primaries › Color Wheels mode"),
        .init(id: "wheel_4_color", path: ["Primaries", "Offset", "Color balance"], type: .wheel,
              requires: "Primaries › Color Wheels mode"),
        .init(id: "wheel_4_amplitude", path: ["Primaries", "Offset", "Master level"], type: .adjust,
              requires: "Primaries › Color Wheels mode"),

        .init(id: "prim_temp",           path: ["Primaries", "General adjustments", "Temperature"],    type: .adjust),
        .init(id: "prim_tint",           path: ["Primaries", "General adjustments", "Tint"],           type: .adjust),
        .init(id: "prim_contrast",       path: ["Primaries", "General adjustments", "Contrast"],       type: .adjust),
        .init(id: "prim_pivot",          path: ["Primaries", "General adjustments", "Pivot"],          type: .adjust),
        .init(id: "prim_midtone_detail", path: ["Primaries", "General adjustments", "Midtone Detail"], type: .adjust),
        .init(id: "prim_color_boost",    path: ["Primaries", "General adjustments", "Color Boost"],    type: .adjust),
        .init(id: "prim_shadows",        path: ["Primaries", "General adjustments", "Shadows"],        type: .adjust),
        .init(id: "prim_highlights",     path: ["Primaries", "General adjustments", "Highlights"],     type: .adjust),
        .init(id: "prim_sat",            path: ["Primaries", "General adjustments", "Saturation"],     type: .adjust),
        .init(id: "prim_hue",            path: ["Primaries", "General adjustments", "Hue"],            type: .adjust),
        .init(id: "prim_lum_mix",        path: ["Primaries", "General adjustments", "Lum Mix"],        type: .adjust),

        // MARK: Log — separate tonal ranges from Primaries even where the
        // screen positions overlap (different wheels, different range settings).

        .init(id: "log_shadows_color",    path: ["Log", "Shadow", "Color balance"], type: .wheel,
              requires: "Primaries palette › Log Wheels mode"),
        .init(id: "log_shadows_master",   path: ["Log", "Shadow", "Master level"], type: .adjust,
              requires: "Primaries palette › Log Wheels mode"),
        .init(id: "log_midtones_color",   path: ["Log", "Midtones", "Color balance"], type: .wheel,
              requires: "Primaries palette › Log Wheels mode"),
        .init(id: "log_midtones_master",  path: ["Log", "Midtones", "Master level"], type: .adjust,
              requires: "Primaries palette › Log Wheels mode"),
        .init(id: "log_highlights_color", path: ["Log", "Highlight", "Color balance"], type: .wheel,
              requires: "Primaries palette › Log Wheels mode"),
        .init(id: "log_highlights_master", path: ["Log", "Highlight", "Master level"], type: .adjust,
              requires: "Primaries palette › Log Wheels mode"),
        .init(id: "log_offset_color",     path: ["Log", "Offset", "Color balance"], type: .wheel,
              requires: "Primaries palette › Log Wheels mode"),
        .init(id: "log_offset_master",    path: ["Log", "Offset", "Master level"], type: .adjust,
              requires: "Primaries palette › Log Wheels mode"),
        .init(id: "log_low_range",        path: ["Log", "Range", "Low range"], type: .adjust,
              requires: "Primaries palette › Log Wheels mode"),
        .init(id: "log_high_range",       path: ["Log", "Range", "High range"], type: .adjust,
              requires: "Primaries palette › Log Wheels mode"),

        // MARK: HDR — zone-based, NOT Lift/Gamma/Gain/Offset. Resolve's HDR
        // zones are Black/Dark/Shadow/Light/Highlight/Specular. Wheel bank
        // targets describe one bank; the bank indicator is part of the
        // prerequisite until banks are observable via the scripting bridge.

        .init(id: "hdr_page", path: ["HDR", "Navigation", "Open HDR palette"], type: .click),
        .init(id: "hdr_bank_prev", path: ["HDR", "Navigation", "Previous wheel bank"], type: .click,
              requires: "HDR palette open"),
        .init(id: "hdr_bank_next", path: ["HDR", "Navigation", "Next wheel bank"], type: .click,
              requires: "HDR palette open"),

        .init(id: "hdr_global_color", path: ["HDR", "Global", "Color balance"], type: .wheel,
              requires: "HDR palette open"),
        .init(id: "hdr_global_exp", path: ["HDR", "Global", "Exposure"], type: .adjust,
              requires: "HDR palette open"),
        .init(id: "hdr_global_sat", path: ["HDR", "Global", "Saturation"], type: .adjust,
              requires: "HDR palette open"),

        .init(id: "hdr_zone_black_color",     path: ["HDR", "Zones", "Black · balance"],   type: .wheel,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_black_exp",       path: ["HDR", "Zones", "Black · exposure"],  type: .adjust,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_black_sat",       path: ["HDR", "Zones", "Black · saturation"], type: .adjust,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_dark_color",      path: ["HDR", "Zones", "Dark · balance"],    type: .wheel,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_dark_exp",        path: ["HDR", "Zones", "Dark · exposure"],   type: .adjust,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_dark_sat",        path: ["HDR", "Zones", "Dark · saturation"], type: .adjust,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_shadow_color",    path: ["HDR", "Zones", "Shadow · balance"],  type: .wheel,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_shadow_exp",      path: ["HDR", "Zones", "Shadow · exposure"], type: .adjust,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_shadow_sat",      path: ["HDR", "Zones", "Shadow · saturation"], type: .adjust,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_light_color",     path: ["HDR", "Zones", "Light · balance"],   type: .wheel,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_light_exp",       path: ["HDR", "Zones", "Light · exposure"],  type: .adjust,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_light_sat",       path: ["HDR", "Zones", "Light · saturation"], type: .adjust,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_highlight_color", path: ["HDR", "Zones", "Highlight · balance"], type: .wheel,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_highlight_exp",   path: ["HDR", "Zones", "Highlight · exposure"], type: .adjust,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_highlight_sat",   path: ["HDR", "Zones", "Highlight · saturation"], type: .adjust,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_specular_color",  path: ["HDR", "Zones", "Specular · balance"], type: .wheel,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_specular_exp",    path: ["HDR", "Zones", "Specular · exposure"], type: .adjust,
              requires: "HDR palette › correct wheel bank"),
        .init(id: "hdr_zone_specular_sat",    path: ["HDR", "Zones", "Specular · saturation"], type: .adjust,
              requires: "HDR palette › correct wheel bank"),

        // MARK: Curves

        .init(id: "curves_page", path: ["Curves", "Navigation", "Open Curves palette"], type: .click),

        .init(id: "curves_custom",  path: ["Curves", "Custom curves", "Graph"], type: .region,
              requires: "Curves › Custom curve type"),
        .init(id: "curves_chan_y",  path: ["Curves", "Custom curves", "Y channel"], type: .click,
              requires: "Curves › Custom curve type"),
        .init(id: "curves_chan_r",  path: ["Curves", "Custom curves", "R channel"], type: .click,
              requires: "Curves › Custom curve type"),
        .init(id: "curves_chan_g",  path: ["Curves", "Custom curves", "G channel"], type: .click,
              requires: "Curves › Custom curve type"),
        .init(id: "curves_chan_b",  path: ["Curves", "Custom curves", "B channel"], type: .click,
              requires: "Curves › Custom curve type"),
        .init(id: "curves_link",    path: ["Curves", "Custom curves", "Channel link"], type: .click,
              requires: "Curves › Custom curve type"),

        .init(id: "curves_hue_hue", path: ["Curves", "Hue curves", "Hue vs Hue"],    type: .region,
              requires: "Curves › correct curve type"),
        .init(id: "curves_hue_sat", path: ["Curves", "Hue curves", "Hue vs Sat"],    type: .region,
              requires: "Curves › correct curve type"),
        .init(id: "curves_hue_lum", path: ["Curves", "Hue curves", "Hue vs Lum"],    type: .region,
              requires: "Curves › correct curve type"),
        .init(id: "curves_lum_sat", path: ["Curves", "Secondary curves", "Lum vs Sat"], type: .region,
              requires: "Curves › correct curve type"),
        .init(id: "curves_sat_sat", path: ["Curves", "Secondary curves", "Sat vs Sat"], type: .region,
              requires: "Curves › correct curve type"),
        .init(id: "curves_sat_lum", path: ["Curves", "Secondary curves", "Sat vs Lum"], type: .region,
              requires: "Curves › correct curve type"),

        .init(id: "curves_soft_clip", path: ["Curves", "Utilities", "Soft clip"], type: .adjust),
        .init(id: "curves_reset",     path: ["Curves", "Utilities", "Reset curve"], type: .click),

        // MARK: Qualifier

        .init(id: "qual_page", path: ["Qualifier", "Navigation", "Open Qualifier palette"], type: .click),
        .init(id: "qual_pick_sample", path: ["Qualifier", "Pickers", "Sample"],           type: .click,
              requires: "Qualifier palette open"),
        .init(id: "qual_pick_add",    path: ["Qualifier", "Pickers", "Add sample"],       type: .click,
              requires: "Qualifier palette open"),
        .init(id: "qual_pick_sub",    path: ["Qualifier", "Pickers", "Subtract sample"],  type: .click,
              requires: "Qualifier palette open"),

        .init(id: "qual_hue_center",  path: ["Qualifier", "Hue", "Center"],   type: .adjust,
              requires: "Qualifier palette › HSL"),
        .init(id: "qual_hue_width",   path: ["Qualifier", "Hue", "Width"],    type: .adjust,
              requires: "Qualifier palette › HSL"),
        .init(id: "qual_hue_soft",    path: ["Qualifier", "Hue", "Softness"], type: .adjust,
              requires: "Qualifier palette › HSL"),
        .init(id: "qual_sat_low",     path: ["Qualifier", "Saturation", "Low threshold"], type: .adjust,
              requires: "Qualifier palette › HSL"),
        .init(id: "qual_sat_high",    path: ["Qualifier", "Saturation", "High threshold"], type: .adjust,
              requires: "Qualifier palette › HSL"),
        .init(id: "qual_sat_soft",    path: ["Qualifier", "Saturation", "Softness"], type: .adjust,
              requires: "Qualifier palette › HSL"),
        .init(id: "qual_lum_low",     path: ["Qualifier", "Luminance", "Low threshold"], type: .adjust,
              requires: "Qualifier palette › HSL"),
        .init(id: "qual_lum_high",    path: ["Qualifier", "Luminance", "High threshold"], type: .adjust,
              requires: "Qualifier palette › HSL"),
        .init(id: "qual_lum_soft",    path: ["Qualifier", "Luminance", "Softness"], type: .adjust,
              requires: "Qualifier palette › HSL"),

        .init(id: "qual_ref_clean_black", path: ["Qualifier", "Matte refinement", "Clean Black"], type: .adjust,
              requires: "Qualifier palette › Matte Finesse"),
        .init(id: "qual_ref_clean_white", path: ["Qualifier", "Matte refinement", "Clean White"], type: .adjust,
              requires: "Qualifier palette › Matte Finesse"),
        .init(id: "qual_ref_blur_radius", path: ["Qualifier", "Matte refinement", "Blur Radius"], type: .adjust,
              requires: "Qualifier palette › Matte Finesse"),
        .init(id: "qual_ref_denoise",     path: ["Qualifier", "Matte refinement", "Denoise"], type: .adjust,
              requires: "Qualifier palette › Matte Finesse"),

        .init(id: "qual_view_highlight", path: ["Qualifier", "Inspection", "Highlight view"], type: .click),

        // MARK: Windows & Tracking

        .init(id: "window_page", path: ["Windows & Tracking", "Navigation", "Open Window palette"], type: .click),

        .init(id: "win_new_circle",    path: ["Windows & Tracking", "Window creation", "Circle"], type: .click,
              requires: "Window palette open"),
        .init(id: "win_new_linear",    path: ["Windows & Tracking", "Window creation", "Linear"], type: .click,
              requires: "Window palette open"),
        .init(id: "win_new_polygon",   path: ["Windows & Tracking", "Window creation", "Polygon"], type: .click,
              requires: "Window palette open"),
        .init(id: "win_new_curve",     path: ["Windows & Tracking", "Window creation", "Curve"], type: .click,
              requires: "Window palette open"),
        .init(id: "win_new_gradient",  path: ["Windows & Tracking", "Window creation", "Gradient"], type: .click,
              requires: "Window palette open"),

        .init(id: "win_position", path: ["Windows & Tracking", "Window adjustment", "Position"], type: .adjust,
              requires: "Window palette › a window exists"),
        .init(id: "win_size",     path: ["Windows & Tracking", "Window adjustment", "Size"], type: .adjust,
              requires: "Window palette › a window exists"),
        .init(id: "win_aspect",   path: ["Windows & Tracking", "Window adjustment", "Aspect"], type: .adjust,
              requires: "Window palette › a window exists"),
        .init(id: "win_rotation", path: ["Windows & Tracking", "Window adjustment", "Rotation"], type: .adjust,
              requires: "Window palette › a window exists"),
        .init(id: "win_softness", path: ["Windows & Tracking", "Window adjustment", "Softness"], type: .adjust,
              requires: "Window palette › a window exists"),

        .init(id: "tracker_page",       path: ["Windows & Tracking", "Tracker", "Open Tracker palette"], type: .click),
        .init(id: "track_forward",      path: ["Windows & Tracking", "Tracker", "Track forward"], type: .click),
        .init(id: "track_backward",     path: ["Windows & Tracking", "Tracker", "Track backward"], type: .click),
        .init(id: "track_stop",         path: ["Windows & Tracking", "Tracker", "Stop tracking"], type: .click),

        .init(id: "track_opt_pan",        path: ["Windows & Tracking", "Tracker options", "Pan"], type: .click),
        .init(id: "track_opt_tilt",       path: ["Windows & Tracking", "Tracker options", "Tilt"], type: .click),
        .init(id: "track_opt_zoom",       path: ["Windows & Tracking", "Tracker options", "Zoom"], type: .click),
        .init(id: "track_opt_rotation",   path: ["Windows & Tracking", "Tracker options", "Rotation"], type: .click),
        .init(id: "track_opt_perspective", path: ["Windows & Tracking", "Tracker options", "Perspective"], type: .click),

        .init(id: "window_osc", path: ["Windows & Tracking", "Viewer", "Window manipulation"], type: .region,
              requires: "Window palette › on-screen controls enabled"),

        // MARK: Finishing

        .init(id: "blur_page", path: ["Finishing", "Blur / Sharpen", "Open Blur palette"], type: .click),
        .init(id: "blur_mode", path: ["Finishing", "Blur / Sharpen", "Mode selector"], type: .click,
              requires: "Blur palette open"),
        .init(id: "blur_radius", path: ["Finishing", "Blur / Sharpen", "Radius"], type: .adjust,
              requires: "Blur palette open"),
        .init(id: "blur_link", path: ["Finishing", "Blur / Sharpen", "Channel linking"], type: .click,
              requires: "Blur palette open"),

        .init(id: "key_page", path: ["Finishing", "Key", "Open Key palette"], type: .click),
        .init(id: "key_output_gain", path: ["Finishing", "Key", "Output Gain"], type: .adjust,
              requires: "Key palette open"),
        .init(id: "key_input_gain", path: ["Finishing", "Key", "Input Gain"], type: .adjust,
              requires: "Key palette open"),

        .init(id: "sizing_page", path: ["Finishing", "Sizing", "Open Sizing palette"], type: .click),
        .init(id: "sizing_pan",      path: ["Finishing", "Sizing", "Pan"], type: .adjust,
              requires: "Sizing palette open"),
        .init(id: "sizing_tilt",     path: ["Finishing", "Sizing", "Tilt"], type: .adjust,
              requires: "Sizing palette open"),
        .init(id: "sizing_zoom",     path: ["Finishing", "Sizing", "Zoom"], type: .adjust,
              requires: "Sizing palette open"),
        .init(id: "sizing_rotation", path: ["Finishing", "Sizing", "Rotation"], type: .adjust,
              requires: "Sizing palette open"),

        .init(id: "rgbmixer_page", path: ["Finishing", "RGB Mixer", "Open RGB Mixer palette"], type: .click),
        .init(id: "rgbmixer_matrix", path: ["Finishing", "RGB Mixer", "Matrix"], type: .region,
              requires: "RGB Mixer palette open"),
        .init(id: "rgbmixer_preserve_lum", path: ["Finishing", "RGB Mixer", "Preserve luminance"], type: .click,
              requires: "RGB Mixer palette open"),
        .init(id: "rgbmixer_mono", path: ["Finishing", "RGB Mixer", "Monochrome"], type: .click,
              requires: "RGB Mixer palette open"),

        .init(id: "raw_page", path: ["Finishing", "Camera RAW", "Open Camera RAW palette"], type: .click,
              requires: "RAW clip (conditional)"),
        .init(id: "raw_exposure", path: ["Finishing", "Camera RAW", "Exposure"], type: .adjust,
              requires: "RAW clip (conditional)"),
        .init(id: "raw_temp", path: ["Finishing", "Camera RAW", "Temperature"], type: .adjust,
              requires: "RAW clip (conditional)"),
        .init(id: "raw_tint", path: ["Finishing", "Camera RAW", "Tint"], type: .adjust,
              requires: "RAW clip (conditional)"),

        .init(id: "motionfx_page", path: ["Finishing", "Motion FX", "Open Motion FX palette"], type: .click),
        .init(id: "motionfx_temporal", path: ["Finishing", "Motion FX", "Temporal NR"], type: .adjust,
              requires: "Motion FX palette open · Studio edition"),
        .init(id: "motionfx_spatial", path: ["Finishing", "Motion FX", "Spatial NR"], type: .adjust,
              requires: "Motion FX palette open · Studio edition"),

        .init(id: "color_warper_page", path: ["Finishing", "Color Warper", "Open Color Warper palette"], type: .click),
        .init(id: "color_warper_graph", path: ["Finishing", "Color Warper", "Warper surface"], type: .region,
              requires: "Color Warper palette open"),
        .init(id: "color_warper_outer_point", path: ["Finishing", "Color Warper", "Outer point"], type: .adjust,
              requires: "Color Warper palette › point selected"),
        .init(id: "color_warper_inner_point", path: ["Finishing", "Color Warper", "Inner point"], type: .adjust,
              requires: "Color Warper palette › point selected"),
        .init(id: "color_warper_select_ring", path: ["Finishing", "Color Warper", "Select ring"], type: .region,
              requires: "Color Warper palette open"),
        .init(id: "color_warper_sat", path: ["Finishing", "Color Warper", "Saturation"], type: .adjust,
              requires: "Color Warper palette open"),

        .init(id: "effects_page", path: ["Finishing", "Effects", "Open Effects palette"], type: .click),

        // MARK: Viewer & Workspace

        .init(id: "viewer_main", path: ["Viewer & Workspace", "Viewer", "Main viewer"], type: .region),
        .init(id: "viewer_zoom", path: ["Viewer & Workspace", "Viewer", "Zoom controls"], type: .click),
        .init(id: "split_screen", path: ["Viewer & Workspace", "Viewer", "Split screen"], type: .click,
              requires: "Split-screen enabled (conditional)"),
        .init(id: "image_wipe", path: ["Viewer & Workspace", "Viewer", "Image wipe"], type: .click),

        .init(id: "scopes", path: ["Viewer & Workspace", "Scopes", "Scopes region"], type: .region),
        .init(id: "scope_menu", path: ["Viewer & Workspace", "Scopes", "Scope selection"], type: .click),

        .init(id: "gallery",        path: ["Viewer & Workspace", "Workspace", "Gallery panel"], type: .click),
        .init(id: "node_window",    path: ["Viewer & Workspace", "Workspace", "Node graph"], type: .region),
        .init(id: "group_pre_clip", path: ["Viewer & Workspace", "Workspace", "Group pre-clip node"], type: .click),
        .init(id: "clip",           path: ["Viewer & Workspace", "Workspace", "Current clip"], type: .click),
        .init(id: "group_post_clip", path: ["Viewer & Workspace", "Workspace", "Group post-clip node"], type: .click),
        .init(id: "01_tree",        path: ["Viewer & Workspace", "Workspace", "Timeline tree (01)"], type: .click),
        .init(id: "tree_clip",      path: ["Viewer & Workspace", "Workspace", "Tree clip"], type: .region),
    ]

    /// Full catalog entry for an id (nil = custom/user-defined target).
    public static func entry(for id: String) -> TargetCatalogEntry? {
        all.first(where: { $0.id == id })
    }

    /// Display label for an id: the full path ("Primaries › Lift › Master level").
    public static func label(for id: String) -> String? {
        entry(for: id)?.fullPath
    }

    /// Top-level group an id belongs to (nil = custom).
    public static func group(for id: String) -> String? {
        entry(for: id)?.topGroup
    }

    /// Ids removed from the catalog (wrong model: HDR never had
    /// Lift/Gamma/Gain/Offset zones). load() migrates stale calibrations away.
    public static let deprecatedIds: [String] = [
        "hdr_lift_color", "hdr_gamma_color", "hdr_gain_color", "hdr_offset_color",
    ]
}
