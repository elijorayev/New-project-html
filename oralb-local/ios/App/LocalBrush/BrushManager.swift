import CoreBluetooth
import Foundation
import OralBKit

enum BrushError: LocalizedError {
    case notConnected, missingCharacteristic(String), disconnected, refused(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the brush."
        case .missingCharacteristic(let u): return "This handle doesn't expose \(OralB.knownCharacteristics[u] ?? u)."
        case .disconnected: return "The brush disconnected."
        case .refused(let why): return why
        }
    }
}

struct DiscoveredBrush: Identifiable {
    let id: UUID              // iOS hides MAC addresses; this is a per-iPhone identifier
    var name: String
    var rssi: Int
    var advertisement: Advertisement?
    var lastSeen: Date
}

struct CharacteristicInfo: Identifiable, Codable {
    var id: String { uuid }
    let service: String
    let uuid: String
    let properties: [String]
    var valueHex: String?
    var error: String?
    var knownAs: String? { OralB.knownCharacteristics[uuid] }
}

/// All CoreBluetooth work. Callbacks arrive on the main queue and are handled on the main actor.
@MainActor
final class BrushManager: NSObject, ObservableObject {
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var brushes: [UUID: DiscoveredBrush] = [:]
    @Published var connectedID: UUID?
    @Published var status = "Not connected"
    @Published var model: ModelInfo?
    @Published var battery: Battery?
    @Published var availableModes: Data?
    @Published var characteristics: [CharacteristicInfo] = []
    @Published var deviceSessions: [SessionRecord] = []
    @Published var notifications: [String] = []

    let history = HistoryStore()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [String: CBCharacteristic] = [:]
    private var pendingServices = 0
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var readWaiters: [String: [CheckedContinuation<Data, Error>]] = [:]
    private var writeWaiters: [String: [CheckedContinuation<Void, Error>]] = [:]
    private var lastRunning: [UUID: Advertisement] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Scanning (passive, read-only)

    func startScan() {
        guard central.state == .poweredOn, !central.isScanning else { return }
        // Duplicates on, so live advertisement changes (mode, time, pressure) keep arriving.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() { central.stopScan() }

    // MARK: Connection

    func connect(_ id: UUID) async throws {
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else { throw BrushError.notConnected }
        peripheral = p
        p.delegate = self
        status = "Connecting…"
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            readyWaiter = c
            central.connect(p)
        }
        connectedID = id
        status = "Connected"
        try await refresh()
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    /// Reads the values the dashboard shows. Read-only.
    func refresh() async throws {
        // Each value is optional: older variants may not expose all of them.
        if let d = try? await read(OralB.Char.model) { model = ModelInfo(d) }
        if let d = try? await read(OralB.Char.battery) { battery = Battery(d) }
        availableModes = try? await read(OralB.Char.availableModes)
    }

    // MARK: Inspector (read-only)

    func inspectAll() async {
        guard let p = peripheral else { return }
        var out: [CharacteristicInfo] = []
        for service in p.services ?? [] {
            for ch in service.characteristics ?? [] {
                var info = CharacteristicInfo(service: service.uuid.uuidString, uuid: ch.uuid.uuidString,
                                              properties: Self.describe(ch.properties))
                if ch.properties.contains(.read) {
                    do { info.valueHex = try await read(ch.uuid.uuidString).hex }
                    catch { info.error = error.localizedDescription }
                }
                out.append(info)
            }
        }
        characteristics = out
    }

    func subscribeAll() {
        guard let p = peripheral else { return }
        for ch in chars.values where ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
            p.setNotifyValue(true, for: ch)
        }
    }

    static func describe(_ p: CBCharacteristicProperties) -> [String] {
        var out: [String] = []
        if p.contains(.read) { out.append("read") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.writeWithoutResponse) { out.append("write-no-response") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        return out
    }

    // MARK: Device-stored sessions
    // Writes [0x02, index] to the control register to select a record; changes no settings.

    func readDeviceSessions(count: Int = 30) async throws {
        let protocolVersion = model?.protocolVersion ?? 1
        var out: [SessionRecord] = []
        for i in 0..<count {
            try await write(OralB.Char.control, Data([OralB.selectSession, UInt8(i)]))
            if let rec = SessionRecord(try await read(OralB.Char.sessionInfo), protocolVersion: protocolVersion) {
                out.append(rec)
            }
        }
        deviceSessions = out.sorted { $0.start > $1.start }
        history.merge(deviceSessions)
    }

    // MARK: Available modes (the only configuration write in this app)

    /// Writes a new available-modes list. Guards: a backup must exist for this brush and model,
    /// the brush must not be running or in a factory state, and the value is read back after writing.
    func writeAvailableModes(_ modes: [UInt8]?) async throws -> Data {
        guard let id = connectedID, let model else { throw BrushError.notConnected }
        guard let backup = BackupStore.load(id) else {
            throw BrushError.refused("Save a backup first.")
        }
        guard backup.modelType == model.modelType else {
            throw BrushError.refused("The backup was taken from a different model type.")
        }
        let state = try await read(OralB.Char.status).first ?? 0
        if OralB.factoryStates.contains(state) {
            throw BrushError.refused("The brush reports a factory state (\(OralB.stateName(state))). Not writing.")
        }
        if state == OralB.runningState { throw BrushError.refused("Stop the brush first.") }

        let current = try await read(OralB.Char.availableModes)
        let payload = try modes.map { try AvailableModes.encode($0, current: current) } ?? backup.availableModes
        guard payload.count == current.count else {
            throw BrushError.refused("The handle uses \(current.count) slots; the new value has \(payload.count).")
        }
        try await write(OralB.Char.control, OralB.unlockAvailableModes)
        try await write(OralB.Char.availableModes, payload)
        let after = try await read(OralB.Char.availableModes)
        availableModes = after
        return after
    }

    func saveBackup() async throws {
        guard let id = connectedID, let model else { throw BrushError.notConnected }
        let modes = try await read(OralB.Char.availableModes)
        try BackupStore.save(Backup(taken: Date(), modelType: model.modelType, availableModes: modes), for: id)
    }

    // MARK: Async GATT primitives

    private func read(_ uuid: String) async throws -> Data {
        guard let p = peripheral else { throw BrushError.notConnected }
        guard let ch = chars[uuid] else { throw BrushError.missingCharacteristic(uuid) }
        return try await withCheckedThrowingContinuation { c in
            readWaiters[uuid, default: []].append(c)
            p.readValue(for: ch)
        }
    }

    private func write(_ uuid: String, _ data: Data) async throws {
        guard let p = peripheral else { throw BrushError.notConnected }
        guard let ch = chars[uuid] else { throw BrushError.missingCharacteristic(uuid) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writeWaiters[uuid, default: []].append(c)
            p.writeValue(data, for: ch, type: .withResponse)
        }
    }

    private func failAll(_ error: Error) {
        readyWaiter?.resume(throwing: error); readyWaiter = nil
        readWaiters.values.flatMap { $0 }.forEach { $0.resume(throwing: error) }
        writeWaiters.values.flatMap { $0 }.forEach { $0.resume(throwing: error) }
        readWaiters = [:]; writeWaiters = [:]
    }

    // MARK: Local history from advertisements

    private func trackSession(_ id: UUID, _ ad: Advertisement) {
        if ad.isRunning {
            lastRunning[id] = ad
        } else if let last = lastRunning.removeValue(forKey: id), last.brushSeconds >= 10 {
            history.add(SessionRecord(start: Date().addingTimeInterval(-Double(last.brushSeconds)),
                                      durationSeconds: last.brushSeconds, mode: last.mode))
        }
    }
}

// MARK: - Delegates

extension BrushManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            bluetoothState = central.state
            if central.state == .poweredOn { startScan() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              mfg.count >= 2, mfg[mfg.startIndex] == 0xDC, mfg[mfg.startIndex + 1] == 0x00 else { return }
        let id = peripheral.identifier
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Oral-B"
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            let ad = Advertisement(manufacturerData: mfg)
            brushes[id] = DiscoveredBrush(id: id, name: name, rssi: rssi, advertisement: ad, lastSeen: Date())
            if let ad { trackSession(id, ad) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { peripheral.discoverServices(nil) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            status = "Connection failed"
            failAll(error ?? BrushError.disconnected)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            status = "Not connected"
            connectedID = nil
            chars = [:]
            failAll(BrushError.disconnected)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let services = peripheral.services ?? []
            pendingServices = services.count
            if let error { failAll(error); return }
            if services.isEmpty { readyWaiter?.resume(); readyWaiter = nil }
            services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for ch in service.characteristics ?? [] { chars[ch.uuid.uuidString] = ch }
            pendingServices -= 1
            if pendingServices == 0 { readyWaiter?.resume(); readyWaiter = nil }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString
        let value = characteristic.value ?? Data()
        MainActor.assumeIsolated {
            if var waiters = readWaiters[uuid], !waiters.isEmpty {
                let c = waiters.removeFirst()
                readWaiters[uuid] = waiters
                if let error { c.resume(throwing: error) } else { c.resume(returning: value) }
                return
            }
            // Not answering a read, so it's a notification.
            let name = OralB.knownCharacteristics[uuid] ?? uuid
            let line = "\(Date().formatted(date: .omitted, time: .standard))  \(name): \(value.hex)"
            notifications.insert(line, at: 0)
            if notifications.count > 300 { notifications.removeLast() }
            if uuid == OralB.Char.battery, let b = Battery(value) { battery = b }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString
        MainActor.assumeIsolated {
            guard var waiters = writeWaiters[uuid], !waiters.isEmpty else { return }
            let c = waiters.removeFirst()
            writeWaiters[uuid] = waiters
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
