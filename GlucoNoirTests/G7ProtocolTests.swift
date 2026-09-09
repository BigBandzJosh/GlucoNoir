//
//  G7ProtocolTests.swift
//  GlucoNoirTests
//
//  Verifies the glucose message parser against the reference byte sequence
//  documented in LoopKit/G7SensorKit, so the wire format is proven before it
//  is trusted on hardware.
//

import Testing
import Foundation
@testable import GlucoNoir

struct G7ProtocolTests {

    /// Reference frame from G7SensorKit's G7GlucoseMessage layout comment:
    /// 0x4e 00 d5070000 0900 00 01 0500 6100 06 01 ffff 0e
    private let reference = Data([
        0x4e, 0x00,
        0xd5, 0x07, 0x00, 0x00,   // messageTimestamp = 2005
        0x09, 0x00,               // sequence = 9
        0x00, 0x01,
        0x05, 0x00,               // age = 5
        0x61, 0x00,               // glucose = 97
        0x06,                     // algorithmState = ok
        0x01,                     // trend = +0.1 mg/dL/min
        0xff, 0xff,               // predicted = none
        0x0e                      // calibration flags
    ])

    @Test func decodesReferenceFrame() throws {
        let m = try #require(G7GlucoseMessage(data: reference))
        #expect(m.messageTimestamp == 2005)
        #expect(m.sequence == 9)
        #expect(m.age == 5)
        #expect(m.glucose == 97)
        #expect(m.predicted == nil)
        #expect(m.algorithmState == .ok)
        #expect(m.hasReliableGlucose)
        #expect(m.trendRate == 0.1)
        #expect(m.glucoseIsDisplayOnly == false)
        // Reading was taken 5 seconds before transmission.
        #expect(m.glucoseTimestamp == 2000)
    }

    @Test func rejectsWrongOpcode() {
        var bad = reference
        bad[bad.startIndex] = 0x52 // extendedVersionTx
        #expect(G7GlucoseMessage(data: bad) == nil)
    }

    @Test func rejectsShortFrame() {
        #expect(G7GlucoseMessage(data: reference.prefix(18)) == nil)
    }

    @Test func handlesAbsentGlucose() throws {
        var d = reference
        d[12] = 0xff; d[13] = 0xff
        let m = try #require(G7GlucoseMessage(data: d))
        #expect(m.glucose == nil)
    }

    @Test func handlesAbsentTrend() throws {
        var d = reference
        d[15] = 0x7f
        let m = try #require(G7GlucoseMessage(data: d))
        #expect(m.trendRate == nil)
        #expect(m.trendArrow == "—")
    }

    @Test func decodesNegativeTrend() throws {
        var d = reference
        d[15] = UInt8(bitPattern: Int8(-25)) // -2.5 mg/dL/min
        let m = try #require(G7GlucoseMessage(data: d))
        #expect(m.trendRate == -2.5)
        #expect(m.trendArrow == "\u{2193}") // single down: -3.0 ..< -2.0
    }

    @Test func masksGlucoseToTwelveBits() throws {
        var d = reference
        // High nibble carries flags, not glucose.
        d[12] = 0x61; d[13] = 0x10
        let m = try #require(G7GlucoseMessage(data: d))
        #expect(m.glucose == 97)
    }

    @Test func mapsTrendBands() {
        func arrow(_ rate: Double) -> String {
            var d = reference
            d[15] = UInt8(bitPattern: Int8(rate * 10))
            return G7GlucoseMessage(data: d)!.trendArrow
        }
        #expect(arrow(-4.0) == "\u{21ca}")
        #expect(arrow(-2.5) == "\u{2193}")
        #expect(arrow(-1.5) == "\u{2198}")
        #expect(arrow(0.0)  == "\u{2192}")
        #expect(arrow(1.5)  == "\u{2197}")
        #expect(arrow(2.5)  == "\u{2191}")
        #expect(arrow(4.0)  == "\u{21c8}")
    }

    @Test func identifiesSensorNames() {
        #expect(G7Name.matches("DXCM4A"))
        #expect(G7Name.matches("DX0212"))
        #expect(!G7Name.matches("AirPods"))
        #expect(!G7Name.matches(nil))
    }

    @Test func flagsUnreliableStates() throws {
        var d = reference
        d[14] = G7AlgorithmState.warmup.rawValue
        let m = try #require(G7GlucoseMessage(data: d))
        #expect(m.algorithmState == .warmup)
        #expect(!m.hasReliableGlucose)
        #expect(m.algorithmState?.isInWarmup == true)
    }
}

struct G7AuthChallengeTests {

    @Test func decodesAuthenticatedBondedSession() throws {
        let m = try #require(G7AuthChallengeMessage(data: Data([0x05, 0x01, 0x01])))
        #expect(m.isAuthenticated)
        #expect(m.isBonded)
        #expect(m.sessionReady)
    }

    @Test func withholdsWhenNotYetBonded() throws {
        let m = try #require(G7AuthChallengeMessage(data: Data([0x05, 0x01, 0x00])))
        #expect(m.isAuthenticated)
        #expect(!m.isBonded)
        #expect(!m.sessionReady, "control must not be subscribed until bonded")
    }

    @Test func withholdsWhenNotAuthenticated() throws {
        let m = try #require(G7AuthChallengeMessage(data: Data([0x05, 0x00, 0x01])))
        #expect(!m.sessionReady)
    }

    @Test func rejectsWrongOpcode() {
        #expect(G7AuthChallengeMessage(data: Data([0x4e, 0x01, 0x01])) == nil)
    }

    @Test func rejectsShortFrame() {
        #expect(G7AuthChallengeMessage(data: Data([0x05, 0x01])) == nil)
    }
}
