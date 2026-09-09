//
//  ChartDataTests.swift
//  GlucoNoirTests
//

import Testing
import Foundation
@testable import GlucoNoir

private let base = Date(timeIntervalSince1970: 1_757_000_000)

private func r(_ minutesAgo: Int, _ value: Int) -> ShareGlucoseReading {
    ShareGlucoseReading(sampleTime: base.addingTimeInterval(-Double(minutesAgo * 60)),
                        valueMgdl: value, trend: .flat)
}

struct ChartSegmentTests {

    @Test func contiguousReadingsFormOneSegment() {
        let readings = (0..<6).map { r($0 * 5, 100 + $0) }
        let segments = ChartDataBuilder.segments(from: readings, unit: .mmolL)
        #expect(segments.count == 1)
        #expect(segments[0].points.count == 6)
    }

    /// A line drawn straight across a gap invents a trajectory that was never
    /// measured — and that invented line can cross the low threshold without
    /// anything having been observed.
    @Test func gapBreaksTheLine() {
        let readings = [r(60, 100), r(55, 102), r(20, 130), r(15, 128)]
        let segments = ChartDataBuilder.segments(from: readings, unit: .mmolL)
        #expect(segments.count == 2, "a 35-minute gap must break the curve")
        #expect(segments[0].points.count == 2)
        #expect(segments[1].points.count == 2)
    }

    @Test func singleMissedSampleDoesNotBreakTheLine() {
        // 10 minutes: one dropped reading, routine. The curve should hold.
        let readings = [r(20, 100), r(10, 105), r(5, 108)]
        let segments = ChartDataBuilder.segments(from: readings, unit: .mmolL)
        #expect(segments.count == 1)
    }

    @Test func outputIsChronologicalRegardlessOfInputOrder() {
        // The store returns newest-first; the chart needs oldest-first.
        let readings = [r(0, 110), r(10, 100), r(5, 105)]
        let segments = ChartDataBuilder.segments(from: readings, unit: .mmolL)
        let values = segments.flatMap { $0.points }.map(\.valueMgdl)
        #expect(values == [100, 105, 110])
    }

    @Test func handlesEmptyAndSingleReading() {
        #expect(ChartDataBuilder.segments(from: [], unit: .mmolL).isEmpty)
        let one = ChartDataBuilder.segments(from: [r(0, 100)], unit: .mmolL)
        #expect(one.count == 1)
        #expect(one[0].points.count == 1)
    }
}

struct ChartValueTests {

    @Test func plotsInDisplayUnits() {
        #expect(ChartDataBuilder.displayValue(100, .mgdl) == 100)
        #expect(ChartDataBuilder.displayValue(100, .mmolL) == 5.5)
        #expect(ChartDataBuilder.displayValue(180, .mmolL) == 10.0)
    }

    /// The chart must never crop a reading out of view, and must always show
    /// the target band for context.
    @Test func yDomainAlwaysContainsTargetRange() {
        let flat = [r(10, 100), r(5, 105)]
        let domain = ChartDataBuilder.yDomain(for: flat, unit: .mgdl)
        #expect(domain.lowerBound <= Double(TargetRange.lowMgdl))
        #expect(domain.upperBound >= Double(TargetRange.highMgdl))
    }

    @Test func yDomainExpandsForExcursions() {
        let spike = [r(10, 45), r(5, 320)]
        let domain = ChartDataBuilder.yDomain(for: spike, unit: .mgdl)
        #expect(domain.lowerBound <= 45)
        #expect(domain.upperBound >= 320)
    }

    @Test func yDomainNeverGoesNegative() {
        let low = [r(0, 40)]
        let domain = ChartDataBuilder.yDomain(for: low, unit: .mmolL)
        #expect(domain.lowerBound >= 0)
    }
}

struct ChartCoverageTests {

    @Test func fullWindowReportsCompleteCoverage() {
        // 3h at one reading per 5 minutes.
        let readings = (0..<36).map { r($0 * 5, 100) }
        let coverage = ChartDataBuilder.coverage(readings: readings, window: .h3, now: base)
        #expect(coverage == 1.0)
    }

    @Test func sparseWindowReportsPartialCoverage() {
        let readings = (0..<9).map { r($0 * 5, 100) }
        let coverage = ChartDataBuilder.coverage(readings: readings, window: .h3, now: base)
        #expect(coverage == 0.25)
    }

    @Test func emptyWindowReportsZero() {
        #expect(ChartDataBuilder.coverage(readings: [], window: .h3, now: base) == 0)
    }

    @Test func coverageIsCappedAtOne() {
        let dense = (0..<200).map { r($0, 100) }
        let coverage = ChartDataBuilder.coverage(readings: dense, window: .h3, now: base)
        #expect(coverage <= 1.0)
    }
}

struct GlycemicBandTests {

    @Test func classifiesTypicalValues() {
        #expect(GlycemicBand.band(for: 50) == .veryLow)
        #expect(GlycemicBand.band(for: 60) == .low)
        #expect(GlycemicBand.band(for: 100) == .inRange)
        #expect(GlycemicBand.band(for: 200) == .high)
        #expect(GlycemicBand.band(for: 300) == .veryHigh)
    }

    /// Off-by-one here would misreport time-in-range against clinical targets.
    @Test func boundariesMatchConsensusThresholds() {
        #expect(GlycemicBand.band(for: 53) == .veryLow)
        #expect(GlycemicBand.band(for: 54) == .low)
        #expect(GlycemicBand.band(for: 69) == .low)
        #expect(GlycemicBand.band(for: 70) == .inRange)
        #expect(GlycemicBand.band(for: 180) == .inRange)
        #expect(GlycemicBand.band(for: 181) == .high)
        #expect(GlycemicBand.band(for: 250) == .high)
        #expect(GlycemicBand.band(for: 251) == .veryHigh)
    }

    /// Below 54 and above 250 are clinically distinct from merely out of range.
    @Test func flagsUrgentBands() {
        #expect(GlycemicBand.veryLow.isUrgent)
        #expect(GlycemicBand.veryHigh.isUrgent)
        #expect(!GlycemicBand.low.isUrgent)
        #expect(!GlycemicBand.high.isUrgent)
        #expect(!GlycemicBand.inRange.isUrgent)
    }

    @Test func handlesRailSentinelValues() {
        #expect(GlycemicBand.band(for: 39) == .veryLow)
        #expect(GlycemicBand.band(for: 401) == .veryHigh)
    }
}
