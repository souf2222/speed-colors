// BMD.swift — Speed Editor protocol: keycodes, LEDs, jog modes, authentication.
//
// Protocol reverse engineering by Sylvain Munaut <tnt@246tNt.com> (2021),
// published under the Apache-2.0 license:
//   https://github.com/smunaut/blackmagic-misc (bmd.py)
// Swift adaptation for speedcolors.

import Foundation

// MARK: - Keys

/// Physical buttons of the Speed Editor, by protocol keycode.
public enum SpeedEditorKey: UInt16, CaseIterable, Sendable, CustomStringConvertible {
    case none = 0x00
    case smartInsrt = 0x01
    case appnd = 0x02
    case riplOwr = 0x03
    case closeUp = 0x04
    case placeOnTop = 0x05
    case srcOwr = 0x06
    case markIn = 0x07
    case markOut = 0x08
    case trimIn = 0x09
    case trimOut = 0x0A
    case roll = 0x0B
    case slipSrc = 0x0C
    case slipDest = 0x0D
    case transDur = 0x0E
    case cut = 0x0F
    case dis = 0x10
    case smthCut = 0x11
    case source = 0x1A
    case timeline = 0x1B
    case shtl = 0x1C
    case jog = 0x1D
    case scrl = 0x1E
    case syncBin = 0x1F
    case trans = 0x22
    case videoOnly = 0x25
    case audioOnly = 0x26
    case riplDel = 0x2B
    case audioLevel = 0x2C
    case fullView = 0x2D
    case snap = 0x2E
    case split = 0x2F
    case liveOwr = 0x30
    case esc = 0x31
    case cam1 = 0x33
    case cam2 = 0x34
    case cam3 = 0x35
    case cam4 = 0x36
    case cam5 = 0x37
    case cam6 = 0x38
    case cam7 = 0x39
    case cam8 = 0x3A
    case cam9 = 0x3B
    case stopPlay = 0x3C

    public var label: String {
        switch self {
        case .none: return "-"
        case .smartInsrt: return "SMART INSRT"
        case .appnd: return "APPND"
        case .riplOwr: return "RIPL O/WR"
        case .closeUp: return "CLOSE UP"
        case .placeOnTop: return "PLACE ON TOP"
        case .srcOwr: return "SRC O/WR"
        case .markIn: return "IN"
        case .markOut: return "OUT"
        case .trimIn: return "TRIM IN"
        case .trimOut: return "TRIM OUT"
        case .roll: return "ROLL"
        case .slipSrc: return "SLIP SRC"
        case .slipDest: return "SLIP DEST"
        case .transDur: return "TRANS DUR"
        case .cut: return "CUT"
        case .dis: return "DIS"
        case .smthCut: return "SMTH CUT"
        case .source: return "SOURCE"
        case .timeline: return "TIMELINE"
        case .shtl: return "SHTL"
        case .jog: return "JOG"
        case .scrl: return "SCRL"
        case .syncBin: return "SYNC BIN"
        case .trans: return "TRANS"
        case .videoOnly: return "VIDEO ONLY"
        case .audioOnly: return "AUDIO ONLY"
        case .riplDel: return "RIPL DEL"
        case .audioLevel: return "AUDIO LEVEL"
        case .fullView: return "FULL VIEW"
        case .snap: return "SNAP"
        case .split: return "SPLIT"
        case .liveOwr: return "LIVE O/WR"
        case .esc: return "ESC"
        case .cam1: return "CAM1"
        case .cam2: return "CAM2"
        case .cam3: return "CAM3"
        case .cam4: return "CAM4"
        case .cam5: return "CAM5"
        case .cam6: return "CAM6"
        case .cam7: return "CAM7"
        case .cam8: return "CAM8"
        case .cam9: return "CAM9"
        case .stopPlay: return "STOP/PLAY"
        }
    }

    /// Canonical config id — the raw case name (e.g. "cam1", "liveOwr").
    /// MUST be used for config lookups: `String(describing:)` returns the
    /// LABEL ("CAM1") because the enum is CustomStringConvertible, which
    /// silently broke every binding lookup once `description` was added.
    public var id: String {
        switch self {
        case .none: return "none"
        case .smartInsrt: return "smartInsrt"
        case .appnd: return "appnd"
        case .riplOwr: return "riplOwr"
        case .closeUp: return "closeUp"
        case .placeOnTop: return "placeOnTop"
        case .srcOwr: return "srcOwr"
        case .markIn: return "markIn"
        case .markOut: return "markOut"
        case .trimIn: return "trimIn"
        case .trimOut: return "trimOut"
        case .roll: return "roll"
        case .slipSrc: return "slipSrc"
        case .slipDest: return "slipDest"
        case .transDur: return "transDur"
        case .cut: return "cut"
        case .dis: return "dis"
        case .smthCut: return "smthCut"
        case .source: return "source"
        case .timeline: return "timeline"
        case .shtl: return "shtl"
        case .jog: return "jog"
        case .scrl: return "scrl"
        case .syncBin: return "syncBin"
        case .trans: return "trans"
        case .videoOnly: return "videoOnly"
        case .audioOnly: return "audioOnly"
        case .riplDel: return "riplDel"
        case .audioLevel: return "audioLevel"
        case .fullView: return "fullView"
        case .snap: return "snap"
        case .split: return "split"
        case .liveOwr: return "liveOwr"
        case .esc: return "esc"
        case .cam1: return "cam1"
        case .cam2: return "cam2"
        case .cam3: return "cam3"
        case .cam4: return "cam4"
        case .cam5: return "cam5"
        case .cam6: return "cam6"
        case .cam7: return "cam7"
        case .cam8: return "cam8"
        case .cam9: return "cam9"
        case .stopPlay: return "stopPlay"
        }
    }

    /// The panel LED that physically sits under this key, if any. Only 18
    /// keys have backlights (camera column, cut row, transport-ish keys);
    /// keys like TRIM IN or ROLL have none and return nil.
    public var led: SpeedEditorLed? {
        switch self {
        case .closeUp:   return .closeUp
        case .cut:       return .cut
        case .dis:       return .dis
        case .smthCut:   return .smthCut
        case .trans:     return .trans
        case .snap:      return .snap
        case .cam1:      return .cam1
        case .cam2:      return .cam2
        case .cam3:      return .cam3
        case .cam4:      return .cam4
        case .cam5:      return .cam5
        case .cam6:      return .cam6
        case .cam7:      return .cam7
        case .cam8:      return .cam8
        case .cam9:      return .cam9
        case .liveOwr:   return .liveOwr
        case .videoOnly: return .videoOnly
        case .audioOnly: return .audioOnly
        default:         return nil
        }
    }

    public var description: String { label }
}

// MARK: - LEDs

/// Panel LEDs — output report 0x02, u32 LE bitmask.
public struct SpeedEditorLed: OptionSet, Sendable, CustomStringConvertible, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    static let closeUp    = SpeedEditorLed(rawValue: 1 << 0)
    static let cut        = SpeedEditorLed(rawValue: 1 << 1)
    static let dis        = SpeedEditorLed(rawValue: 1 << 2)
    static let smthCut    = SpeedEditorLed(rawValue: 1 << 3)
    static let trans      = SpeedEditorLed(rawValue: 1 << 4)
    static let snap       = SpeedEditorLed(rawValue: 1 << 5)
    static let cam7       = SpeedEditorLed(rawValue: 1 << 6)
    static let cam8       = SpeedEditorLed(rawValue: 1 << 7)
    static let cam9       = SpeedEditorLed(rawValue: 1 << 8)
    static let liveOwr    = SpeedEditorLed(rawValue: 1 << 9)
    static let cam4       = SpeedEditorLed(rawValue: 1 << 10)
    static let cam5       = SpeedEditorLed(rawValue: 1 << 11)
    static let cam6       = SpeedEditorLed(rawValue: 1 << 12)
    static let videoOnly  = SpeedEditorLed(rawValue: 1 << 13)
    static let cam1       = SpeedEditorLed(rawValue: 1 << 14)
    static let cam2       = SpeedEditorLed(rawValue: 1 << 15)
    static let cam3       = SpeedEditorLed(rawValue: 1 << 16)
    static let audioOnly  = SpeedEditorLed(rawValue: 1 << 17)

    /// Physical order on the panel (for chase demos / mapping checks).
    public static let allInOrder: [SpeedEditorLed] = [
        .closeUp, .cut, .dis, .smthCut, .trans, .snap,
        .cam7, .cam8, .cam9, .liveOwr,
        .cam4, .cam5, .cam6, .videoOnly,
        .cam1, .cam2, .cam3, .audioOnly,
    ]

    public var label: String {
        switch rawValue {
        case 1 << 0: return "CLOSE UP"
        case 1 << 1: return "CUT"
        case 1 << 2: return "DIS"
        case 1 << 3: return "SMTH CUT"
        case 1 << 4: return "TRANS"
        case 1 << 5: return "SNAP"
        case 1 << 6: return "CAM7"
        case 1 << 7: return "CAM8"
        case 1 << 8: return "CAM9"
        case 1 << 9: return "LIVE O/WR"
        case 1 << 10: return "CAM4"
        case 1 << 11: return "CAM5"
        case 1 << 12: return "CAM6"
        case 1 << 13: return "VIDEO ONLY"
        case 1 << 14: return "CAM1"
        case 1 << 15: return "CAM2"
        case 1 << 16: return "CAM3"
        case 1 << 17: return "AUDIO ONLY"
        default: return "LED(\(rawValue))"
        }
    }

    public var description: String { label }
}

/// Jog-mode LEDs (JOG / SHTL / SCRL) — output report 0x04, u8 bitmask.
public struct SpeedEditorJogLed: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    static let jog  = SpeedEditorJogLed(rawValue: 1 << 0)
    static let shtl = SpeedEditorJogLed(rawValue: 1 << 1)
    static let scrl = SpeedEditorJogLed(rawValue: 1 << 2)

    public static let allInOrder: [SpeedEditorJogLed] = [.jog, .shtl, .scrl]
}

// MARK: - Jog modes

public enum SpeedEditorJogMode: UInt8, Sendable, CustomStringConvertible {
    /// Relative deltas since the last report.
    case relative0 = 0
    /// Absolute position -4096...4096 (≈ half a turn) relative to when the mode was set.
    case absoluteContinuous = 1
    /// Relative (Resolve uses this for its fast-scroll double-press behavior).
    case relative2 = 2
    /// Like absoluteContinuous with a dead band around zero.
    case absoluteDeadzero = 3

    public var description: String {
        switch self {
        case .relative0: return "RELATIVE"
        case .absoluteContinuous: return "ABSOLUTE"
        case .relative2: return "RELATIVE_2"
        case .absoluteDeadzero: return "ABSOLUTE±DEADZONE"
        }
    }
}

// MARK: - Authentication

private func rol8(_ v: UInt64) -> UInt64 {
    ((v << 56) | (v >> 8)) & 0xFFFF_FFFF_FFFF_FFFF
}

/// Answer the keyboard's challenge so it starts sending input reports.
/// Algorithm reverse engineered by Sylvain Munaut (Apache-2.0).
public func bmdKbdAuth(_ challenge: UInt64) -> UInt64 {
    let even: [UInt64] = [
        0x3AE1_206F_97C1_0BC8, 0x2A9A_B32B_EBF2_44C6, 0x20A6_F8B8_DF9A_DF0A,
        0xAF80_ECE5_2CFC_1719, 0xEC2E_E2F7_414F_D151, 0xB055_ADFD_7334_4A15,
        0xA63D_2E30_5900_1187, 0x751B_F623_F42E_0DDE,
    ]
    let odd: [UInt64] = [
        0x3E22_B34F_502E_7FDE, 0x2465_6B98_1875_AB1C, 0xA17F_3456_DF7B_F8C3,
        0x6DF7_2E19_41AE_F698, 0x7222_6F01_1E66_AB94, 0x3831_A3C6_0629_6B42,
        0xFD7F_F818_8133_2C89, 0x61A3_F647_4FF2_36C6,
    ]
    let mask: UInt64 = 0xA79A_63F5_85D3_7BF0

    let n = Int(challenge & 7)
    var v = challenge
    for _ in 0..<n { v = rol8(v) }

    let k: UInt64
    if (v & 1) == UInt64((0x78 >> n) & 1) {
        k = even[n]
    } else {
        v = v ^ rol8(v)
        k = odd[n]
    }
    return v ^ (rol8(v) & mask) ^ k
}

// MARK: - Events

public enum SpeedEditorEvent: Sendable, CustomStringConvertible {
    case jog(mode: SpeedEditorJogMode, value: Int32)
    case keys([SpeedEditorKey])
    case battery(charging: Bool, level: UInt8)
    case unknown(reportID: UInt8, data: [UInt8])

    public var description: String {
        switch self {
        case .keys(let keys):
            return "KEYS  " + (keys.isEmpty ? "— (all released)" : keys.map(\.label).joined(separator: " + "))
        case .jog(let mode, let value):
            let sign = value >= 0 ? "+" : ""
            return "JOG   [\(mode)] \(sign)\(value)"
        case .battery(let charging, let level):
            return "BATT  \(level)%\(charging ? " (charging)" : "")"
        case .unknown(let rid, let data):
            let hex = data.map { String(format: "%02x", $0) }.joined()
            return "???   report 0x\(String(format: "%02x", rid)): \(hex)"
        }
    }

    public static func parse(_ report: [UInt8]) -> SpeedEditorEvent? {
        guard let rid = report.first else { return nil }
        switch rid {
        case 0x03 where report.count >= 7:
            let u = UInt32(report[2])
                | UInt32(report[3]) << 8
                | UInt32(report[4]) << 16
                | UInt32(report[5]) << 24
            let mode = SpeedEditorJogMode(rawValue: report[1]) ?? .relative0
            return .jog(mode: mode, value: Int32(bitPattern: u))

        case 0x04 where report.count >= 13:
            var keys: [SpeedEditorKey] = []
            for i in stride(from: 1, to: 13, by: 2) {
                let code = UInt16(report[i]) | (UInt16(report[i + 1]) << 8)
                if let key = SpeedEditorKey(rawValue: code), key != .none {
                    keys.append(key)
                }
            }
            return .keys(keys)

        case 0x07 where report.count >= 3:
            return .battery(charging: report[1] != 0, level: report[2])

        default:
            return .unknown(reportID: rid, data: Array(report.dropFirst()))
        }
    }
}

// MARK: - Shared helpers

let speedTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

public func speedTimestamp() -> String {
    speedTimestampFormatter.string(from: Date())
}
