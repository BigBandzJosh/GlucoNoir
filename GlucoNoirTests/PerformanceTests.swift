//
//  PerformanceTests.swift
//  GlucoNoirTests
//
//  Guards against work that is fine at spike volumes and unusable at real ones.
//  A 90-day store is ~26,000 readings; a 30-day window ~8,600.
//

import Testing
import Foundation
import SwiftData
@testable import GlucoNoir

private let now = Date(timeIntervalSince1970: 1_757_000_000)

/// Realistic data: 5-minute cadence with a plausible daily glucose rhythm.
private func realisticReadings(days: Int) -> [ShareGlucoseReading] {
    let count = days * 288
    return (0..<count).map { i in
        let t = now.addingTimeInterval(-Double(i * 300))
        let phase = Double(i % 288) / 288.0 * 2 * .pi
        let value = 130 + Int(45 * sin(phase)) + (i % 17) - 8
        return ShareGlucoseReading(sampleTime: t, valueMgdl: max(40, min(400, value)), trend: .flat)
    }
}

private func duration(_ block: () throws -> Void) rethrows -> TimeInterval {
    let start = Date()
    try block()
    return Date().timeIntervalSince(start)
}

struct StatisticsPerformanceTests {

    /// This was computed in a view body driven by a one-second timer. At
    /// 30-day volume the median alone sorts ~8,600 values, every tick.
    @Test func thirtyDayStatisticsAreFast() {
        let readings = realisticReadings(days: 30)
        #expect(readings.count == 8_640)

        let elapsed = duration {
            _ = GlucoseStatistics.compute(readings: readings, windowDuration: 30 * 86400, now: now)
        }
        #expect(elapsed < 0.5, "30-day statistics took \(elapsed)s")
    }

    @Test func ninetyDayStatisticsAreFast() {
        let readings = realisticReadings(days: 90)
        let elapsed = duration {
            _ = GlucoseStatistics.compute(readings: readings, windowDuration: 90 * 86400, now: now)
        }
        #expect(elapsed < 1.0, "90-day statistics took \(elapsed)s")
    }

    @Test func statisticsStayCorrectAtVolume() {
        let readings = realisticReadings(days: 30)
        let stats = GlucoseStatistics.compute(readings: readings, windowDuration: 30 * 86400, now: now)
        #expect(stats.readingCount == 8_640)
        #expect(stats.coverage > 0.99)
        let total = GlycemicBand.allCases.reduce(0.0) { $0 + stats.fraction($1) }
        #expect(abs(total - 1.0) < 0.0001)
        #expect(stats.gmi != nil, "90 days at full coverage must qualify for GMI")
    }
}

struct DownsamplingPerformanceTests {

    @Test func thirtyDayChartBuildIsFast() {
        let readings = realisticReadings(days: 30)
        let elapsed = duration {
            _ = ChartDataBuilder.segments(from: readings, unit: .mmolL,
                                          gapThreshold: 30 * 86400 / 120)
        }
        #expect(elapsed < 1.0, "chart build took \(elapsed)s")
    }

    @Test func downsamplingActuallyReduces() {
        let readings = realisticReadings(days: 30)
        let reduced = ChartDataBuilder.downsample(readings)
        #expect(reduced.count < readings.count / 4)
        #expect(reduced.count > 0)
    }

    /// The point of keeping extremes rather than means: a brief hypo inside a
    /// bucket must survive downsampling, or the chart hides the one event that
    /// matters most.
    @Test func downsamplingPreservesABriefHypo() {
        var readings = realisticReadings(days: 30)
        // Insert a short, sharp low well inside the series.
        let hypoIndex = 4_000
        for offset in 0..<4 {
            let existing = readings[hypoIndex + offset]
            readings[hypoIndex + offset] = ShareGlucoseReading(
                sampleTime: existing.sampleTime, valueMgdl: 48, trend: .singleDown
            )
        }

        let reduced = ChartDataBuilder.downsample(readings)
        let lowest = reduced.map(\.valueMgdl).min() ?? 999
        #expect(lowest <= 48, "a 20-minute hypo was smoothed away by downsampling")
    }

    @Test func shortSeriesIsLeftAlone() {
        let readings = realisticReadings(days: 1)   // 288 readings
        #expect(ChartDataBuilder.downsample(readings).count == readings.count)
    }

    @Test func downsampledOutputStaysChronological() {
        let reduced = ChartDataBuilder.downsample(realisticReadings(days: 30))
        let times = reduced.map(\.sampleTime)
        #expect(times == times.sorted(), "downsampled points must not zig-zag backwards in time")
    }
}

@Suite(.serialized)
struct StorePerformanceTests {

    private func makeStore() throws -> GlucoseStore {
        let container = try ModelContainer(
            for: Schema(versionedSchema: GlucoNoirSchemaV2.self),
            migrationPlan: GlucoNoirMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return GlucoseStore(modelContainer: container)
    }

    /// Mirrors the HealthKit backfill: ~26,000 rows in one pass.
    @Test func ninetyDayBackfillCompletes() async throws {
        let store = try makeStore()
        let readings = realisticReadings(days: 90)

        let start = Date()
        let result = try await store.upsert(readings, isBackfilled: true)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.inserted == readings.count)
        #expect(try await store.count() == readings.count)
        #expect(elapsed < 30, "90-day backfill took \(elapsed)s")
    }

    /// A live poll against a full store must not degrade as history grows.
    @Test func pollAgainstFullStoreStaysFast() async throws {
        let store = try makeStore()
        _ = try await store.upsert(realisticReadings(days: 90), isBackfilled: true)

        let poll = realisticReadings(days: 1).prefix(36).map { $0 }
        let start = Date()
        _ = try await store.upsert(Array(poll))
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 2.0, "a routine poll took \(elapsed)s against a full store")
    }

    @Test func windowQueryAgainstFullStoreStaysFast() async throws {
        let store = try makeStore()
        _ = try await store.upsert(realisticReadings(days: 90), isBackfilled: true)

        let start = Date()
        let window = try await store.readings(since: now.addingTimeInterval(-30 * 86400))
        let elapsed = Date().timeIntervalSince(start)

        #expect(window.count > 8_000)
        #expect(elapsed < 3.0, "30-day window query took \(elapsed)s")
    }
}
