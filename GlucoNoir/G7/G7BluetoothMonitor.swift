//
//  G7BluetoothMonitor.swift
//  GlucoNoir
//
//  Phase 1 spike: connect to the G7 over BLE and observe glucose messages.
//
//  This is passive observation. The official Dexcom app owns pairing and
//  session management; we subscribe to the control characteristic and read the
//  messages the sensor already transmits. We never write to the sensor.
//

import Foundation
import Combine
import CoreBluetooth

@MainActor
final class G7BluetoothMonitor: NSObject, ObservableObject {

    // MARK: Published state

    enum ConnectionState: String {
        case bluetoothOff  = "Bluetooth off"
        case unauthorized  = "Permission denied"
        case scanning      = "Scanning"
        case connecting    = "Connecting"
        case connected     = "Connected"
        case disconnected  = "Disconnected"
    }

    @Published private(set) var state: ConnectionState = .scanning
    @Published private(set) var latest: G7GlucoseMessage?
    @Published private(set) var latestReceivedAt: Date?
    @Published private(set) var sensorName: String?
    @Published private(set) var readingCount = 0
    /// Wall-clock time the sensor session started, derived from message timestamps.
    @Published private(set) var sessionStart: Date?

    // MARK: Private

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Held back until the official app's session is observed as authenticated.
    private var controlCharacteristic: CBCharacteristic?
    private var isSubscribedToControl = false
    private let restoreID = "com.joshscott.GlucoNoir.g7monitor"
    private let log = SpikeLog.shared

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: nil, // main queue; the spike does no heavy work in callbacks
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: restoreID,
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
    }

    /// Age of the newest reading, measured from the sensor's own `age` field
    /// plus elapsed time since we received it.
    var currentAge: TimeInterval? {
        guard let latest, let latestReceivedAt else { return nil }
        return Date().timeIntervalSince(latestReceivedAt) + TimeInterval(latest.age)
    }

    private func startScanning() {
        guard central.state == .poweredOn else { return }
        state = .scanning
        log.log(.info, "Scanning for G7 (service \(G7UUID.advertisement.uuidString))")
        central.scanForPeripherals(
            withServices: [G7UUID.advertisement],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
}

// MARK: - CBCentralManagerDelegate

extension G7BluetoothMonitor: CBCentralManagerDelegate {

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // iOS relaunched us in the background and handed the session back.
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        Task { @MainActor in
            self.log.log(.info, "Restored by system with \(peripherals.count) peripheral(s)")
            if let p = peripherals.first {
                self.peripheral = p
                p.delegate = self
                self.sensorName = p.name
                self.state = p.state == .connected ? .connected : .connecting
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.log.log(.info, "Bluetooth ready")
                if let p = self.peripheral, p.state == .connected {
                    p.discoverServices([G7UUID.cgmService])
                } else {
                    self.startScanning()
                }
            case .poweredOff:
                self.state = .bluetoothOff
                self.log.log(.error, "Bluetooth powered off")
            case .unauthorized:
                self.state = .unauthorized
                self.log.log(.error, "Bluetooth permission denied")
            default:
                self.log.log(.info, "Bluetooth state: \(central.state.rawValue)")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName
        guard G7Name.matches(name) else { return }

        Task { @MainActor in
            guard self.peripheral == nil else { return }
            self.log.log(.connection, "Found \(name ?? "?") rssi \(RSSI)")
            self.peripheral = peripheral
            self.sensorName = name
            peripheral.delegate = self
            self.state = .connecting
            central.stopScan()
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.state = .connected
            self.sensorName = peripheral.name ?? self.sensorName
            self.log.log(.connection, "Connected to \(peripheral.name ?? "?")")
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.log.log(.error, "Connect failed: \(error?.localizedDescription ?? "unknown")")
            self.peripheral = nil
            self.startScanning()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.state = .disconnected
            self.controlCharacteristic = nil
            self.isSubscribedToControl = false
            let reason = error?.localizedDescription ?? "clean"
            self.log.log(.connection, "Disconnected (\(reason)) — reconnecting")
            // The sensor drops the link between transmissions; reconnect immediately.
            central.connect(peripheral, options: nil)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension G7BluetoothMonitor: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                self.log.log(.error, "Service discovery: \(error.localizedDescription)")
                return
            }
            self.log.log(.info, "services: \((peripheral.services ?? []).map { $0.uuid.uuidString.prefix(8) }.joined(separator: ", "))")
            for service in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                self.log.log(.error, "Characteristic discovery: \(error.localizedDescription)")
                return
            }
            // Diagnostic mode: subscribe to everything notifiable and report
            // exactly what the sensor exposes, so we can see whether the link is
            // silent or our subscriptions are simply not taking.
            for c in service.characteristics ?? [] {
                if c.uuid == G7UUID.control { self.controlCharacteristic = c }
                let p = c.properties
                var flags: [String] = []
                if p.contains(.notify)   { flags.append("notify") }
                if p.contains(.indicate) { flags.append("indicate") }
                if p.contains(.read)     { flags.append("read") }
                if p.contains(.write)    { flags.append("write") }
                if p.contains(.writeWithoutResponse) { flags.append("writeNoRsp") }
                self.log.log(.info, "char \(self.label(c.uuid)) [\(flags.joined(separator: ","))]")

                if p.contains(.notify) || p.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: c)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        let uuid = characteristic.uuid
        let on = characteristic.isNotifying
        Task { @MainActor in
            if let error {
                self.log.log(.error, "NOTIFY FAILED \(self.label(uuid)): \(error.localizedDescription)")
            } else {
                self.log.log(.info, "notify=\(on) confirmed for \(self.label(uuid))")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let data = characteristic.value
        let uuid = characteristic.uuid
        Task { @MainActor in
            if let error {
                self.log.log(.error, "Value update: \(error.localizedDescription)")
                return
            }
            guard let data, !data.isEmpty else { return }

            // Log every frame regardless of source while diagnosing.
            self.log.log(.info, "RX \(self.label(uuid)) \(data.map { String(format: "%02x", $0) }.joined())")

            if uuid == G7UUID.authentication {
                self.handleAuthResponse(data, on: peripheral)
                return
            }

            guard uuid == G7UUID.control else { return }
            guard data[data.startIndex] == G7Opcode.glucoseTx.rawValue else { return }

            guard let message = G7GlucoseMessage(data: data) else {
                self.log.log(.error, "Undecodable 0x4e payload: \(data.map { String(format: "%02x", $0) }.joined())")
                return
            }
            self.handle(message)
        }
    }

    fileprivate func label(_ uuid: CBUUID) -> String {
        switch uuid {
        case G7UUID.control:        return "control"
        case G7UUID.authentication: return "auth"
        case G7UUID.communication:  return "comm"
        case G7UUID.backfill:       return "backfill"
        default:                    return String(uuid.uuidString.prefix(8))
        }
    }

    private func handleAuthResponse(_ data: Data, on peripheral: CBPeripheral) {
        guard let auth = G7AuthChallengeMessage(data: data) else { return }
        guard auth.sessionReady else {
            log.log(.info, "Auth observed: authenticated=\(auth.isAuthenticated) bonded=\(auth.isBonded) — waiting")
            return
        }
        guard !isSubscribedToControl, let control = controlCharacteristic else { return }

        isSubscribedToControl = true
        peripheral.setNotifyValue(true, for: control)
        log.log(.info, "Session authenticated — subscribed to control, expecting glucose")
    }

    private func handle(_ m: G7GlucoseMessage) {
        latest = m
        latestReceivedAt = Date()
        readingCount += 1
        // Session start = now minus seconds-since-pairing carried in the message.
        sessionStart = Date().addingTimeInterval(-TimeInterval(m.messageTimestamp))

        let value = m.glucose.map(String.init) ?? "—"
        let pred = m.predicted.map { " pred \($0)" } ?? ""
        let rate = m.trendRate.map { String(format: " %+.1f/min", $0) } ?? ""
        log.log(.reading,
                "\(value) mg/dL \(m.trendArrow)\(rate)\(pred) | age \(m.age)s | seq \(m.sequence) | \(m.stateDescription)\(m.hasReliableGlucose ? "" : " [UNRELIABLE]")")
    }
}
