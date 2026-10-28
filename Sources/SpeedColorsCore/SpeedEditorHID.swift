// SpeedEditorHID.swift — USB transport over hidapi (VID 0x1EDB / PID 0xDA0E).
//
// Opens the device in *shared* mode (no seize) so Resolve can keep reading the
// same reports concurrently — the pass-through architecture relies on this.

import CHid
import Foundation

public enum HIDError: Error, CustomStringConvertible {
    case notFound
    case openFailed
    case writeFailed
    case readFailed
    case authFailed(String)

    public var description: String {
        switch self {
        case .notFound:
            return "Speed Editor not found on USB (VID 1EDB / PID DA0E)"
        case .openFailed: return "failed to open HID device"
        case .writeFailed: return "HID write failed"
        case .readFailed: return "HID read failed"
        case .authFailed(let step): return "authentication failed at: \(step)"
        }
    }
}

public final class SpeedEditorHID {
    private let dev: OpaquePointer
    private var isClosed = false
    private static var hidInitialized = false

    private static func ensureInit() {
        if !hidInitialized {
            _ = hid_init()
            hidInitialized = true
        }
    }

    /// Path of the first matching Speed Editor HID device, if present.
    public static func firstDevicePath() -> String? {
        ensureInit()
        guard let first = hid_enumerate(0x1EDB, 0xDA0E) else { return nil }
        defer { hid_free_enumeration(first) }
        return String(cString: first.pointee.path)
    }

    /// One hidapi enumeration entry, simplified.
    public struct DeviceCandidate {
        public let path: String
        public let usagePage: UInt16
        public let usage: UInt16
        public let interface: Int
    }

    /// All 1EDB:DA0E HID interfaces currently present (BT virtual device and
    /// USB both enumerate 9 of them; usage pages 0xFF00–0xFF07 are the
    /// proprietary control interfaces).
    public static func deviceCandidates() -> [DeviceCandidate] {
        ensureInit()
        guard let first = hid_enumerate(0x1EDB, 0xDA0E) else { return [] }
        defer { hid_free_enumeration(first) }
        var out: [DeviceCandidate] = []
        var cur: UnsafeMutablePointer<hid_device_info>? = first
        while let p = cur {
            out.append(DeviceCandidate(
                path: String(cString: p.pointee.path),
                usagePage: p.pointee.usage_page,
                usage: p.pointee.usage,
                interface: Int(p.pointee.interface_number)))
            cur = p.pointee.next
        }
        return out
    }

    /// Human-readable dump of every enumerated interface (diagnostics).
    public static func describeDevices() -> String {
        let all = deviceCandidates()
        guard !all.isEmpty else { return "no 1EDB:DA0E interfaces found" }
        return all.map { d in
            String(format: "if%02d usage 0x%04X/0x%04X", d.interface, d.usagePage, d.usage)
        }.joined(separator: "  ·  ")
    }

    public init(path: String) throws {
        Self.ensureInit()
        guard let d = hid_open_path(path) else { throw HIDError.openFailed }
        dev = d
    }

    deinit { close() }

    /// Release the device handle (single-client devices: do this promptly).
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        hid_close(dev)
    }

    // MARK: Control reports

    /// Perform the proprietary handshake. Returns the re-auth timeout (seconds).
    @discardableResult
    public func authenticate() throws -> Int {
        // 1. Reset the auth state machine
        try sendFeature([0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        // 2. Read the keyboard's challenge
        let challengeData = try getFeature(6, length: 10)
        guard challengeData.count >= 10, challengeData[1] == 0x00 else {
            throw HIDError.authFailed("get challenge (\(challengeData.hex))")
        }
        var challenge: UInt64 = 0
        for i in 0..<8 { challenge |= UInt64(challengeData[2 + i]) << (8 * UInt64(i)) }

        // 3. Send our challenge (we skip verifying the keyboard's response)
        try sendFeature([0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let response = try getFeature(6, length: 10)
        guard response.count >= 10, response[1] == 0x02 else {
            throw HIDError.authFailed("get keyboard response (\(response.hex))")
        }

        // 4. Send our computed response
        let answer = bmdKbdAuth(challenge)
        var msg: [UInt8] = [0x06, 0x03]
        for i in 0..<8 { msg.append(UInt8((answer >> (8 * UInt64(i))) & 0xFF)) }
        try sendFeature(msg)

        // 5. Read the status
        let status = try getFeature(6, length: 10)
        guard status.count >= 4, status[1] == 0x04 else {
            throw HIDError.authFailed("get status (\(status.hex))")
        }
        return Int(status[2]) | (Int(status[3]) << 8)
    }

    public func setLeds(_ leds: SpeedEditorLed) throws {
        let v = leds.rawValue
        try write([0x02, UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
                   UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)])
    }

    public func setJogLeds(_ leds: SpeedEditorJogLed) throws {
        try write([0x04, leds.rawValue])
    }

    public func setJogMode(_ mode: SpeedEditorJogMode, unknown: UInt8 = 255) throws {
        try write([0x03, mode.rawValue, 0, 0, 0, 0, unknown])
    }

    // MARK: Input

    /// Switch the device handle to non-blocking mode (for daemon read loops —
    /// avoids hid_read_timeout's blocking quirks on BT virtual devices).
    public func setNonblocking(_ on: Bool) {
        hid_set_nonblocking(dev, on ? 1 : 0)
    }

    /// Non-blocking read: returns the parsed event, or nil if nothing queued.
    public func pollNonBlocking() throws -> SpeedEditorEvent? {
        guard !isClosed else { throw HIDError.readFailed }
        var buf = [UInt8](repeating: 0, count: 64)
        let n = buf.withUnsafeMutableBufferPointer { ptr in
            hid_read(dev, ptr.baseAddress, 64)
        }
        guard n >= 0 else { throw HIDError.readFailed }
        guard n > 0 else { return nil }
        return SpeedEditorEvent.parse(Array(buf[0..<Int(n)]))
    }

    /// Blocking read with timeout; returns the parsed event or nil on timeout.
    public func poll(timeoutMs: Int32) throws -> SpeedEditorEvent? {
        var buf = [UInt8](repeating: 0, count: 64)
        let n = buf.withUnsafeMutableBufferPointer { ptr in
            hid_read_timeout(dev, ptr.baseAddress, 64, timeoutMs)
        }
        guard n >= 0 else { throw HIDError.readFailed }
        guard n > 0 else { return nil }
        return SpeedEditorEvent.parse(Array(buf[0..<Int(n)]))
    }

    // MARK: Low-level

    private func write(_ bytes: [UInt8]) throws {
        guard !isClosed else { throw HIDError.writeFailed }
        guard hid_write(dev, bytes, bytes.count) >= 0 else { throw HIDError.writeFailed }
    }

    private func sendFeature(_ bytes: [UInt8]) throws {
        guard !isClosed else { throw HIDError.writeFailed }
        guard hid_send_feature_report(dev, bytes, bytes.count) >= 0 else { throw HIDError.writeFailed }
    }

    private func getFeature(_ reportID: UInt8, length: Int) throws -> [UInt8] {
        guard !isClosed else { throw HIDError.readFailed }
        var buf = [UInt8](repeating: 0, count: length)
        buf[0] = reportID
        let n = buf.withUnsafeMutableBufferPointer { ptr in
            hid_get_feature_report(dev, ptr.baseAddress, length)
        }
        guard n >= 0 else { throw HIDError.readFailed }
        return Array(buf[0..<Int(n)])
    }
}

extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
