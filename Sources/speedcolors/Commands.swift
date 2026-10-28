// speedcolors — CLI entry point.
// Phase 0 commands: USB smoke tests + Bluetooth discovery spike + page query.

import ArgumentParser
import CHid
import Foundation
import SpeedColorsCore

@main
struct SpeedColors: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speedcolors",
        abstract: "DaVinci Resolve Speed Editor → Color page controller",
        subcommands: [Run.self, Autocal.self, Coords.self, Status.self, Events.self, LedsDemo.self, Hold.self, HidList.self, HidProbe.self, BleScan.self, BleDump.self, Page.self]
    )
}

// MARK: - Helpers

// MARK: - Helpers

/// hidapi device-info strings are `wchar_t*` (UTF-32 on macOS) — decode to String.
private func wcharString(_ p: UnsafeMutablePointer<Int32>?) -> String {
    guard let p else { return "-" }
    var out = ""
    var i = 0
    while p[i] != 0 {
        if let scalar = Unicode.Scalar(UInt32(bitPattern: Int32(p[i]))) {
            out.unicodeScalars.append(scalar)
        }
        i += 1
    }
    return out
}

private func openAndAuthenticate() throws -> SpeedEditorHID {
    guard let path = SpeedEditorHID.firstDevicePath() else {
        print("✗ Speed Editor not found on USB/BT (VID 1EDB / PID DA0E).")
        print("  → Plug it in via USB-C, or connect it via Bluetooth.")
        throw ExitCode.failure
    }
    print("✓ Found Speed Editor")
    let se = try SpeedEditorHID(path: path)
    let timeout = try se.authenticate()
    print("✓ Authentication OK (re-auth window ≈ \(timeout)s)")
    return se
}

/// Guarantee the command exits after `seconds` even if hidapi blocks forever
/// (observed with BT virtual devices), and always releases the device.
private func withWatchdog(_ seconds: Double?, _ body: (SpeedEditorHID) throws -> Void) throws {
    let se = try openAndAuthenticate()
    defer { se.close() }
    if let seconds {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            print("\n(window closed)")
            fflush(stdout)
            exit(0)
        }
    }
    try body(se)
}

// MARK: - HID enumeration

struct HidList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-hid",
        abstract: "List all HID devices visible via IOKit/hidapi (USB + Bluetooth virtual devices)")

    mutating func run() throws {
        _ = hid_init()
        guard let head = hid_enumerate(0, 0) else {
            print("(no HID devices found)")
            return
        }
        defer { hid_free_enumeration(head) }

        var e: UnsafeMutablePointer<hid_device_info>? = head
        var count = 0
        while let dev = e {
            let info = dev.pointee
            count += 1
            let serial = wcharString(info.serial_number)
            let product = wcharString(info.product_string)
            let mfr = wcharString(info.manufacturer_string)
            let path = info.path.map { String(cString: $0) } ?? "-"
            let tail = path.count > 60 ? String(path.suffix(60)) : path
            let star = (info.vendor_id == 0x1EDB && info.product_id == 0xDA0E) ? "★" : " "
            let vid = String(format: "%04x", info.vendor_id)
            let pid = String(format: "%04x", info.product_id)
            let up = String(format: "0x%04x", info.usage_page)
            let us = String(format: "0x%04x", info.usage)
            print("\(star) \(vid):\(pid)  usage_page \(up)  usage \(us)  iface \(info.interface_number)  ser '\(serial)'  product '\(product)'  mfr '\(mfr)'  path …\(tail)")
            e = info.next
        }
        print("(\(count) HID interfaces)")
    }
}

// MARK: - USB commands

struct HidProbe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe-hid",
        abstract: "Try opening every Speed Editor HID interface (diagnoses exclusive access)")

    mutating func run() throws {
        _ = hid_init()
        guard let head = hid_enumerate(0x1EDB, 0xDA0E) else {
            print("(no Speed Editor HID devices present)")
            return
        }
        defer { hid_free_enumeration(head) }
        var e: UnsafeMutablePointer<hid_device_info>? = head
        var ok = 0, fail = 0
        while let dev = e {
            let info = dev.pointee
            let path = String(cString: info.path)
            let up = String(format: "0x%04x", info.usage_page)
            let us = String(format: "0x%04x", info.usage)
            if let d = hid_open_path(path) {
                hid_close(d)
                print("✓ open OK    usage_page \(up)  usage \(us)")
                ok += 1
            } else {
                print("✗ open FAIL  usage_page \(up)  usage \(us)")
                fail += 1
            }
            e = info.next
        }
        print("(\(ok) opened, \(fail) blocked)")
    }
}

struct Hold: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Hold the Speed Editor exclusively for N seconds, then release it (handoff experiment)")

    @Option(name: .shortAndLong, help: "Seconds to hold before releasing")
    var seconds: Double = 12

    mutating func run() throws {
        let se = try openAndAuthenticate()
        defer { se.close() }
        print("Holding exclusively for \(Int(seconds))s — keys should do NOTHING in Resolve now…")
        fflush(stdout)
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if let ev = try se.poll(timeoutMs: 100) {
                print("\(speedTimestamp())  \(ev)")
                fflush(stdout)
            }
        }
        se.close()
        print("✅ RELEASED — device is free.")
        print("   Now press IN / OUT on the Speed Editor:")
        print("   does Resolve respond WITHOUT restarting Resolve?")
        fflush(stdout)
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open the Speed Editor on USB, authenticate, report battery")

    mutating func run() throws {
        let se = try openAndAuthenticate()
        var battery: (charging: Bool, level: UInt8)?
        print("Waiting for a battery report (up to 6 s)…")
        let start = Date()
        while battery == nil && Date().timeIntervalSince(start) < 6 {
            if let ev = try se.poll(timeoutMs: 200), case .battery(let c, let l) = ev {
                battery = (c, l)
            }
        }
        if let b = battery {
            print("✓ Battery: \(b.level)%\(b.charging ? " (charging)" : "")")
        } else {
            print("· No battery report yet (normal on USB power); LEDs auth path verified anyway")
        }
    }
}

struct Events: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print live key / dial / battery events from the Speed Editor")

    @Option(name: .shortAndLong, help: "Auto-stop after N seconds (omit to run until Ctrl-C)")
    var duration: Double?

    mutating func run() throws {
        let se = try openAndAuthenticate()
        print("Listening — press buttons / turn the dial… (Ctrl-C to stop)")
        let start = Date()
        var jogCount = 0
        var keyCount = 0
        while true {
            if let d = duration, Date().timeIntervalSince(start) >= d { break }
            if let ev = try se.poll(timeoutMs: 100) {
                print("\(speedTimestamp())  \(ev)")
                switch ev {
                case .jog: jogCount += 1
                case .keys: keyCount += 1
                default: break
                }
            }
        }
        print("\ncaptured: \(keyCount) key reports, \(jogCount) jog reports")
    }
}

struct LedsDemo: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Walk every panel LED so you can verify the mapping visually")

    @Option(name: .shortAndLong, help: "Seconds per LED")
    var speed: Double = 0.5

    mutating func run() throws {
        let se = try openAndAuthenticate()
        print("LED chase — watch the panel! (panel LEDs, then JOG/SHTL/SCRL)")
        for led in SpeedEditorLed.allInOrder {
            print("  \(led.label)")
            try se.setLeds(led)
            Thread.sleep(forTimeInterval: speed)
        }
        try se.setLeds([])
        for led in SpeedEditorJogLed.allInOrder {
            print("  jog-mode LED bit \(led.rawValue)")
            try se.setJogLeds(led)
            Thread.sleep(forTimeInterval: speed)
        }
        try se.setJogLeds([])
        print("Done — LEDs off.")
    }
}

// MARK: - Bluetooth spike

struct BleScan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan Bluetooth LE and list advertised devices (find the Speed Editor)")

    @Option(name: .shortAndLong, help: "Scan duration in seconds")
    var duration: Double = 15

    mutating func run() throws {
        BLEExplorer(mode: .scanOnly, timeout: duration, logPath: nil).run()
    }
}

struct BleDump: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Connect to the Speed Editor over BLE, dump GATT, log notifications")

    @Option(name: .shortAndLong, help: "Total duration in seconds")
    var duration: Double = 40

    @Option(name: .shortAndLong, help: "Log file path")
    var log: String = "tools/ble-dump.log"

    mutating func run() throws {
        BLEExplorer(mode: .fullDump, timeout: duration, logPath: log).run()
    }
}

// MARK: - Daemon

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the speedcolors daemon — owns the Speed Editor; mirrors Cut/Edit, custom control on Color")

    @Option(name: .shortAndLong, help: "Jog units per arrow-key tap (calibration)")
    var jogStep: Int = 800

    mutating func run() throws {
        guard EventInjector.isAccessibilityGranted() else {
            print(EventInjector.accessibilityInstructions)
            throw ExitCode.failure
        }
        print("speedcolors daemon starting…")
        print("  Quitting this process releases the Speed Editor back to Resolve (stock behavior).")
        let daemon = SpeedColorsDaemon(config: DaemonConfig(jogUnitsPerArrow: jogStep))

        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            print("\nshutting down — releasing the Speed Editor…")
            fflush(stdout)
            daemon.stop()
            Thread.sleep(forTimeInterval: 0.3)  // let the session thread release the device
            Foundation.exit(0)
        }
        sigint.resume()
        _ = sigint

        daemon.start()
        print("running — press keys on the Speed Editor (Ctrl-C to stop)")
        fflush(stdout)
        dispatchMain()
    }
}

// MARK: - Color page calibration

struct Autocal: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autocal",
        abstract: "Auto-detect Color-page controls via OCR and save their positions")

    @Flag(name: .shortAndLong, help: "Overwrite existing targets too (default: only fill missing ones)")
    var force = false

    @Flag(name: .shortAndLong, help: "Print every text region OCR found (for tuning)")
    var debug = false

    mutating func run() throws {
        print("Capturing the Resolve window…")
        fflush(stdout)
        do {
            let result = try AutoCal.calibrate(force: force, debug: debug)
            if debug {
                print("— all OCR regions —")
                for (text, bb) in result.observations {
                    print("  '\(text)'  @ (\(Int(bb.midX * 100))%, \(Int((1 - bb.midY) * 100))%)")
                }
            }
            print("✓ OCR read \(result.regions) text regions")
            if result.matched.isEmpty {
                print("· No known control labels found.")
                print("  → Open the Color page with the primaries (wheels) palette visible, then retry.")
            } else {
                for m in result.matched.sorted(by: { $0.name < $1.name }) {
                    let state: String
                    if result.derived.contains(m.name) { state = "derived (geometry)" }
                    else if result.updated.contains(m.name) { state = "saved" }
                    else if result.kept.contains(m.name) { state = "kept existing (use --force to overwrite)" }
                    else { state = "skipped" }
                    print("  • \(m.name) ← \"\(m.text)\"  [\(state)]")
                }
                let known = AutoCal.wanted.map(\.name)
                let found = Set(result.matched.map(\.name))
                let missing = known.filter { !found.contains($0) }
                if !missing.isEmpty {
                    print("· Not found (calibrate manually with 'coords --save <name>' if needed):")
                    print("    \(missing.joined(separator: ", "))")
                }
            }
            print("✓ Targets saved to \(ColorModeConfig.defaultPath.path)")
            print("✓ Annotated screenshot: \(result.pngURL.path)")
            print("  → Open it and verify the red boxes sit on the right controls.")
        } catch let e as AutoCalError {
            print("✗ \(e)")
            throw ExitCode.failure
        }
    }
}

struct Coords: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "coords",
        abstract: "Calibrate Color-page targets — record cursor positions for the daemon")

    @Option(name: .shortAndLong, help: "Save the current cursor position under this name (lift, gamma, gain, curves, …)")
    var save: String?

    @Option(name: .long, help: "Remove a saved target (fixes bad autocal matches)")
    var remove: String?

    @Flag(name: .shortAndLong, help: "Print saved targets")
    var list = false

    mutating func run() throws {
        if let name = remove {
            var cfg = ColorModeConfig.load()
            if cfg.removeTarget(named: name) {
                try cfg.save()
                print("✓ removed '\(name)'")
            } else {
                print("· '\(name)' was not saved")
            }
            return
        }
        if list {
            let cfg = ColorModeConfig.load()
            if cfg.targets.isEmpty {
                print("(no targets saved yet — try: speedcolors coords --save lift)")
            }
            for (name, t) in cfg.targets.sorted(by: { $0.key < $1.key }) {
                print("  \(name): (\(Int(t.x)), \(Int(t.y)))")
            }
            print("  pixelsPerUnit: \(cfg.pixelsPerUnit)")
            return
        }
        if let name = save {
            print("Move the cursor over '\(name)' — recording in 3 s…")
            for i in stride(from: 3, through: 1, by: -1) {
                print("  \(i)…")
                fflush(stdout)
                Thread.sleep(forTimeInterval: 1)
            }
            let p = MouseController.currentPosition()
            var cfg = ColorModeConfig.load()
            cfg.targets[name] = ColorTarget(x: p.x, y: p.y)
            try cfg.save()
            print("✓ \(name) = (\(Int(p.x)), \(Int(p.y)))  →  \(ColorModeConfig.defaultPath.path)")
            return
        }
        print("Live cursor position — move the mouse (Ctrl-C to stop):")
        while true {
            let p = MouseController.currentPosition()
            print("\r  (\(Int(p.x)), \(Int(p.y)))    ", terminator: "")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 0.15)
        }
    }
}

// MARK: - Resolve

struct Page: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Ask the running Resolve which page is active (via the Python sidecar)")

    @Option(help: "Path to resolve_page_agent.py")
    var script: String = ResolveAgent.defaultScriptPath

    mutating func run() throws {
        guard let info = try ResolveAgent.queryPage(script: script) else {
            print("Resolve is not running (or the scripting bridge couldn't reach it).")
            return
        }
        print("✓ \(info)")
    }
}
