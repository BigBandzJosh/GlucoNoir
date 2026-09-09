//
//  ShareTests.swift
//  GlucoNoirTests
//

import Testing
import Foundation
@testable import GlucoNoir

struct ShareDateTests {

    @Test func parsesMicrosoftDateWithTimezone() throws {
        let d = try #require(ShareGlucoseReading.parseMicrosoftDate("/Date(1747051200000+0000)/"))
        #expect(d.timeIntervalSince1970 == 1747051200)
    }

    @Test func parsesMicrosoftDateWithoutTimezone() throws {
        let d = try #require(ShareGlucoseReading.parseMicrosoftDate("Date(1747051200000)"))
        #expect(d.timeIntervalSince1970 == 1747051200)
    }

    @Test func parsesNegativeOffsetForm() throws {
        let d = try #require(ShareGlucoseReading.parseMicrosoftDate("/Date(1747051200000-0500)/"))
        // Epoch milliseconds are absolute; the offset is display metadata only.
        #expect(d.timeIntervalSince1970 == 1747051200)
    }

    @Test func rejectsIso8601() {
        // The classic failure: ISO parsing silently yields hours-off readings.
        #expect(ShareGlucoseReading.parseMicrosoftDate("2026-09-08T04:00:00Z") == nil)
    }

    @Test func rejectsGarbage() {
        #expect(ShareGlucoseReading.parseMicrosoftDate("") == nil)
        #expect(ShareGlucoseReading.parseMicrosoftDate("Date()") == nil)
    }
}

struct ShareTrendTests {

    @Test func decodesStringForm() {
        #expect(ShareTrend(apiValue: "Flat") == .flat)
        #expect(ShareTrend(apiValue: "DoubleDown") == .doubleDown)
        #expect(ShareTrend(apiValue: "FortyFiveUp") == .fortyFiveUp)
    }

    @Test func decodesLegacyIntegerForm() {
        #expect(ShareTrend(apiValue: 4) == .flat)
        #expect(ShareTrend(apiValue: 7) == .doubleDown)
    }

    @Test func decodesIntegerSentAsString() {
        #expect(ShareTrend(apiValue: "4") == .flat)
    }

    @Test func unknownFallsBackToNone() {
        #expect(ShareTrend(apiValue: "Sideways") == .none)
        #expect(ShareTrend(apiValue: nil) == .none)
    }

    @Test func nonDirectionalStatesDrawNoArrow() {
        #expect(ShareTrend.none.arrow == nil)
        #expect(ShareTrend.notComputable.arrow == nil)
        #expect(ShareTrend.rateOutOfRange.arrow == nil)
        #expect(ShareTrend.flat.arrow != nil)
    }
}

struct ShareReadingTests {

    private let json: [String: Any] = [
        "WT": "/Date(1747051200000)/",
        "ST": "/Date(1747051200000)/",
        "DT": "/Date(1747051200000+0000)/",
        "Value": 142,
        "Trend": "Flat"
    ]

    @Test func decodesReading() throws {
        let r = try #require(ShareGlucoseReading(json: json))
        #expect(r.valueMgdl == 142)
        #expect(r.trend == .flat)
        #expect(r.sampleTime.timeIntervalSince1970 == 1747051200)
    }

    @Test func rejectsMissingValue() {
        var bad = json; bad.removeValue(forKey: "Value")
        #expect(ShareGlucoseReading(json: bad) == nil)
    }

    @Test func rejectsMissingTimestamps() {
        var bad = json
        bad.removeValue(forKey: "WT"); bad.removeValue(forKey: "ST"); bad.removeValue(forKey: "DT")
        #expect(ShareGlucoseReading(json: bad) == nil)
    }

    @Test func fallsBackToSTWhenWTAbsent() throws {
        var j = json; j.removeValue(forKey: "WT")
        let r = try #require(ShareGlucoseReading(json: j))
        #expect(r.sampleTime.timeIntervalSince1970 == 1747051200)
    }

    @Test func flagsRailSentinels() {
        let low = ShareGlucoseReading(sampleTime: .now, valueMgdl: 39, trend: .flat)
        let high = ShareGlucoseReading(sampleTime: .now, valueMgdl: 401, trend: .flat)
        let mid = ShareGlucoseReading(sampleTime: .now, valueMgdl: 142, trend: .flat)
        #expect(low.isBelowRange)
        #expect(high.isAboveRange)
        #expect(!mid.isBelowRange && !mid.isAboveRange)
    }

    @Test func convertsToMmol() {
        let r = ShareGlucoseReading(sampleTime: .now, valueMgdl: 180, trend: .flat)
        #expect(r.mmolL == 10.0)
    }
}

struct ShareErrorTests {

    @Test func authFailuresAreTerminal() {
        // Retrying these is what locks the Dexcom account.
        #expect(ShareError.authenticationFailed("x").isTerminal)
        #expect(ShareError.accountLocked.isTerminal)
        #expect(ShareError.notConfigured.isTerminal)
    }

    @Test func transientFailuresAreRetryable() {
        #expect(!ShareError.sessionExpired.isTerminal)
        #expect(!ShareError.network("timeout").isTerminal)
        #expect(!ShareError.server("500").isTerminal)
        #expect(!ShareError.malformedResponse("junk").isTerminal)
    }
}

struct ShareRegionTests {

    @Test func usesCorrectApplicationIDs() {
        #expect(ShareRegion.us.applicationID == "d89443d2-327c-4a6f-89e5-496bbb0317db")
        #expect(ShareRegion.ous.applicationID == ShareRegion.us.applicationID)
        #expect(ShareRegion.jp.applicationID == "d8665ade-9673-4e27-9ff6-92db4ce13d13")
    }

    @Test func usesCorrectHosts() {
        #expect(ShareRegion.us.baseURL.host() == "share2.dexcom.com")
        #expect(ShareRegion.ous.baseURL.host() == "shareous1.dexcom.com")
        #expect(ShareRegion.jp.baseURL.host() == "share.dexcom.jp")
    }
}

struct GlucoseUnitTests {

    /// The official Dexcom app shows 100 mg/dL as 5.5. Using the precise molar
    /// mass (18.01559) yields 5.6 and silently disagrees with the device the
    /// user is checking against.
    @Test func matchesDexcomAtBoundaryValues() {
        #expect(GlucoseUnit.mmolL.format(100) == "5.5")
        #expect(GlucoseUnit.mmolL.format(90)  == "5.0")
        #expect(GlucoseUnit.mmolL.format(126) == "7.0")
        #expect(GlucoseUnit.mmolL.format(180) == "10.0")
        #expect(GlucoseUnit.mmolL.format(70)  == "3.9")
        #expect(GlucoseUnit.mmolL.format(54)  == "3.0")
        #expect(GlucoseUnit.mmolL.format(250) == "13.9")
    }

    @Test func mgdlFormatsAsInteger() {
        #expect(GlucoseUnit.mgdl.format(100) == "100")
        #expect(GlucoseUnit.mgdl.format(54) == "54")
    }

    @Test func railSentinelsIgnoreUnits() {
        let low = ShareGlucoseReading(sampleTime: .now, valueMgdl: 39, trend: .flat)
        let high = ShareGlucoseReading(sampleTime: .now, valueMgdl: 401, trend: .flat)
        #expect(low.displayValue(in: .mmolL) == "LOW")
        #expect(low.displayValue(in: .mgdl) == "LOW")
        #expect(high.displayValue(in: .mmolL) == "HIGH")
    }

    @Test func conversionIsLosslessAcrossToggling() {
        // Storage is always mg/dL, so switching units cannot corrupt a value.
        let r = ShareGlucoseReading(sampleTime: .now, valueMgdl: 142, trend: .flat)
        #expect(r.displayValue(in: .mgdl) == "142")
        #expect(r.displayValue(in: .mmolL) == "7.9")
        #expect(r.valueMgdl == 142)
    }

    @Test func formatsTargetRange() {
        #expect(GlucoseUnit.mmolL.format(range: 70, high: 180) == "3.9–10.0 mmol/L")
        #expect(GlucoseUnit.mgdl.format(range: 70, high: 180) == "70–180 mg/dL")
    }
}
