//
//  StatisticsTests.swift
//  GlucoNoirTests
//

import Testing
import Foundation
@testable import GlucoNoir

private let now = Date(timeIntervalSince1970: 1_757_000_000)

/// Readings at the sensor's 5-minute cadence, most recent first.
private func series(_ values: [Int]) -> [ShareGlucoseReading] {
    values.enumerated().map { i, v in
        ShareGlucoseReading(sampleTime: now.addingTimeInterval(-Double(i * 300)),
                            valueMgdl: v, trend: .flat)
    }
}

private func flat(_ value: Int, count: Int) -> [ShareGlucoseReading] {
    series(Array(repeating: value, count: count))
}

struct StatisticsCentralTendencyTests {

    @Test func computesMeanAndMedian() {
        let stats = GlucoseStatistics.compute(readings: series([100, 110, 120]),
                                              windowDuration: 3600, now: now)
        #expect(stats.meanMgdl == 110)
        #expect(stats.medianMgdl == 110)
        #expect(stats.readingCount == 3)
    }

    @Test func medianAveragesTheMiddlePairWhenEven() {
        let stats = GlucoseStatistics.compute(readings: series([100, 110, 120, 130]),
                                              windowDuration: 3600, now: now)
        #expect(stats.medianMgdl == 115)
    }

    /// Median is the robust one: a single spike should move the mean much more.
    @Test func medianResistsOutliers() {
        let stats = GlucoseStatistics.compute(readings: series([100, 100, 100, 100, 400]),
                                              windowDuration: 3600, now: now)
        #expect(stats.medianMgdl == 100)
        #expect(stats.meanMgdl == 160)
    }

    @Test func emptyInputYieldsEmptyStatistics() {
        #expect(GlucoseStatistics.compute(readings: [], windowDuration: 3600) == .empty)
    }
}

struct StatisticsVariabilityTests {

    @Test func flatSeriesHasNoVariability() {
        let stats = GlucoseStatistics.compute(readings: flat(100, count: 10),
                                              windowDuration: 3600, now: now)
        #expect(stats.standardDeviation == 0)
        #expect(stats.coefficientOfVariation == 0)
    }

    /// Sample standard deviation (n−1) of [2,4,4,4,5,5,7,9] is 2.138…
    @Test func usesSampleStandardDeviation() {
        let stats = GlucoseStatistics.compute(readings: series([2, 4, 4, 4, 5, 5, 7, 9]),
                                              windowDuration: 3600, now: now)
        #expect(abs(stats.standardDeviation - 2.13809) < 0.001)
    }

    @Test func coefficientOfVariationIsSDOverMean() {
        let stats = GlucoseStatistics.compute(readings: series([90, 100, 110]),
                                              windowDuration: 3600, now: now)
        #expect(abs(stats.coefficientOfVariation - 10.0) < 0.001)
    }

    @Test func singleReadingHasZeroSpreadNotUndefined() {
        let stats = GlucoseStatistics.compute(readings: series([100]),
                                              windowDuration: 3600, now: now)
        #expect(stats.standardDeviation == 0)
        #expect(!stats.coefficientOfVariation.isNaN)
    }

    @Test func flagsTheConsensusCVTarget() {
        let steady = GlucoseStatistics.compute(readings: series([100, 102, 98]),
                                               windowDuration: 3600, now: now)
        #expect(steady.meetsCVTarget)

        let erratic = GlucoseStatistics.compute(readings: series([60, 200, 70, 240, 55]),
                                                windowDuration: 3600, now: now)
        #expect(!erratic.meetsCVTarget)
    }
}

struct StatisticsDistributionTests {

    @Test func bandFractionsSumToOne() {
        let stats = GlucoseStatistics.compute(readings: series([50, 60, 100, 200, 300]),
                                              windowDuration: 3600, now: now)
        let total = GlycemicBand.allCases.reduce(0.0) { $0 + stats.fraction($1) }
        #expect(abs(total - 1.0) < 0.0001)
    }

    @Test func classifiesIntoFiveBands() {
        let stats = GlucoseStatistics.compute(readings: series([50, 60, 100, 200, 300]),
                                              windowDuration: 3600, now: now)
        #expect(abs(stats.fraction(.veryLow) - 0.2) < 0.0001)
        #expect(abs(stats.fraction(.low) - 0.2) < 0.0001)
        #expect(abs(stats.fraction(.inRange) - 0.2) < 0.0001)
        #expect(abs(stats.fraction(.high) - 0.2) < 0.0001)
        #expect(abs(stats.fraction(.veryHigh) - 0.2) < 0.0001)
    }

    /// The consensus target of <4% below range covers low and very low together.
    @Test func timeBelowRangeCombinesLowBands() {
        let stats = GlucoseStatistics.compute(readings: series([50, 60, 100, 100, 100]),
                                              windowDuration: 3600, now: now)
        #expect(abs(stats.timeBelowRange - 0.4) < 0.0001)
        #expect(!stats.meetsTimeBelowTarget)
    }

    @Test func recognisesTheTimeInRangeTarget() {
        let good = GlucoseStatistics.compute(readings: flat(100, count: 10),
                                             windowDuration: 3600, now: now)
        #expect(good.timeInRange == 1.0)
        #expect(good.meetsTimeInRangeTarget)

        let poor = GlucoseStatistics.compute(readings: series([300, 300, 300, 100]),
                                             windowDuration: 3600, now: now)
        #expect(!poor.meetsTimeInRangeTarget)
    }

    /// Rounding a real hypo down to "0%" would hide the thing that matters most.
    @Test func smallNonZeroFractionsAreNotRoundedAway() {
        #expect(GlucoseStatistics.percent(0.004) == "<1%")
        #expect(GlucoseStatistics.percent(0) == "0%")
        #expect(GlucoseStatistics.percent(0.5) == "50%")
    }
}

struct StatisticsGMITests {

    private func fullCoverage(days: Int, value: Int) -> [ShareGlucoseReading] {
        flat(value, count: days * 288)
    }

    /// GMI over a short window is noise presented as an A1C estimate.
    @Test func gmiHiddenBelowFourteenDays() {
        let stats = GlucoseStatistics.compute(readings: fullCoverage(days: 1, value: 120),
                                              windowDuration: 24 * 3600, now: now)
        #expect(stats.gmi == nil)
        #expect(stats.gmiDisplay == nil)
    }

    @Test func gmiHiddenWhenCoverageTooLow() {
        // 14 days of window, but only ~3 days of readings.
        let stats = GlucoseStatistics.compute(readings: fullCoverage(days: 3, value: 120),
                                              windowDuration: 14 * 86400, now: now)
        #expect(stats.coverage < GlucoseStatistics.gmiMinimumCoverage)
        #expect(stats.gmi == nil)
    }

    /// GMI(%) = 3.31 + 0.02392 × mean mg/dL.
    @Test func gmiUsesTheConsensusFormula() throws {
        let stats = GlucoseStatistics.compute(readings: fullCoverage(days: 14, value: 120),
                                              windowDuration: 14 * 86400, now: now)
        let gmi = try #require(stats.gmi)
        #expect(abs(gmi - (3.31 + 0.02392 * 120)) < 0.0001)
        #expect(abs(gmi - 6.1804) < 0.001)
    }
}

struct StatisticsCoverageTests {

    @Test func fullWindowIsFullyCovered() {
        let stats = GlucoseStatistics.compute(readings: flat(100, count: 36),
                                              windowDuration: 3 * 3600, now: now)
        #expect(abs(stats.coverage - 1.0) < 0.0001)
        #expect(stats.isReliable)
    }

    @Test func sparseWindowIsFlaggedUnreliable() {
        let stats = GlucoseStatistics.compute(readings: flat(100, count: 9),
                                              windowDuration: 3 * 3600, now: now)
        #expect(abs(stats.coverage - 0.25) < 0.0001)
        #expect(!stats.isReliable)
    }

    /// Readings outside the window must not inflate coverage or skew the mean.
    @Test func excludesReadingsOutsideTheWindow() {
        let readings = series(Array(repeating: 100, count: 100))   // ~8h of data
        let stats = GlucoseStatistics.compute(readings: readings,
                                              windowDuration: 3600, now: now)
        // Offsets 0…3600 at a 5-minute cadence: 13 readings, boundary included.
        #expect(stats.readingCount == 13, "only the last hour belongs in a 1h window")
    }

    @Test func windowBoundaryIsInclusive() {
        let onBoundary = ShareGlucoseReading(sampleTime: now.addingTimeInterval(-3600),
                                             valueMgdl: 100, trend: .flat)
        let justOutside = ShareGlucoseReading(sampleTime: now.addingTimeInterval(-3601),
                                              valueMgdl: 100, trend: .flat)
        let stats = GlucoseStatistics.compute(readings: [onBoundary, justOutside],
                                              windowDuration: 3600, now: now)
        #expect(stats.readingCount == 1)
    }
}
