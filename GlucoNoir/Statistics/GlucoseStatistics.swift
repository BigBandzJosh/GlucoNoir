//
//  GlucoseStatistics.swift
//  GlucoNoir
//
//  Glycemic statistics over a window of readings.
//
//  Definitions follow the international consensus (ATTD/ADA) rather than a
//  simplified in/out-of-range split, so figures here are directly comparable
//  with the AGP report an endocrinologist reads.
//
//  Pure and UI-free: same numbers drive the on-screen summary and, later, the
//  exported report.
//

import Foundation

nonisolated struct GlucoseStatistics: Equatable, Sendable {

    // MARK: Inputs

    let readingCount: Int
    /// Proportion of expected 5-minute samples actually present, 0...1.
    let coverage: Double
    let windowDuration: TimeInterval

    // MARK: Central tendency

    /// mg/dL. Canonical unit; converted only for display.
    let meanMgdl: Double
    let medianMgdl: Double

    // MARK: Variability

    /// Sample standard deviation (n−1), mg/dL.
    let standardDeviation: Double
    /// SD as a percentage of the mean. The standard glycemic variability
    /// metric, and more interpretable than raw SD because it scales with level.
    /// Consensus target is below 36%.
    let coefficientOfVariation: Double

    // MARK: Distribution

    /// Fraction of readings in each band, 0...1. Sums to 1 when non-empty.
    let bandFractions: [GlycemicBand: Double]

    // MARK: Derived

    /// Glucose Management Indicator, an A1C estimate.
    ///
    /// `nil` unless the window is at least 14 days with at least 70% capture.
    /// Below that it is not a meaningful estimate, and showing a number with a
    /// caveat invites it being read anyway.
    let gmi: Double?

    // MARK: Consensus targets

    static let cvTarget = 36.0
    static let timeInRangeTarget = 0.70
    static let timeBelowTarget = 0.04
    static let timeVeryBelowTarget = 0.01
    static let timeAboveTarget = 0.25
    static let timeVeryAboveTarget = 0.05

    /// GMI requires 14 days of data at 70% capture to be valid.
    static let gmiMinimumDuration: TimeInterval = 14 * 24 * 3600
    static let gmiMinimumCoverage = 0.70
    /// Every other statistic here is unreliable below this.
    static let reliableCoverage = 0.70

    var isReliable: Bool { coverage >= Self.reliableCoverage && readingCount > 0 }

    func fraction(_ band: GlycemicBand) -> Double { bandFractions[band] ?? 0 }

    /// Time in range, the headline figure.
    var timeInRange: Double { fraction(.inRange) }
    /// Low plus very low — what the consensus target of <4% refers to.
    var timeBelowRange: Double { fraction(.low) + fraction(.veryLow) }
    var timeAboveRange: Double { fraction(.high) + fraction(.veryHigh) }

    var meetsTimeInRangeTarget: Bool { timeInRange >= Self.timeInRangeTarget }
    var meetsCVTarget: Bool { coefficientOfVariation < Self.cvTarget }
    var meetsTimeBelowTarget: Bool { timeBelowRange < Self.timeBelowTarget }

    // MARK: Computation

    static let empty = GlucoseStatistics(
        readingCount: 0, coverage: 0, windowDuration: 0,
        meanMgdl: 0, medianMgdl: 0,
        standardDeviation: 0, coefficientOfVariation: 0,
        bandFractions: [:], gmi: nil
    )

    static func compute(readings: [ShareGlucoseReading],
                        windowDuration: TimeInterval,
                        now: Date = .now) -> GlucoseStatistics {
        let cutoff = now.addingTimeInterval(-windowDuration)
        let windowed = readings.filter { $0.sampleTime >= cutoff }
        guard !windowed.isEmpty else { return .empty }

        let values = windowed.map { Double($0.valueMgdl) }
        let n = Double(values.count)

        let mean = values.reduce(0, +) / n

        let sorted = values.sorted()
        let median: Double = sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2

        // Sample standard deviation. A single reading has no spread rather
        // than an undefined one.
        let sd: Double
        if values.count > 1 {
            let sumSquares = values.reduce(0) { $0 + pow($1 - mean, 2) }
            sd = (sumSquares / (n - 1)).squareRoot()
        } else {
            sd = 0
        }
        let cv = mean > 0 ? (sd / mean) * 100 : 0

        var counts: [GlycemicBand: Int] = [:]
        for reading in windowed {
            counts[GlycemicBand.band(for: reading.valueMgdl), default: 0] += 1
        }
        var fractions: [GlycemicBand: Double] = [:]
        for band in GlycemicBand.allCases {
            fractions[band] = Double(counts[band] ?? 0) / n
        }

        let expected = windowDuration / 300
        let coverage = expected > 0 ? min(1.0, n / expected) : 0

        // Gated deliberately: below 14 days at 70% capture this is noise
        // presented as an A1C estimate.
        let gmi: Double?
        if windowDuration >= gmiMinimumDuration && coverage >= gmiMinimumCoverage {
            gmi = 3.31 + 0.02392 * mean
        } else {
            gmi = nil
        }

        return GlucoseStatistics(
            readingCount: windowed.count,
            coverage: coverage,
            windowDuration: windowDuration,
            meanMgdl: mean,
            medianMgdl: median,
            standardDeviation: sd,
            coefficientOfVariation: cv,
            bandFractions: fractions,
            gmi: gmi
        )
    }
}

// MARK: - Display

nonisolated extension GlucoseStatistics {
    func meanDisplay(_ unit: GlucoseUnit) -> String {
        unit.format(Int(meanMgdl.rounded()))
    }

    /// SD carries the unit of the measurement, so it converts like a value.
    func sdDisplay(_ unit: GlucoseUnit) -> String {
        switch unit {
        case .mgdl:  return String(Int(standardDeviation.rounded()))
        case .mmolL: return String(format: "%.1f", standardDeviation / GlucoseUnit.mmolDivisor)
        }
    }

    var cvDisplay: String { String(format: "%.1f%%", coefficientOfVariation) }
    var gmiDisplay: String? { gmi.map { String(format: "%.1f%%", $0) } }

    static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        // Avoid rounding a genuine, non-zero low-range excursion to "0%".
        if value > 0 && value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }
}
