// Oral-B SmartSeries BLE protocol: constants and pure decoders (no CoreBluetooth).
//
// Sources are community reverse engineering, not official Oral-B documentation:
//   - oralb-ble 1.1.3 (MIT), used by Home Assistant's Oral-B integration
//   - OralBlue_python Protocol.md (wise86-android)
// Every table here is "observed on some handles"; confirm it on yours.
// Mirrors ../python/oralb_protocol.py.

import Foundation

public enum OralB {
    /// Bluetooth SIG company ID 0x00DC (Procter & Gamble).
    public static let manufacturerID: UInt16 = 0x00DC

    /// Custom 128-bit UUIDs: a0f0XXXX-5047-4d53-8208-4f72616c2d42 ("PGMS" ... "Oral-B").
    public static func uuid(_ short: UInt16) -> String {
        String(format: "A0F0%04X-5047-4D53-8208-4F72616C2D42", short)
    }

    public enum Char {
        public static let toothbrushID = uuid(0xFF01)
        public static let model = uuid(0xFF02)
        public static let userID = uuid(0xFF03)
        public static let status = uuid(0xFF04)
        public static let battery = uuid(0xFF05)
        public static let buttons = uuid(0xFF06)
        public static let mode = uuid(0xFF07)
        public static let brushingTime = uuid(0xFF08)
        public static let sector = uuid(0xFF09)
        public static let pressure = uuid(0xFF0B)
        public static let control = uuid(0xFF21)
        public static let currentTime = uuid(0xFF22)
        public static let signals = uuid(0xFF24)
        public static let availableModes = uuid(0xFF25)
        public static let sectorTimer = uuid(0xFF26)
        public static let sessionInfo = uuid(0xFF29)
    }

    public static let knownCharacteristics: [String: String] = [
        Char.toothbrushID: "toothbrush id",
        Char.model: "model / protocol / firmware",
        Char.userID: "user id",
        Char.status: "status",
        Char.battery: "battery",
        Char.buttons: "buttons",
        Char.mode: "current mode",
        Char.brushingTime: "brushing time",
        Char.sector: "sector",
        Char.pressure: "pressure",
        Char.control: "control (command register)",
        Char.currentTime: "clock",
        Char.signals: "signals",
        Char.availableModes: "available modes",
        Char.sectorTimer: "sector timer",
        Char.sessionInfo: "session info",
    ]

    /// Written to `Char.control` before writing `Char.availableModes`.
    public static let unlockAvailableModes = Data([0x37, 0x29])
    /// Written to `Char.control` as [selectSession, index] before reading `Char.sessionInfo`.
    public static let selectSession: UInt8 = 0x02

    public static let modes: [UInt8: String] = [
        0: "Off", 1: "Daily Clean", 2: "Sensitive", 3: "Massage", 4: "Whitening",
        5: "Deep Clean", 6: "Tongue Cleaning", 7: "Turbo", 255: "Empty slot",
    ]
    /// Mode IDs a user may put into the available-modes list.
    public static let selectableModes: [UInt8] = [1, 2, 3, 4, 5, 6, 7]

    public static let states: [UInt8: String] = [
        0: "Unknown", 1: "Initializing", 2: "Idle", 3: "Running", 4: "Charging", 5: "Setup",
        6: "Flight menu", 8: "Selection menu", 9: "Off", 10: "Post-brushing statistics",
        113: "Final test", 114: "PCB test", 115: "Sleeping", 116: "Transport",
    ]
    /// Factory/diagnostic states: the app never writes while the brush reports one.
    public static let factoryStates: Set<UInt8> = [113, 114, 116]
    public static let runningState: UInt8 = 3

    /// "N mode" = number of modes the hardware variant shipped with; "X mode" variants are configurable.
    public static let modelTypes: [UInt8: String] = [
        0: "D36 Triumph/Professional Care (X mode)", 1: "D36 Triumph/Professional Care (6 mode)",
        2: "D36 Triumph/Professional Care (5 mode)",
        32: "D701 Genius (X mode)", 33: "D701 Genius (6 mode)", 34: "D701 Genius (5 mode)",
        39: "D700 Smart/Pro Series (5 mode)", 40: "D700 Smart/Pro Series (4 mode)",
        41: "D700 Smart/Pro Series (6 mode)",
        48: "iO (X mode)", 49: "iO", 50: "iO (big Ti)", 52: "iO Series 4", 53: "iO Series 5",
        54: "iO (ePlatform)", 63: "D36 (experimental)",
        64: "D21 Smart Series (X mode)", 65: "D21 Smart Series (4 mode)", 66: "D21 Smart Series (3a mode)",
        67: "D21 Smart Series (2a mode)", 68: "D21 Smart Series (2b mode)",
        69: "D21 Smart Series (3 mode, whitening)", 70: "D21 Smart Series (1 mode)",
        80: "D601 Pro (X mode)", 81: "D601 Pro (5 mode)", 82: "D601 Pro (4 mode)", 83: "D601 Pro (3a mode)",
        84: "D601 Pro (2a mode)", 85: "D601 Pro (2b mode)", 86: "D601 Pro (3b mode)", 87: "D601 Pro (1 mode)",
        112: "D706 Genius X (X mode)", 113: "D706 Genius X (6 mode)", 114: "D706 Genius X (5 mode)",
    ]

    public static func modeName(_ m: UInt8) -> String { modes[m] ?? "Unknown mode \(m)" }
    public static func stateName(_ s: UInt8) -> String { states[s] ?? "Unknown state \(s)" }
    public static func modelName(_ t: UInt8) -> String { modelTypes[t] ?? "Unknown model type \(t)" }

    static let epoch2000 = Date(timeIntervalSince1970: 946_684_800)
}

// MARK: - Advertisement

public enum PressureStatus: String, Sendable {
    case normal = "Normal", high = "High", button = "Button pressed", powerButton = "Power button pressed"

    /// Advertisement byte 4 is a bit field; button presses win over the pressure flag.
    public init(flags: UInt8) {
        if flags & 0x08 != 0 { self = .powerButton }
        else if flags & 0x04 != 0 { self = .button }
        else if flags & 0x80 != 0 { self = .high }
        else { self = .normal }
    }
}

public struct Advertisement: Equatable, Sendable {
    public let raw: Data
    public let protocolVersion: UInt8
    public let modelType: UInt8
    public let firmware: UInt8
    public let state: UInt8
    public let pressureFlags: UInt8
    public let brushSeconds: Int
    public let mode: UInt8
    public let sector: UInt8
    public let sectorTimer: UInt8?
    public let sectorCount: UInt8?

    /// Parses manufacturer data. CoreBluetooth includes the 2-byte little-endian
    /// company ID (DC 00) at the front; bleak and Home Assistant strip it. Both are accepted.
    public init?(manufacturerData: Data) {
        var d = [UInt8](manufacturerData)
        if (d.count == 11 || d.count == 13), d[0] == 0xDC, d[1] == 0x00 { d.removeFirst(2) }
        guard d.count == 9 || d.count == 11 else { return nil }
        raw = Data(d)
        protocolVersion = d[0]; modelType = d[1]; firmware = d[2]; state = d[3]
        pressureFlags = d[4]; brushSeconds = Int(d[5]) * 60 + Int(d[6]); mode = d[7]; sector = d[8]
        sectorTimer = d.count == 11 ? d[9] : nil
        sectorCount = d.count == 11 ? d[10] : nil
    }

    public var modelName: String { OralB.modelName(modelType) }
    public var stateName: String { OralB.stateName(state) }
    public var modeName: String { OralB.modeName(mode) }
    public var pressure: PressureStatus { PressureStatus(flags: pressureFlags) }
    public var isRunning: Bool { state == OralB.runningState }
    public var timeText: String { String(format: "%d:%02d", brushSeconds / 60, brushSeconds % 60) }

    public var sectorText: String {
        let q = sector & 0x07
        if q == 0 { return "No sector" }
        if q == 7 { let c = (sectorCount ?? 0) & 0x07; return "Sector \(c == 0 ? 4 : c)" }
        return "Sector \(q)"
    }
}

// MARK: - Characteristic decoders

public struct ModelInfo: Equatable, Sendable, Codable {
    public let modelType: UInt8
    public let protocolVersion: UInt8?
    public let firmware: UInt8?
    public var name: String { OralB.modelName(modelType) }

    public init?(_ data: Data) {
        let d = [UInt8](data)
        guard let first = d.first else { return nil }
        modelType = first
        protocolVersion = d.count >= 3 ? d[1] : nil
        firmware = d.count >= 3 ? d[2] : nil
    }
}

public struct Battery: Equatable, Sendable {
    public let percent: Int
    public let secondsLeft: Int?

    public init?(_ data: Data) {
        let d = [UInt8](data)
        guard let first = d.first else { return nil }
        percent = Int(first)
        secondsLeft = d.count >= 3 ? Int(d[1]) | Int(d[2]) << 8 : nil
    }
}

public func decodeClock(_ data: Data) -> Date? {
    let d = [UInt8](data)
    guard d.count >= 4 else { return nil }
    let s = UInt32(d[0]) | UInt32(d[1]) << 8 | UInt32(d[2]) << 16 | UInt32(d[3]) << 24
    return OralB.epoch2000.addingTimeInterval(TimeInterval(s))
}

public struct SessionRecord: Equatable, Sendable, Codable, Identifiable {
    public var id: Date { start }
    public let start: Date
    public let durationSeconds: Int
    public let mode: UInt8
    public let pressureSeconds: Double
    public let pressureWarnings: Int
    public let batteryAtEnd: Int
    public let rawHex: String

    /// One record from `Char.sessionInfo`. Field layout is from community notes; raw bytes are kept.
    public init?(_ data: Data, protocolVersion: UInt8) {
        let d = [UInt8](data)
        guard d.count >= 12 else { return nil }
        let s = UInt32(d[0]) | UInt32(d[1]) << 8 | UInt32(d[2]) << 16 | UInt32(d[3]) << 24
        // Empty slots read back as all zeros or all 0xFF.
        if s == 0 || s == .max { return nil }
        start = OralB.epoch2000.addingTimeInterval(TimeInterval(s))
        durationSeconds = Int(d[4]) | Int(d[5]) << 8
        mode = d[7]
        let p = Double(Int(d[8]) | Int(d[9]) << 8)
        pressureSeconds = protocolVersion >= 4 ? p / 10 : p
        pressureWarnings = Int(d[10])
        batteryAtEnd = Int(d[11])
        rawHex = data.map { String(format: "%02x", $0) }.joined()
    }

    public init(start: Date, durationSeconds: Int, mode: UInt8) {
        self.start = start; self.durationSeconds = durationSeconds; self.mode = mode
        pressureSeconds = 0; pressureWarnings = 0; batteryAtEnd = 0; rawHex = ""
    }
}

// MARK: - Available modes

public enum AvailableModesError: Error, Equatable, CustomStringConvertible {
    case empty, tooMany(Int), duplicate, undocumented(UInt8), unknownFiller(Int)

    public var description: String {
        switch self {
        case .empty: return "At least one mode is required."
        case .tooMany(let n): return "At most \(n) modes fit."
        case .duplicate: return "Each mode can appear only once."
        case .undocumented(let m): return "Mode \(m) is not a documented brushing mode."
        case .unknownFiller(let n):
            return "Can't tell which byte marks an empty slot on this handle. Select exactly \(n) modes, or send the raw value for analysis."
        }
    }
}

public enum AvailableModes {
    public static func names(_ data: Data) -> [String] { data.map(OralB.modeName) }

    /// The byte the handle itself uses for unused slots, if exactly one such byte appears.
    public static func emptySlotByte(_ current: Data) -> UInt8? {
        let fillers = Set(current.filter { !OralB.selectableModes.contains($0) })
        return fillers.count == 1 ? fillers.first : nil
    }

    /// The modes currently enabled on the handle, in button order.
    public static func enabled(_ current: Data) -> [UInt8] {
        current.filter { OralB.selectableModes.contains($0) }
    }

    /// Builds a new value shaped like `current`. Never invents a filler byte.
    public static func encode(_ modes: [UInt8], current: Data) throws -> Data {
        guard !modes.isEmpty else { throw AvailableModesError.empty }
        guard modes.count <= current.count else { throw AvailableModesError.tooMany(current.count) }
        guard Set(modes).count == modes.count else { throw AvailableModesError.duplicate }
        if let bad = modes.first(where: { !OralB.selectableModes.contains($0) }) {
            throw AvailableModesError.undocumented(bad)
        }
        let pad = current.count - modes.count
        guard pad > 0 else { return Data(modes) }
        guard let filler = emptySlotByte(current) else { throw AvailableModesError.unknownFiller(current.count) }
        return Data(modes + Array(repeating: filler, count: pad))
    }
}
