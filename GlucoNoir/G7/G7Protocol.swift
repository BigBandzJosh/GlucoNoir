//
//  G7Protocol.swift
//  GlucoNoir
//
//  Wire format for the Dexcom G7 BLE protocol.
//
//  Layouts and UUIDs derived from LoopKit/G7SensorKit (MIT), which is the
//  reference implementation used by Loop. Reimplemented standalone here so the
//  Phase 1 spike has no dependency on LoopKit's build system.
//

import Foundation
import CoreBluetooth

// MARK: - Bluetooth identifiers

nonisolated enum G7UUID {
    /// Advertised by the sensor; what we scan for.
    static let advertisement = CBUUID(string: "FEBC")

    /// The CGM service carrying glucose messages.
    static let cgmService = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")

    static let communication  = CBUUID(string: "F8083533-849E-531C-C594-30F1F86A4EA5") // read/notify
    static let control        = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5") // write/indicate
    static let authentication = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5") // write/indicate
    static let backfill       = CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5") // read/write/notify

    /// Characteristics we discover. Subscription is staged, not simultaneous:
    /// see `G7AuthChallengeMessage`.
    static let discoverTargets = [control, authentication, communication, backfill]
}

nonisolated enum G7Opcode: UInt8 {
    case authChallengeRx   = 0x05
    case sessionStopTx     = 0x28
    case glucoseTx         = 0x4e
    case extendedVersionTx = 0x52
    case extendedVersionRx = 0x53
    case backfillFinished  = 0x59
}

/// The G7 advertises as "DXCMxx"; Dexcom ONE+ as "DX02xx".
nonisolated enum G7Name {
    static let prefixes = ["DXCM", "DX02"]
    static func matches(_ name: String?) -> Bool {
        guard let name else { return false }
        return prefixes.contains { name.hasPrefix($0) }
    }
}

// MARK: - Sensor lifecycle

/// The sensor's own view of its state. Only `.ok` means the glucose value is
/// trustworthy — everything else gates the display (PRD §3.1.3).
nonisolated enum G7AlgorithmState: UInt8 {
    case stopped = 1
    case warmup = 2
    case excessNoise = 3
    case firstOfTwoBGsNeeded = 4
    case secondOfTwoBGsNeeded = 5
    case ok = 6
    case needsCalibration = 7
    case calibrationError1 = 8
    case calibrationError2 = 9
    case calibrationLinearityFitFailure = 10
    case sensorFailedDueToCountsAberration = 11
    case sensorFailedDueToResidualAberration = 12
    case outOfCalibrationDueToOutlier = 13
    case outlierCalibrationRequest = 14
    case sessionExpired = 15
    case sessionFailedDueToUnrecoverableError = 16
    case sessionFailedDueToTransmitterError = 17
    case temporarySensorIssue = 18
    case sensorFailedDueToProgressiveSensorDecline = 19
    case sensorFailedDueToHighCountsAberration = 20
    case sensorFailedDueToLowCountsAberration = 21
    case sensorFailedDueToRestart = 22
    case expired = 24
    case sensorFailed = 25
    case sessionEnded = 26

    var hasReliableGlucose: Bool { self == .ok }
    var isInWarmup: Bool { self == .warmup }

    var isSensorFailure: Bool {
        switch self {
        case .sensorFailed, .sensorFailedDueToCountsAberration,
             .sensorFailedDueToResidualAberration, .sessionFailedDueToTransmitterError,
             .sessionFailedDueToUnrecoverableError, .sensorFailedDueToProgressiveSensorDecline,
             .sensorFailedDueToHighCountsAberration, .sensorFailedDueToLowCountsAberration,
             .sensorFailedDueToRestart:
            return true
        default:
            return false
        }
    }
}

nonisolated enum G7Limits {
    static let minimum: UInt16 = 40
    static let maximum: UInt16 = 400
    /// Sensor session length before the 12h grace period.
    static let sessionDuration: TimeInterval = 10 * 24 * 3600
    static let warmupDuration: TimeInterval = 27 * 60
    static let gracePeriod: TimeInterval = 12 * 3600
}

// MARK: - Glucose message

/// A decoded 0x4e glucose message.
///
/// Byte layout (19 bytes):
/// ```
///    0    1  2..5     6..7  8  9  10..11  12..13  14  15  16..17  18
///  0x4e  00  TTTTTTTT SQSQ           AGAG    BGBG  SS  TR    PRPR   C
/// ```
nonisolated struct G7GlucoseMessage {
    /// Seconds since sensor pairing, at the moment the message was sent.
    let messageTimestamp: UInt32
    let sequence: UInt16
    /// Seconds between the sensor taking the reading and transmitting it.
    /// This is what makes displayed freshness measured rather than estimated.
    let age: UInt16
    let glucose: UInt16?
    let predicted: UInt16?
    let algorithmState: G7AlgorithmState?
    let rawAlgorithmState: UInt8
    /// mg/dL per minute.
    let trendRate: Double?
    let glucoseIsDisplayOnly: Bool
    let raw: Data

    /// Seconds since pairing at which the reading was actually taken.
    var glucoseTimestamp: UInt32 { messageTimestamp &- UInt32(age) }

    var hasReliableGlucose: Bool { algorithmState?.hasReliableGlucose ?? false }

    var isBelowRange: Bool { (glucose ?? 0) < G7Limits.minimum }
    var isAboveRange: Bool { (glucose ?? 0) > G7Limits.maximum }

    init?(data: Data) {
        guard data.count >= 19 else { return nil }
        let b = [UInt8](data)
        guard b[0] == G7Opcode.glucoseTx.rawValue, b[1] == 0x00 else { return nil }

        messageTimestamp = Self.u32(b, 2)
        sequence = Self.u16(b, 6)
        age = Self.u16(b, 10)

        let g = Self.u16(b, 12)
        if g != 0xffff {
            glucose = g & 0x0fff
            glucoseIsDisplayOnly = (b[18] & 0x10) > 0
        } else {
            glucose = nil
            glucoseIsDisplayOnly = false
        }

        let p = Self.u16(b, 16)
        predicted = p != 0xffff ? (p & 0x0fff) : nil

        rawAlgorithmState = b[14]
        algorithmState = G7AlgorithmState(rawValue: b[14])

        // 0x7f is the sentinel for "no trend available".
        trendRate = b[15] == 0x7f ? nil : Double(Int8(bitPattern: b[15])) / 10.0

        raw = data
    }

    // Little-endian reads.
    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
}

nonisolated extension G7GlucoseMessage {
    /// Dexcom's published trend bands (PRD §4.2.7).
    var trendArrow: String {
        guard let r = trendRate else { return "—" }
        switch r {
        case ..<(-3.0):     return "\u{21ca}"  // ⇊
        case ..<(-2.0):     return "\u{2193}"  // ↓
        case ..<(-1.0):     return "\u{2198}"  // ↘
        case ..<1.0:        return "\u{2192}"  // →
        case ..<2.0:        return "\u{2197}"  // ↗
        case ..<3.0:        return "\u{2191}"  // ↑
        default:            return "\u{21c8}"  // ⇈
        }
    }

    var stateDescription: String {
        algorithmState.map { String(describing: $0) } ?? "unknown(\(rawAlgorithmState))"
    }
}


/// Response on the authentication characteristic.
///
/// We never authenticate ourselves. The official Dexcom app owns the session;
/// we passively observe its handshake and wait for it to report both bonded and
/// authenticated. Only then does the sensor stream glucose on `control` —
/// subscribing to control before this point yields silence and a dropped link.
nonisolated struct G7AuthChallengeMessage {
    let isAuthenticated: Bool
    let isBonded: Bool

    /// True once the official app's session is fully established.
    var sessionReady: Bool { isAuthenticated && isBonded }

    init?(data: Data) {
        guard data.count >= 3 else { return nil }
        let b = [UInt8](data)
        guard b[0] == G7Opcode.authChallengeRx.rawValue else { return nil }
        isAuthenticated = b[1] == 0x01
        isBonded = b[2] == 0x01
    }
}
