import Foundation
import CoreBluetooth
import Observation

/// Bluetooth link to the puck. Implements the contract from the build sheet:
///
///   service  7A0B0001-…   advertised
///   IMU      7A0B0002-…   notify, 8 bytes: int16 ax, ay, az at 8192 counts/g, uint16 sequence
///   haptic   7A0B0003-…   write without response, 1 byte amplitude 0...127
///   battery  0x180F / 0x2A19  standard battery level
///
/// All CoreBluetooth callbacks arrive on the main queue, so the observable state
/// here is only ever touched from the main thread.
@Observable
final class PuckBLE: NSObject, MotionSource, HapticSink {
    enum UUIDs {
        static let service    = CBUUID(string: "7A0B0001-6F3C-4D2E-9B1A-0B7E47B5C001")
        static let imu        = CBUUID(string: "7A0B0002-6F3C-4D2E-9B1A-0B7E47B5C001")
        static let haptic     = CBUUID(string: "7A0B0003-6F3C-4D2E-9B1A-0B7E47B5C001")
        static let battery    = CBUUID(string: "180F")
        static let batteryLvl = CBUUID(string: "2A19")
    }

    enum State: String { case off, scanning, connecting, connected, disconnected }

    let name = "Breath Puck"
    private(set) var state = State.off
    private(set) var batteryPercent: Int?
    private(set) var packetsReceived = 0
    private(set) var packetsDropped = 0
    private(set) var lastError: String?
    private(set) var rssi: Int?

    @ObservationIgnored var onSample: ((AccelSample) -> Void)?

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var imuChar: CBCharacteristic?
    @ObservationIgnored private var hapticChar: CBCharacteristic?
    @ObservationIgnored private var batteryChar: CBCharacteristic?
    @ObservationIgnored private var lastSeq: UInt16?
    @ObservationIgnored private var wantStream = false
    @ObservationIgnored private var lastSentAmplitude: UInt8 = 255

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    var isAvailable: Bool { state == .connected && imuChar != nil }
    var isReady: Bool { state == .connected && hapticChar != nil }

    // MARK: MotionSource

    func start() {
        wantStream = true
        if let p = peripheral, let c = imuChar, state == .connected {
            p.setNotifyValue(true, for: c)
        } else {
            connect()
        }
    }

    func stop() {
        wantStream = false
        if let p = peripheral, let c = imuChar { p.setNotifyValue(false, for: c) }
    }

    // MARK: HapticSink

    func startHaptics() { setAmplitude(0) }
    func stopHaptics() { setAmplitude(0) }

    func setAmplitude(_ amplitude: Double) {
        guard let p = peripheral, let c = hapticChar, state == .connected else { return }
        let v = UInt8(max(0, min(127, (amplitude * 127).rounded())))
        guard v != lastSentAmplitude else { return }
        lastSentAmplitude = v
        p.writeValue(Data([v]), for: c, type: .withoutResponse)
    }

    // MARK: connection

    func connect() {
        lastError = nil
        guard central.state == .poweredOn else { state = .off; return }
        if let p = peripheral, p.state == .connected { state = .connected; return }
        state = .scanning
        central.scanForPeripherals(withServices: [UUIDs.service], options: nil)
    }

    func disconnect() {
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        state = .disconnected
    }
}

extension PuckBLE: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantStream { connect() } else { state = .disconnected }
        case .unauthorized:
            state = .off; lastError = "Bluetooth permission denied. Allow it in Settings."
        case .poweredOff:
            state = .off; lastError = "Bluetooth is off."
        default:
            state = .off
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        self.rssi = RSSI.intValue
        peripheral.delegate = self
        state = .connecting
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connected
        lastSeq = nil
        lastSentAmplitude = 255
        peripheral.discoverServices([UUIDs.service, UUIDs.battery])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .disconnected
        lastError = error?.localizedDescription ?? "Could not connect."
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        state = .disconnected
        imuChar = nil; hapticChar = nil; batteryChar = nil
        if let error { lastError = error.localizedDescription }
        if wantStream { connect() }   // auto-reconnect while a session wants data
    }
}

extension PuckBLE: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] {
            if s.uuid == UUIDs.service { peripheral.discoverCharacteristics([UUIDs.imu, UUIDs.haptic], for: s) }
            if s.uuid == UUIDs.battery { peripheral.discoverCharacteristics([UUIDs.batteryLvl], for: s) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case UUIDs.imu:
                imuChar = c
                if wantStream { peripheral.setNotifyValue(true, for: c) }
            case UUIDs.haptic:
                hapticChar = c
            case UUIDs.batteryLvl:
                batteryChar = c
                peripheral.readValue(for: c)
                peripheral.setNotifyValue(true, for: c)
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case UUIDs.imu:
            guard data.count >= 8 else { return }
            let v = data.withUnsafeBytes { raw -> (Int16, Int16, Int16, UInt16) in
                (raw.loadUnaligned(fromByteOffset: 0, as: Int16.self),
                 raw.loadUnaligned(fromByteOffset: 2, as: Int16.self),
                 raw.loadUnaligned(fromByteOffset: 4, as: Int16.self),
                 raw.loadUnaligned(fromByteOffset: 6, as: UInt16.self))
            }
            packetsReceived += 1
            if let last = lastSeq {
                let gap = Int(v.3 &- last &- 1)
                if gap > 0 && gap < 1000 { packetsDropped += gap }
            }
            lastSeq = v.3
            let scale = 1.0 / 8192.0
            onSample?(AccelSample(t: ProcessInfo.processInfo.systemUptime,
                                  x: Double(v.0) * scale, y: Double(v.1) * scale, z: Double(v.2) * scale))
        case UUIDs.batteryLvl:
            if let b = data.first { batteryPercent = Int(b) }
        default: break
        }
    }
}
