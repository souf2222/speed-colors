// BLEExplorer.swift — Phase-0 spike: discover the Speed Editor over Bluetooth LE.
//
// Scans, identifies the Speed Editor advertisement, connects (while Resolve may
// also be connected — that's the concurrency test), walks the GATT tree,
// subscribes to every notify/indicate characteristic and hex-dumps the values.

import CoreBluetooth
import Foundation

public final class BLEExplorer: NSObject {
    public enum Mode { case scanOnly, fullDump }

    private let mode: Mode
    private let timeout: TimeInterval
    private let logPath: String?

    private var central: CBCentralManager?
    private var target: CBPeripheral?
    private var printedCount = 0
    private var gattLog: [String] = []
    private var notifyCount = 0

    public init(mode: Mode, timeout: TimeInterval, logPath: String?) {
        self.mode = mode
        self.timeout = timeout
        self.logPath = logPath
        super.init()
    }

    public func run() {
        print("[BLE] mode: \(mode == .scanOnly ? "scan only" : "connect + GATT dump + notify") (\(Int(timeout))s)")
        if let lp = logPath { print("[BLE] notification log → \(lp)") }
        print("[BLE] scanning… (put the Speed Editor in Bluetooth pairing mode if it isn't visible)")
        central = CBCentralManager(delegate: self, queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish()
        }
        RunLoop.main.run()
    }

    private func finish() {
        print("\n──── summary ────")
        print("devices advertised: \(printedCount)")
        print("notifications received: \(notifyCount)")
        for line in gattLog { print(line) }
        print("[BLE] done")
        exit(0)
    }

    private func appendLog(_ line: String) {
        gattLog.append(line)
        guard let lp = logPath else { return }
        let url = URL(fileURLWithPath: lp)
        if !FileManager.default.fileExists(atPath: lp) {
            FileManager.default.createFile(atPath: lp, contents: nil)
        }
        if let fh = FileHandle(forWritingAtPath: lp) {
            fh.seekToEndOfFile()
            fh.write((line + "\n").data(using: .utf8)!)
            try? fh.close()
        }
    }
}

extension BLEExplorer: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("[BLE] Bluetooth powered on — scanning…")
            central.scanForPeripherals(withServices: nil, options: nil)
        case .poweredOff:
            print("✗ Bluetooth is turned off (System Settings → Bluetooth)"); exit(1)
        case .unauthorized:
            print("✗ Bluetooth permission denied. Allow the terminal app in System Settings → Privacy & Security → Bluetooth, then re-run."); exit(1)
        case .unsupported:
            print("✗ Bluetooth LE unsupported on this machine"); exit(1)
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "(unnamed)"
        let isCandidate = name.lowercased().contains("speed editor")
            || name.lowercased().contains("davinci")
            || name.lowercased().contains("blackmagic")
        guard isCandidate || printedCount < 30 else { return }
        printedCount += 1

        var line = "[adv] \(name)  rssi \(RSSI)"
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? (Data, NSNumber) {
            line += "  mfg[" + String(format: "0x%04x", mfg.1.uint16Value) + "] " + mfg.0.hex
        }
        if let svcs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            line += "  svcs " + svcs.map(\.uuidString).joined(separator: ",")
        }
        print(line)

        guard mode == .fullDump, target == nil, isCandidate else { return }
        target = peripheral
        print("\n[BLE] → connecting to '\(name)' …")
        print("[BLE]    (Resolve holding a connection at the same time = the multi-central test)")
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[BLE] ✓ connected — discovering GATT tree…")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[BLE] ✗ CONNECT FAILED: \(error?.localizedDescription ?? "unknown error")")
        print("[BLE] → likely single-central device; Resolve owns the link (or pairing needed).")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[BLE] disconnected: \(error?.localizedDescription ?? "clean")")
    }
}

extension BLEExplorer: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { print("[GATT] service discovery error: \(e)") }
        for svc in peripheral.services ?? [] {
            print("[GATT] service \(svc.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: svc)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let e = error { print("[GATT] characteristic discovery error: \(e)") }
        for ch in service.characteristics ?? [] {
            var props: [String] = []
            if ch.properties.contains(.read) { props.append("read") }
            if ch.properties.contains(.write) { props.append("write") }
            if ch.properties.contains(.writeWithoutResponse) { props.append("writeNR") }
            if ch.properties.contains(.notify) { props.append("notify") }
            if ch.properties.contains(.indicate) { props.append("indicate") }
            let line = "    char \(ch.uuid.uuidString)  [\(props.joined(separator: " "))]"
            print(line)
            appendLog(line)
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: ch)
            }
            if ch.properties.contains(.read) {
                peripheral.readValue(for: ch)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value ?? Data()
        let line = "\(speedTimestamp()) [value] \(characteristic.uuid.uuidString) = \(value.hex) (\(value.count) bytes)"
        print(line)
        notifyCount += 1
        appendLog(line)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            print("[notify] subscribe FAILED \(characteristic.uuid.uuidString): \(e)")
        } else {
            print("[notify] subscribed \(characteristic.uuid.uuidString)")
        }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
