// DeviceSession.swift — long-lived Speed Editor connection.
//
// Owns a background thread with NON-BLOCKING reads (12 ms idle sleep), so a
// silent device can never wedge the daemon (observed hid_read_timeout hangs on
// BT virtual devices). Reconnects automatically when the device disappears
// (USB unplug / BT drop / Resolve grabbing it back) and re-applies
// auth + jog mode on every reconnect.
//
// The keyboard unlocks its reports for ~600 s per authentication, so the
// session re-authenticates on a timer to stay alive for days.
//
// THREADING: hidapi's enumerate/open/close schedule IOKit objects on the
// CALLING thread's CF run loop, and calling them from arbitrary/GCD threads
// crashed with EXC_BREAKPOINT inside CFRunLoopAddSource (corrupt run-loop
// state). So all control-plane hidapi work — enumerate, open, auth, jog mode,
// LED writes, close — runs on the MAIN thread (AppKit's permanent, healthy
// run loop; the configuration IOKit is designed for). Only the non-blocking
// poll loop stays on the dedicated session thread. Reconnect attempts back
// off (1 s → 2 s → 3 s → 5 s) so a flapping device never hammers enumerate.

import Foundation

public final class SpeedEditorSession {
    public var onKey: (([SpeedEditorKey]) -> Void)?
    public var onJog: ((SpeedEditorJogMode, Int32) -> Void)?
    public var onBattery: ((Bool, UInt8) -> Void)?
    /// true = device connected & authenticated, false = lost (will retry)
    public var onStatusChange: ((Bool) -> Void)?
    /// Diagnostic log line (called from the session thread; handler must be thread-safe).
    public var onLog: ((String) -> Void)?

    private let stateLock = NSLock()
    private var device: SpeedEditorHID?
    private var shouldRun = false
    private var isConnectedState = false
    private var thread: Thread?
    private var nextReauth = Date.distantFuture

    private let exited = DispatchSemaphore(value: 0)
    /// Device re-auth interval (device unlocks reports for ~600 s; re-auth well before).
    private let reauthInterval: TimeInterval = 480
    /// Reconnect backoff (resets on every successful connect).
    private var retryDelay: TimeInterval = 1.0

    /// Last interface that authenticated successfully (per transport try-loop).
    private var lastGoodUsagePage: UInt16?
    private var lastGoodUsage: UInt16?
    private var lastGoodInterface: Int?
    /// Connect-failure logging: first failure + every 10th after that.
    private var connectFailures = 0
    /// Unknown-report cadence counter (reset on every successful connect).
    private var unknownReports = 0

    public init() {}

    /// Runs `work` on the main thread (hidapi control-plane only).
    private func onMain<T>(_ work: @escaping () throws -> T) throws -> T {
        if Thread.isMainThread { return try work() }
        var out: Result<T, Error>?
        DispatchQueue.main.sync { out = Result { try work() } }
        switch out! {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }

    private func onMainAsync(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    public func start() {
        guard !shouldRun else { return }
        shouldRun = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "speedcolors-session"
        thread = t
        t.start()
    }

    public func stop() {
        stateLock.lock()
        shouldRun = false
        stateLock.unlock()
        // Join the session thread (bounded) so hidapi is never touched by two
        // threads — the restart path creates a fresh session immediately.
        _ = exited.wait(timeout: .now() + 3)
        thread = nil
    }

    // MARK: Outputs (main thread; no-ops while disconnected)

    /// Panel LED bitmask.
    public func setPanelLeds(_ leds: SpeedEditorLed) {
        onMainAsync { try? self.deviceRef()?.setLeds(leds) }
    }

    /// JOG/SHTL/SCRL dial LEDs.
    public func setDialLeds(_ leds: SpeedEditorJogLed) {
        onMainAsync { try? self.deviceRef()?.setJogLeds(leds) }
    }

    // MARK: Internals

    private func deviceRef() -> SpeedEditorHID? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return device
    }

    private func setDevice(_ newDevice: SpeedEditorHID?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        device = newDevice
    }

    private func setStatus(_ connected: Bool) {
        guard connected != isConnectedState else { return }
        isConnectedState = connected
        onStatusChange?(connected)
    }

    private func shouldKeepRunning() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shouldRun
    }

    /// Enumerate + open + auth + jog mode. MAIN THREAD ONLY.
    ///
    /// Both transports (BT virtual device, USB) enumerate several 1EDB:DA0E
    /// HID interfaces, and the one carrying the control reports is not
    /// necessarily first — USB interface order can differ from BT. So we try
    /// candidates in order, verifying each with a real open + auth handshake,
    /// and remember the winner so subsequent connects try it first.
    private func buildConnection() throws -> SpeedEditorHID {
        let candidates = SpeedEditorHID.deviceCandidates()
        guard !candidates.isEmpty else { throw HIDError.notFound }

        // Last-known-good interface first; the rest keep enumeration order.
        // (Deliberately not sorted: with no last-good yet, order must stay
        // exactly as enumerated — first interface worked over BT.)
        let ordered: [SpeedEditorHID.DeviceCandidate]
        if let lp = lastGoodUsagePage, let lu = lastGoodUsage, let li = lastGoodInterface,
           let good = candidates.first(where: { $0.usagePage == lp && $0.usage == lu && $0.interface == li }) {
            ordered = [good] + candidates.filter { $0.path != good.path }
        } else {
            ordered = candidates
        }

        var lastError: Error = HIDError.notFound
        for cand in ordered {
            let dev: SpeedEditorHID
            do {
                dev = try SpeedEditorHID(path: cand.path)
            } catch {
                lastError = error
                continue
            }
            do {
                try dev.authenticate()
            } catch {
                dev.close()
                lastError = error
                continue
            }
            // Winner — remember it for the next connect.
            lastGoodUsagePage = cand.usagePage
            lastGoodUsage = cand.usage
            lastGoodInterface = cand.interface
            // Absolute jog mode: reports become exact positions (-4096…4096 ≈
            // half a turn) so we can derive precise deltas. Falls back
            // gracefully if the device ignores it.
            try? dev.setJogMode(.absoluteContinuous)
            try? dev.setJogLeds(.jog)
            dev.setNonblocking(true)
            nextReauth = Date().addingTimeInterval(reauthInterval)
            return dev
        }
        throw lastError
    }

    /// Logs a connect failure: always for the first, then every 10th, so a
    /// missing device doesn't flood the log while retries continue.
    private func logConnectFailure(_ error: Error) {
        connectFailures += 1
        guard connectFailures == 1 || connectFailures % 10 == 0 else { return }
        let interfaces = SpeedEditorHID.describeDevices()
        onLog?("⚠️ connect failed (\(connectFailures)): \(error)  [\(interfaces)]")
    }

    private func closeOnMain(_ dev: SpeedEditorHID) {
        onMainAsync { dev.close() }
    }

    private func loop() {
        defer { exited.signal() }
        while shouldKeepRunning() {
            if deviceRef() == nil {
                do {
                    let d = try onMain { try self.buildConnection() }
                    setDevice(d)
                    setStatus(true)
                    retryDelay = 1.0
                    connectFailures = 0
                    unknownReports = 0
                } catch {
                    setStatus(false)
                    logConnectFailure(error)
                    Thread.sleep(forTimeInterval: retryDelay)
                    retryDelay = min(retryDelay * 2, 5.0)
                    continue
                }
            }
            guard let dev = deviceRef() else { continue }
            do {
                if let ev = try dev.pollNonBlocking() {
                    switch ev {
                    case .keys(let keys): onKey?(keys)
                    case .jog(let mode, let value): onJog?(mode, value)
                    case .battery(let charging, let level): onBattery?(charging, level)
                    case .unknown(let rid, _):
                        // Silent drops made invisible reports undebuggable
                        // (e.g. combined key+jog reports while a key is held).
                        // Log the first, then every 50th, as a cadence probe.
                        unknownReports += 1
                        if unknownReports == 1 || unknownReports % 50 == 0 {
                            onLog?("· unknown HID report 0x\(String(format: "%02X", rid)) ×\(unknownReports)")
                        }
                    }
                } else {
                    Thread.sleep(forTimeInterval: 0.012)
                }
                if Date() >= nextReauth {
                    do {
                        try onMain {
                            try dev.authenticate()
                            print("· re-authenticated (timer)")
                            fflush(stdout)
                        }
                        nextReauth = Date().addingTimeInterval(reauthInterval)
                    } catch {
                        // Not fatal: the device may just be slow to answer. It
                        // stays unlocked for ~600 s per auth, so warn and retry
                        // on the next interval instead of tearing the session down.
                        print("⚠️  re-auth failed: \(error) — device may go silent until reconnect")
                        fflush(stdout)
                        nextReauth = Date().addingTimeInterval(30)
                    }
                }
            } catch {
                // Device lost — release and retry until it reappears.
                closeOnMain(dev)
                if deviceRef() === dev { setDevice(nil) }
                setStatus(false)
                nextReauth = .distantFuture
                Thread.sleep(forTimeInterval: retryDelay)
                retryDelay = min(retryDelay * 2, 5.0)
            }
        }
        if let dev = deviceRef() { closeOnMain(dev) }
        setDevice(nil)
        setStatus(false)
    }
}

