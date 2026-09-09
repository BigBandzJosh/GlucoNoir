//
//  ChartData.swift
//  GlucoNoir
//
//  Turns stored readings into something drawable.
//

import Foundation

// MARK: - Window

nonisolated enum ChartWindow: String, CaseIterable, Identifiable, Sendable {
    case h3, h6, h12, h24, d7, d14, d30

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .h3:  return 3 * 3600
        case .h6:  return 6 * 3600
        case .h12: return 12 * 3600
        case .h24: return 24 * 3600
        case .d7:  return 7 * 86400
        case .d14: return 14 * 86400
        case .d30: return 30 * 86400
        }
    }

    var label: String {
        switch self {
        case .h3: return "3h"; case .h6: return "6h"
        case .h12: return "12h"; case .h24: return "24h"
        case .d7: return "7d"; case .d14: return "14d"; case .d30: return "30d"
        }
    }

    /// Windows beyond a day are dated rather than clocked.
    var isMultiDay: Bool { duration > 24 * 3600 }

    var axisStride: (component: Calendar.Component, count: Int) {
        switch self {
        case .h3:  return (.hour, 1)
        case .h6:  return (.hour, 2)
        case .h12: return (.hour, 3)
        case .h24: return (.hour, 6)
        case .d7:  return (.day, 1)
        case .d14: return (.day, 3)
        case .d30: return (.day, 7)
        }
    }

    /// Expected reading count at the sensor's 5-minute cadence.
    var expectedReadings: Int { Int(duration / 300) }
}

// MARK: - Target range

/// Defaults from the international consensus. Editable in a later phase; the
/// band thresholds for Very Low / Very High stay fixed because editing those
/// would silently invalidate comparison against clinical targets.
nonisolated enum TargetRange {
    static let lowMgdl = 70
    static let highMgdl = 180
}

// MARK: - Glycemic bands

/// The international consensus (ATTD/ADA) bands.
///
/// Domain logic, deliberately free of any UI framework: the same classification
/// drives chart colouring now and five-band time-in-range statistics later, and
/// the two must never be allowed to disagree.
nonisolated enum GlycemicBand: String, CaseIterable, Sendable {
    case veryLow, low, inRange, high, veryHigh

    /// Thresholds are fixed at consensus values and are not user-editable —
    /// changing them would silently invalidate comparison against clinical targets.
    static func band(for mgdl: Int) -> GlycemicBand {
        switch mgdl {
        case ..<54:      return .veryLow
        case 54..<70:    return .low
        case 70...180:   return .inRange
        case 181...250:  return .high
        default:         return .veryHigh
        }
    }

    /// Below 54 and above 250 are clinically distinct from merely out of range.
    var isUrgent: Bool { self == .veryLow || self == .veryHigh }

    var label: String {
        switch self {
        case .veryLow:  return "Very low"
        case .low:      return "Low"
        case .inRange:  return "In range"
        case .high:     return "High"
        case .veryHigh: return "Very high"
        }
    }
}

// MARK: - Points and segments

nonisolated struct ChartPoint: Identifiable, Equatable, Sendable {
    let date: Date
    /// Already converted to the display unit, so the axis needs no further work.
    let value: Double
    let valueMgdl: Int

    var id: Date { date }
}

/// A run of readings with no meaningful gap between them.
nonisolated struct ChartSegment: Identifiable, Equatable, Sendable {
    let id: Int
    let points: [ChartPoint]
}

// MARK: - Builder

nonisolated enum ChartDataBuilder {

    /// Two missed samples. Beyond this the sensor genuinely lost contact and
    /// the curve should break.
    static let gapThreshold: TimeInterval = 11 * 60

    /// Splits readings into gap-free segments, oldest first.
    ///
    /// Drawing one continuous line through a 40-minute hole would invent a
    /// trajectory that was never measured — on a glucose chart that is not a
    /// cosmetic issue, because the invented line can cross the low threshold
    /// without anything having been observed.
    static func segments(from readings: [ShareGlucoseReading],
                         unit: GlucoseUnit,
                         gapThreshold: TimeInterval = gapThreshold) -> [ChartSegment] {
        let ordered = downsample(readings).sorted { $0.sampleTime < $1.sampleTime }
        guard !ordered.isEmpty else { return [] }

        var segments: [ChartSegment] = []
        var current: [ChartPoint] = []
        var previous: Date?
        var index = 0

        for reading in ordered {
            if let previous, reading.sampleTime.timeIntervalSince(previous) > gapThreshold {
                segments.append(ChartSegment(id: index, points: current))
                index += 1
                current = []
            }
            current.append(ChartPoint(date: reading.sampleTime,
                                      value: displayValue(reading.valueMgdl, unit),
                                      valueMgdl: reading.valueMgdl))
            previous = reading.sampleTime
        }
        if !current.isEmpty { segments.append(ChartSegment(id: index, points: current)) }
        return segments
    }

    /// Above this, Swift Charts begins to stutter on scroll and zoom.
    static let downsampleThreshold = 1_000
    static let downsampleTargetBuckets = 400

    /// Reduces a dense window to something drawable, keeping the extremes.
    ///
    /// Each bucket contributes its minimum and maximum reading rather than a
    /// mean, because averaging is what makes downsampled glucose charts lie: a
    /// brief hypo inside a bucket disappears entirely into the average, and a
    /// chart that hides a hypo is worse than no chart. A 30-day window is
    /// ~8,600 readings; naive plotting of that is both slow and misleading.
    static func downsample(_ readings: [ShareGlucoseReading],
                           threshold: Int = downsampleThreshold,
                           buckets targetBuckets: Int = downsampleTargetBuckets) -> [ShareGlucoseReading] {
        guard readings.count > threshold else { return readings }
        let ordered = readings.sorted { $0.sampleTime < $1.sampleTime }
        guard let first = ordered.first?.sampleTime,
              let last = ordered.last?.sampleTime,
              last > first else { return ordered }

        let span = last.timeIntervalSince(first)
        let bucketSize = span / Double(targetBuckets)
        guard bucketSize > 0 else { return ordered }

        var result: [ShareGlucoseReading] = []
        var bucket: [ShareGlucoseReading] = []
        var bucketEnd = first.addingTimeInterval(bucketSize)

        func flush() {
            guard !bucket.isEmpty else { return }
            guard let lo = bucket.min(by: { $0.valueMgdl < $1.valueMgdl }),
                  let hi = bucket.max(by: { $0.valueMgdl < $1.valueMgdl }) else { return }
            // Emit in time order so the curve does not zig-zag backwards.
            if lo.sampleTime == hi.sampleTime {
                result.append(lo)
            } else if lo.sampleTime < hi.sampleTime {
                result.append(contentsOf: [lo, hi])
            } else {
                result.append(contentsOf: [hi, lo])
            }
            bucket.removeAll(keepingCapacity: true)
        }

        for reading in ordered {
            while reading.sampleTime >= bucketEnd {
                flush()
                bucketEnd = bucketEnd.addingTimeInterval(bucketSize)
            }
            bucket.append(reading)
        }
        flush()
        return result
    }

    static func displayValue(_ mgdl: Int, _ unit: GlucoseUnit) -> Double {
        switch unit {
        case .mgdl:  return Double(mgdl)
        case .mmolL: return (Double(mgdl) / GlucoseUnit.mmolDivisor * 10).rounded() / 10
        }
    }

    /// Y-axis bounds: always contains the target range, expands for excursions,
    /// and never crops a reading out of view.
    static func yDomain(for readings: [ShareGlucoseReading], unit: GlucoseUnit) -> ClosedRange<Double> {
        let values = readings.map(\.valueMgdl)
        let lowMgdl = min(values.min() ?? TargetRange.lowMgdl, TargetRange.lowMgdl) - 20
        let highMgdl = max(values.max() ?? TargetRange.highMgdl, TargetRange.highMgdl) + 20
        let lo = displayValue(max(0, lowMgdl), unit)
        let hi = displayValue(highMgdl, unit)
        return lo...hi
    }

    /// Proportion of expected 5-minute samples actually present.
    /// Every statistic derived from a window is unreliable below ~70%, so this
    /// is shown alongside rather than buried.
    static func coverage(readings: [ShareGlucoseReading], window: ChartWindow, now: Date = .now) -> Double {
        let expected = window.duration / 300
        guard expected > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-window.duration)
        let present = readings.filter { $0.sampleTime >= cutoff }.count
        return min(1.0, Double(present) / expected)
    }
}
